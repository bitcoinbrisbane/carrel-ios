import Foundation

/// Brings a `HeaderChain` up to a hub's tip, batch by batch, and recovers from
/// short reorgs by stepping back inside the window.
public actor ChainSync {

    public enum SyncError: Error, Equatable {
        /// We're further behind than one batch per call allows; keep calling `sync()`.
        case stillBehind(local: Int, remote: Int)
        /// The hub's chain forks below our window. Needs a newer checkpoint.
        case forkBeyondWindow(Int)
    }

    public private(set) var chain: HeaderChain
    private let source: HeaderSource
    private let batchSize: Int

    public init(chain: HeaderChain, source: HeaderSource, batchSize: Int = 2000) {
        self.chain = chain
        self.source = source
        self.batchSize = batchSize
    }

    /// Sync to the source's tip. Returns how many headers were added to the best chain.
    @discardableResult
    public func sync(maxBatches: Int = 1_000) async throws -> Int {
        var added = 0
        for _ in 0..<maxBatches {
            let remote = try await source.tip()
            if remote.height == chain.height && remote.header.hash == chain.tip.header.hash {
                return added
            }
            if remote.height < chain.height - 1 && chain.header(at: remote.height)?.hash == remote.header.hash {
                return added   // hub is just behind us
            }

            let start = chain.height + 1
            let count = max(1, min(batchSize, remote.height - chain.height))
            let batch = try await source.headers(from: start, count: count)
            if batch.isEmpty { return added }

            do {
                added += try chain.connect(batch, startingAt: start)
            } catch HeaderChain.ValidationError.prevHashMismatch(let height) where height == start {
                // Our tip isn't on the hub's chain: walk back through the window to find the fork.
                added += try await rewindAndReconnect()
            }
        }
        throw SyncError.stillBehind(local: chain.height, remote: try await source.tip().height)
    }

    private func rewindAndReconnect() async throws -> Int {
        var back = 1
        while chain.height - back - 2 >= chain.startHeight {
            let from = chain.height - back
            let batch = try await source.headers(from: from, count: back + batchSize)
            if let ours = chain.header(at: from), let theirs = batch.first, ours.hash == theirs.hash {
                return try chain.connect(batch, startingAt: from)
            }
            back *= 2
        }
        throw SyncError.forkBeyondWindow(chain.startHeight)
    }
}
