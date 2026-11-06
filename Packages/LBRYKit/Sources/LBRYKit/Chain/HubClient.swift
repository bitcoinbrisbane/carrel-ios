import Foundation

/// What CarrelChain needs from an LBRY hub (Electrum-style protocol).
/// A protocol so sync logic can be tested without a network.
public protocol HeaderSource: Sendable {
    /// Current best height and its raw header.
    func tip() async throws -> (height: Int, header: BlockHeader)
    /// Up to `count` consecutive raw headers starting at `height`.
    func headers(from height: Int, count: Int) async throws -> [BlockHeader]
}

public struct HubServer: Sendable, Hashable {
    public let host: String
    public let port: UInt16
    public let useTLS: Bool

    public init(host: String, port: UInt16 = 50001, useTLS: Bool = false) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }

    /// Default hubs, per lbry-sdk-ng's refreshed list (Oct 2026). The old
    /// spv1x.lbry.com hubs were dropped. Some of these may still be offline.
    public static let defaults: [HubServer] = [
        "a-hub1.odysee.com", "b-hub1.odysee.com", "c-hub1.odysee.com", "s-hub1.odysee.com",
        "hub.lbry.grin.io", "hub.lizard.technology", "s1.lbry.network",
    ].map { HubServer(host: $0) }
}

public enum HubError: Error, Equatable {
    case notConnected
    case connectionFailed(String)
    case rpc(String)
    case badResponse(String)
}

#if canImport(Network)
import Network

/// Newline-delimited JSON-RPC over TCP to an LBRY hub, using Network.framework.
public actor HubClient: HeaderSource {

    public static let clientName = "Carrel 0.1"
    public static let protocolVersion = "0.113.0"   // matches lbry-sdk; hubs accept >= 0.65.0

    public let server: HubServer
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?

    public init(server: HubServer) {
        self.server = server
    }

    // MARK: Connection

    public func connect(timeout: TimeInterval = 6) async throws {
        guard connection == nil else { return }
        let parameters: NWParameters = server.useTLS ? .tls : .tcp
        let conn = NWConnection(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: parameters
        )
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handle(state) }
        }
        conn.start(queue: .global(qos: .utility))

        let host = server.host
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.failReady(HubError.connectionFailed("timed out connecting to \(host)"))
        }
        defer { timeoutTask.cancel() }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if conn.state == .ready { cont.resume() } else { readyContinuation = cont }
            }
        } catch {
            disconnect()
            throw error
        }
        receiveNext()
        _ = try await call("server.version", [Self.clientName, Self.protocolVersion])
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        failReady(HubError.notConnected)
        failAll(HubError.notConnected)
    }

    private func failReady(_ error: Error) {
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            readyContinuation?.resume()
            readyContinuation = nil
        case .failed(let error), .waiting(let error):
            failReady(HubError.connectionFailed(error.localizedDescription))
            failAll(HubError.connectionFailed(error.localizedDescription))
        case .cancelled:
            failAll(HubError.notConnected)
        default:
            break
        }
    }

    // MARK: JSON-RPC

    /// Call a hub method; returns the decoded JSON `result`.
    public func call(_ method: String, _ params: [Any]) async throws -> Any {
        guard let connection else { throw HubError.notConnected }
        nextID += 1
        let id = nextID
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        var line = try JSONSerialization.data(withJSONObject: body)
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            connection.send(content: line, completion: .contentProcessed { [weak self] error in
                guard let error, let self else { return }
                Task { await self.resolve(id: id, with: .failure(HubError.connectionFailed(error.localizedDescription))) }
            })
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.didReceive(data, isComplete: isComplete, error: error) }
        }
    }

    private func didReceive(_ data: Data?, isComplete: Bool, error: NWError?) {
        if let data { buffer.append(data) }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handleLine(Data(line))
        }
        if let error {
            failAll(HubError.connectionFailed(error.localizedDescription))
        } else if isComplete {
            failAll(HubError.notConnected)
        } else {
            receiveNext()
        }
    }

    private func handleLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        // Notifications (e.g. blockchain.headers.subscribe) have no id; ignored for now.
        guard let id = object["id"] as? Int else { return }
        if let error = object["error"] as? [String: Any] {
            resolve(id: id, with: .failure(HubError.rpc(error["message"] as? String ?? "\(error)")))
        } else {
            resolve(id: id, with: .success(object["result"] ?? NSNull()))
        }
    }

    private func resolve(id: Int, with result: Result<Any, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    // MARK: HeaderSource

    public func tip() async throws -> (height: Int, header: BlockHeader) {
        let result = try await call("blockchain.headers.subscribe", [true])
        guard let dict = result as? [String: Any],
              let height = dict["height"] as? Int,
              let hex = dict["hex"] as? String else {
            throw HubError.badResponse("headers.subscribe")
        }
        return (height, try BlockHeader(hex: hex))
    }

    public func headers(from height: Int, count: Int) async throws -> [BlockHeader] {
        // params: start_height, count, cp_height (0 = no proof), b64 (false = plain hex)
        let result = try await call("blockchain.block.headers", [height, count, 0, false])
        guard let dict = result as? [String: Any], let hex = dict["hex"] as? String else {
            throw HubError.badResponse("block.headers")
        }
        guard let bytes = [UInt8](hex: hex) else { throw HubError.badResponse("block.headers hex") }
        return try BlockHeader.split(bytes)
    }
}
#endif
