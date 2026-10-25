#if targetEnvironment(simulator)
import Foundation
@preconcurrency import MultipeerConnectivity
@preconcurrency import Network

/// Simulator only: two Simulators on one Mac can't complete a MultipeerConnectivity session, so they talk over
/// loopback TCP instead. The first app to start listens on a fixed port; the second connects. Messages are
/// length-prefixed. Everything above the link (the payment protocol, Face ID, the ledgers) is unchanged.
final class LoopbackLink: NearbyLink {
    static let port: NWEndpoint.Port = 47_800

    private let queue = DispatchQueue(label: "secure.loopback-link")
    private let onEvent: (NearbyLinkEvent) -> Void
    private var listener: NWListener?
    private var connections: [MCPeerID: NWConnection] = [:]

    init(onEvent: @escaping (NearbyLinkEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = false
        if let listener = try? NWListener(using: parameters, on: Self.port) {
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.adopt(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                // The port is taken: another Simulator is listening, so connect to it instead.
                if case .failed = state { Task { @MainActor in self?.connectAsClient() } }
            }
            listener.start(queue: queue)
        } else {
            connectAsClient()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    func send(_ data: Data, to peer: MCPeerID) throws {
        guard let connection = connections[peer] else { return }
        var length = UInt32(data.count).bigEndian
        connection.send(content: Data(bytes: &length, count: 4) + data, completion: .idempotent)
    }

    private func connectAsClient() {
        listener?.cancel()
        listener = nil
        adopt(NWConnection(host: "127.0.0.1", port: Self.port, using: .tcp))
    }

    private func adopt(_ connection: NWConnection) {
        let peer = MCPeerID(displayName: "Simulator peer")
        connections[peer] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onEvent(.connected(peer))
                    self.receive(on: connection, from: peer)
                case .failed, .cancelled:
                    if self.connections.removeValue(forKey: peer) != nil { self.onEvent(.disconnected(peer)) }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, from peer: MCPeerID) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let header, header.count == 4, error == nil else {
                if isComplete || error != nil { connection.cancel() }
                return
            }
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, error == nil else { return connection.cancel() }
                Task { @MainActor in
                    self?.onEvent(.received(body, from: peer))
                    self?.receive(on: connection, from: peer)
                }
            }
        }
    }
}
#endif
