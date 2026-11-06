import Foundation

#if canImport(Network)
/// Wallet calls on an LBRY hub, as lbc.exchange makes them (works on both the
/// Python hub and herald.go): base58 addresses, transactions fetched in batches.
extension HubClient: WalletBackend {

    public func history(of address: String) async throws -> [(txid: String, height: Int)] {
        let result = try await call("blockchain.address.get_history", [address])
        guard let items = result as? [[String: Any]] else {
            if result is NSNull { return [] }
            throw HubError.badResponse("address.get_history")
        }
        return items.compactMap { item in
            guard let txid = item["tx_hash"] as? String, let height = item["height"] as? Int else { return nil }
            return (txid, height)
        }
    }

    public func transactions(_ txids: [String]) async throws -> [String: FetchedTransaction] {
        var out: [String: FetchedTransaction] = [:]
        for start in stride(from: 0, to: txids.count, by: 100) {
            let batch = Array(txids[start..<min(start + 100, txids.count)])
            let result = try await call("blockchain.transaction.get_batch", batch)
            guard let dict = result as? [String: Any] else { throw HubError.badResponse("transaction.get_batch") }
            for (txid, value) in dict {
                guard let pair = value as? [Any], let hex = pair.first as? String else { continue }
                let info = pair.count > 1 ? pair[1] as? [String: Any] : nil
                let height = info?["block_height"] as? Int ?? 0
                out[txid] = FetchedTransaction(
                    hex: hex,
                    height: height,
                    merkleBranch: height > 0 ? info?["merkle"] as? [String] : nil,
                    merklePosition: height > 0 ? info?["pos"] as? Int : nil
                )
            }
        }
        return out
    }

    public func broadcast(_ rawHex: String) async throws -> String {
        let result = try await call("blockchain.transaction.broadcast", [rawHex])
        return result as? String ?? ""
    }
}
#endif
