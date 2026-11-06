import Foundation

extension Checkpoint {

    /// Genesis (blocks 0 and 1). Always valid, but syncing from here means ~2M headers —
    /// use only for tests or as a last resort.
    public static let genesis = Checkpoint(
        height: 1,
        previousHeaderHex: "010000000000000000000000000000000000000000000000000000000000000000000000cc59e59ff97ac092b55e423aa5495151ed6fb80570a5bb78cd5bd1c3821c21b8010000000000000000000000000000000000000000000000000000000000000033193156ffff001f07050000",
        headerHex: "0000002063f4346a4db34fdfce29a70f5e8d11f065f6b91602b7036c7f22f3a03b28899cba888e2f9c037f831046f8ad09f6d378f79c728d003b177a64d29621f481da5d01000000000000000000000000000000000000000000000000000000000000003c406b5746e1001f5b4f0000",
        hash: "decb9e2cca03a419fd9cca0cb2b1d5ad11b088f22f8f38556d93ac4358b86c24"
    )

    /// Recent mainnet checkpoint shipped with the app. Regenerate before each release:
    ///
    ///     python3 scripts/make_checkpoint.py > Packages/LBRYKit/Sources/LBRYKit/Chain/Checkpoint+Mainnet.swift
    ///
    /// Until one has been generated, `mainnet` is nil and this falls back to genesis.
    public static var latest: Checkpoint { mainnet ?? genesis }
}
