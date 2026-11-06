import Foundation

/// A trusted starting point: two consecutive raw headers (height-1, height) and the
/// expected hash of the second. Two are needed because LBRY's retarget for block
/// N+1 depends on blocks N and N-1.
public struct Checkpoint: Sendable, Hashable {
    public let height: Int
    public let previousHeaderHex: String
    public let headerHex: String
    public let hash: String

    public init(height: Int, previousHeaderHex: String, headerHex: String, hash: String) {
        self.height = height
        self.previousHeaderHex = previousHeaderHex
        self.headerHex = headerHex
        self.hash = hash
    }
}

/// CarrelChain: a rolling window of the most recent LBRY headers, fully validated
/// from a checkpoint forward (linkage, per-block difficulty, LBRY proof of work).
/// Older headers are dropped once the window is full.
public struct HeaderChain: Sendable, Codable, Equatable {

    public struct Entry: Sendable, Codable, Hashable {
        public let height: Int
        public let header: BlockHeader
    }

    public enum ValidationError: Error, Equatable {
        case badCheckpoint(String)
        case gap(expected: Int, got: Int)
        case beforeWindow(height: Int, windowStart: Int)
        case prevHashMismatch(height: Int)
        case badBits(height: Int, expected: UInt32, got: UInt32)
        case insufficientProofOfWork(height: Int)
        case lessWorkThanCurrentChain(forkHeight: Int)
    }

    public static let defaultCapacity = 100

    public let capacity: Int
    public private(set) var window: [Entry]

    public var tip: Entry { window[window.count - 1] }
    public var height: Int { tip.height }
    public var startHeight: Int { window[0].height }

    public init(checkpoint: Checkpoint, capacity: Int = HeaderChain.defaultCapacity) throws {
        precondition(capacity >= 2, "window must hold at least two headers to validate difficulty")
        let previous: BlockHeader, current: BlockHeader
        do {
            previous = try BlockHeader(hex: checkpoint.previousHeaderHex)
            current = try BlockHeader(hex: checkpoint.headerHex)
        } catch {
            throw ValidationError.badCheckpoint("unparseable header")
        }
        guard current.prevHash == previous.hash else { throw ValidationError.badCheckpoint("headers don't link") }
        guard current.hashHex == checkpoint.hash.lowercased() else { throw ValidationError.badCheckpoint("hash mismatch") }
        self.capacity = capacity
        self.window = [
            Entry(height: checkpoint.height - 1, header: previous),
            Entry(height: checkpoint.height, header: current),
        ]
    }

    public func header(at height: Int) -> BlockHeader? {
        let i = height - startHeight
        return window.indices.contains(i) ? window[i].header : nil
    }

    /// Connect headers starting at `height`. Headers we already have are skipped;
    /// a competing branch replaces ours only if it carries more work.
    /// Returns the number of new headers on the resulting best chain.
    @discardableResult
    public mutating func connect(_ headers: [BlockHeader], startingAt height: Int) throws -> Int {
        guard !headers.isEmpty else { return 0 }
        guard height <= tip.height + 1 else { throw ValidationError.gap(expected: tip.height + 1, got: height) }

        // Skip headers identical to ones already in the window.
        var offset = 0
        while offset < headers.count,
              let existing = header(at: height + offset),
              existing.hash == headers[offset].hash {
            offset += 1
        }
        guard offset < headers.count else { return 0 }

        let forkHeight = height + offset
        // Validating block N needs N-1 and N-2 in the window.
        guard forkHeight - 2 >= startHeight else {
            throw ValidationError.beforeWindow(height: forkHeight, windowStart: startHeight)
        }

        // Build the candidate chain on a copy, so a failure leaves us untouched.
        var candidate = Array(window[0..<(forkHeight - startHeight)])
        for (i, header) in headers[offset...].enumerated() {
            let h = forkHeight + i
            let prev = candidate[candidate.count - 1].header
            let prevPrev = candidate[candidate.count - 2].header
            try Self.validate(header, height: h, previous: prev, previousPrevious: prevPrev)
            candidate.append(Entry(height: h, header: header))
        }

        // Fork choice: if this replaces blocks we had, it must carry more work.
        if forkHeight <= tip.height {
            let replaced = window[(forkHeight - startHeight)...].reduce(0) { $0 + $1.header.work }
            let incoming = candidate[(forkHeight - startHeight)...].reduce(0) { $0 + $1.header.work }
            guard incoming > replaced else { throw ValidationError.lessWorkThanCurrentChain(forkHeight: forkHeight) }
        }

        let added = candidate.count - (forkHeight - startHeight)
        if candidate.count > capacity { candidate.removeFirst(candidate.count - capacity) }
        window = candidate
        return added
    }

    public mutating func connect(raw bytes: [UInt8], startingAt height: Int) throws -> Int {
        try connect(BlockHeader.split(bytes), startingAt: height)
    }

    static func validate(_ header: BlockHeader, height: Int, previous: BlockHeader, previousPrevious: BlockHeader) throws {
        guard header.prevHash == previous.hash else {
            throw ValidationError.prevHashMismatch(height: height)
        }
        let expected = LBRYDifficulty.nextBits(previousPrevious: previousPrevious, previous: previous)
        guard header.bits == expected else {
            throw ValidationError.badBits(height: height, expected: expected, got: header.bits)
        }
        guard header.proofOfWork <= header.target else {
            throw ValidationError.insufficientProofOfWork(height: height)
        }
    }
}
