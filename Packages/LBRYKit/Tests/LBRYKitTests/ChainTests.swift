import XCTest
@testable import LBRYKit

/// Vectors come from lbry-sdk `tests/unit/wallet/test_headers.py` and lbrycrd
/// `src/test/lbry_tests.cpp`; the 20 headers are real mainnet blocks 0–19.
final class HashingTests: XCTestCase {

    func testRIPEMD160KnownVectors() {
        XCTAssertEqual(RIPEMD160.hash([]).hex, "9c1185a5c5e9fc54612808977ee8f548b2258d31")
        XCTAssertEqual(RIPEMD160.hash(Array("abc".utf8)).hex, "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
        XCTAssertEqual(RIPEMD160.hash(Array("message digest".utf8)).hex, "5d0689ef49d2fae572b881b123a85ffa21595f36")
        XCTAssertEqual(RIPEMD160.hash([UInt8](repeating: 0x61, count: 1000)).hex, "aa69deee9a8922e92f8105e007f76110f381e9cf")
    }

    func testLBRYProofOfWorkHash() {
        func pow(_ input: [UInt8]) -> String {
            LBRYHash.powHash(blockHash: LBRYHash.sha256d(input)).reversed().hex
        }
        XCTAssertEqual(pow(Array("test string".utf8)), "485f3920d48a0448034b0852d1489cfa475341176838c7d36896765221be35ce")
        XCTAssertEqual(pow([UInt8](repeating: 0x61, count: 70)), "eb44af2f41e7c6522fb8be4773661be5baa430b8b2c3a670247e9ab060608b75")
        XCTAssertEqual(pow([UInt8](repeating: 0x64, count: 140)), "74044747b7c1ff867eb09a84d026b02d8dc539fb6adcec3536f3dfa9266495d9")
    }
}

final class DifficultyTests: XCTestCase {

    func testCompactRoundTrip() {
        for bits: UInt32 in [0x1f00ffff, 0x1f00e146, 0x1e76e170, 0x1d00ffff, 0x1b0404cb] {
            XCTAssertEqual(UInt256(compact: bits).compact, bits, String(bits, radix: 16))
        }
        XCTAssertEqual(UInt256.lbryMaxTarget.compact, 0x1f00ffff)
    }

    func testRetargetVectors() {
        let t0: UInt32 = 1_386_475_638
        // Max retarget from block 1 difficulty.
        XCTAssertEqual(LBRYDifficulty.nextBits(previousPreviousTimestamp: t0, previousTimestamp: t0, previousBits: 0x1f00ffff), 0x1f00e146)
        // Max retarget (difficulty increase).
        XCTAssertEqual(LBRYDifficulty.nextBits(previousPreviousTimestamp: t0, previousTimestamp: t0, previousBits: 0x1f00a000), 0x1f008ccc)
        // Min retarget (difficulty decrease).
        XCTAssertEqual(LBRYDifficulty.nextBits(previousPreviousTimestamp: t0, previousTimestamp: t0 + 1200, previousBits: 0x1f00a000), 0x1f00f000)
        // Never above the proof-of-work limit.
        XCTAssertEqual(LBRYDifficulty.nextBits(previousPreviousTimestamp: t0, previousTimestamp: t0 + 600, previousBits: 0x1f00ffff), 0x1f00ffff)
    }
}

final class HeaderChainTests: XCTestCase {

    private func mainnetHeaders() throws -> [BlockHeader] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "headers_0_19", withExtension: "hex", subdirectory: "Fixtures"))
        let hex = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try BlockHeader.split(XCTUnwrap([UInt8](hex: hex)))
    }

    func testParsesGenesis() throws {
        let genesis = try mainnetHeaders()[0]
        XCTAssertEqual(genesis.hashHex, "9c89283ba0f3227f6c03b70216b9f665f0118d5e0fa729cedf4fb34d6a34f463")
        XCTAssertEqual(genesis.version, 1)
        XCTAssertEqual(genesis.timestamp, 1_446_058_291)
        XCTAssertEqual(genesis.bits, 520_159_231)
        XCTAssertEqual(genesis.nonce, 1287)
        XCTAssertEqual(genesis.claimTrieRootHex, String(repeating: "0", count: 63) + "1")
    }

    func testBlock10Fields() throws {
        let h = try mainnetHeaders()[10]
        XCTAssertEqual(h.bits, 509_349_720)
        XCTAssertEqual(h.nonce, 75838)
        XCTAssertEqual(h.prevHashHex, "fdab1b38bcf236bc85b6bcd52fe8ec19bcb0b6c7352e913de05fa5a4e5ae8d55")
    }

    func testGenesisCheckpointMatchesFixture() throws {
        let headers = try mainnetHeaders()
        XCTAssertEqual(Checkpoint.genesis.previousHeaderHex, headers[0].raw.hex)
        XCTAssertEqual(Checkpoint.genesis.headerHex, headers[1].raw.hex)
        XCTAssertEqual(Checkpoint.genesis.hash, headers[1].hashHex)
    }

    func testValidatesMainnetBlocks2Through19() throws {
        let headers = try mainnetHeaders()
        var chain = try HeaderChain(checkpoint: .genesis)
        XCTAssertEqual(try chain.connect(Array(headers[2...]), startingAt: 2), 18)
        XCTAssertEqual(chain.height, 19)
        XCTAssertEqual(chain.tip.header.hashHex, "18d3de7103c42f7a923d1cd69af4909557758eda58f1d38d4ba0ea335e88df1f")
    }

    func testWindowKeepsOnlyCapacity() throws {
        let headers = try mainnetHeaders()
        var chain = try HeaderChain(checkpoint: .genesis, capacity: 5)
        try chain.connect(Array(headers[2...]), startingAt: 2)
        XCTAssertEqual(chain.window.count, 5)
        XCTAssertEqual(chain.startHeight, 15)
        XCTAssertNil(chain.header(at: 14))
        XCTAssertEqual(chain.header(at: 19)?.hash, headers[19].hash)
    }

    func testConnectInBatchesAndIgnoresDuplicates() throws {
        let headers = try mainnetHeaders()
        var chain = try HeaderChain(checkpoint: .genesis)
        XCTAssertEqual(try chain.connect(Array(headers[2..<10]), startingAt: 2), 8)
        XCTAssertEqual(try chain.connect(Array(headers[5..<10]), startingAt: 5), 0)
        XCTAssertEqual(try chain.connect(Array(headers[8...]), startingAt: 8), 10)
        XCTAssertEqual(chain.height, 19)
    }

    func testRejectsTamperedHeader() throws {
        let headers = try mainnetHeaders()
        var raw = headers[2].raw
        raw[108] ^= 0x01   // flip a nonce bit: hash changes, PoW fails
        var chain = try HeaderChain(checkpoint: .genesis)
        XCTAssertThrowsError(try chain.connect([try BlockHeader(raw: raw)], startingAt: 2)) { error in
            XCTAssertEqual(error as? HeaderChain.ValidationError, .insufficientProofOfWork(height: 2))
        }
        XCTAssertEqual(chain.height, 1, "failed connect must leave the chain untouched")
    }

    func testRejectsWrongBits() throws {
        let headers = try mainnetHeaders()
        var raw = headers[2].raw
        raw[104] ^= 0x01
        var chain = try HeaderChain(checkpoint: .genesis)
        XCTAssertThrowsError(try chain.connect([try BlockHeader(raw: raw)], startingAt: 2)) { error in
            guard case .badBits(height: 2, _, _)? = error as? HeaderChain.ValidationError else {
                return XCTFail("expected badBits, got \(error)")
            }
        }
    }

    func testRejectsBrokenLinkAndGaps() throws {
        let headers = try mainnetHeaders()
        var chain = try HeaderChain(checkpoint: .genesis)
        XCTAssertThrowsError(try chain.connect([headers[3]], startingAt: 2)) { error in
            XCTAssertEqual(error as? HeaderChain.ValidationError, .prevHashMismatch(height: 2))
        }
        XCTAssertThrowsError(try chain.connect([headers[4]], startingAt: 4)) { error in
            XCTAssertEqual(error as? HeaderChain.ValidationError, .gap(expected: 2, got: 4))
        }
    }

    func testBadCheckpointIsRejected() {
        let bad = Checkpoint(
            height: 1,
            previousHeaderHex: Checkpoint.genesis.previousHeaderHex,
            headerHex: Checkpoint.genesis.headerHex,
            hash: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(try HeaderChain(checkpoint: bad))
    }

    func testChainRoundTripsThroughJSON() throws {
        let headers = try mainnetHeaders()
        var chain = try HeaderChain(checkpoint: .genesis, capacity: 10)
        try chain.connect(Array(headers[2...]), startingAt: 2)
        let decoded = try JSONDecoder().decode(HeaderChain.self, from: JSONEncoder().encode(chain))
        XCTAssertEqual(decoded, chain)
    }
}

final class ChainSyncTests: XCTestCase {

    /// In-memory hub serving the 20 fixture headers, a few at a time.
    struct FixtureSource: HeaderSource {
        let headers: [BlockHeader]
        let maxPerCall: Int
        func tip() async throws -> (height: Int, header: BlockHeader) {
            (headers.count - 1, headers[headers.count - 1])
        }
        func headers(from height: Int, count: Int) async throws -> [BlockHeader] {
            guard height < headers.count else { return [] }
            return Array(headers[height..<min(headers.count, height + min(count, maxPerCall))])
        }
    }

    func testSyncsToTipInSmallBatches() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "headers_0_19", withExtension: "hex", subdirectory: "Fixtures"))
        let hex = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = try BlockHeader.split(XCTUnwrap([UInt8](hex: hex)))

        let sync = ChainSync(
            chain: try HeaderChain(checkpoint: .genesis, capacity: 8),
            source: FixtureSource(headers: headers, maxPerCall: 3)
        )
        let added = try await sync.sync()
        let chain = await sync.chain
        XCTAssertEqual(added, 18)
        XCTAssertEqual(chain.height, 19)
        XCTAssertEqual(chain.window.count, 8)
        let again = try await sync.sync()
        XCTAssertEqual(again, 0, "already at tip")
    }
}
