import Foundation
import Network

/// Advertises this Mac over Bonjour, discovers other MediaTool instances on the LAN
/// and keeps one TCP connection per peer.
///
/// To avoid duplicate connections, only the peer with the lexicographically smaller ID
/// dials out; the other side waits for the incoming connection.
/// All internal state lives on `queue`; the public callbacks are delivered on the main queue.
final class PeerService {
    static let serviceType = "_mediatool._tcp"
    private static let retryDelay: TimeInterval = 5

    var onPeerDiscovered: ((_ id: String, _ name: String) -> Void)?
    var onPeerLost: ((_ id: String) -> Void)?
    var onPeerConnected: ((_ id: String, _ name: String) -> Void)?
    var onPeerDisconnected: ((_ id: String) -> Void)?
    var onMessage: ((_ from: String, WireMessage) -> Void)?

    private let identity: LocalIdentity
    private let queue = DispatchQueue(label: "mediatool.peers")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discovered: [String: NWEndpoint] = [:]
    private var connections: [String: PeerConnection] = [:]
    private var handshaking: [ObjectIdentifier: PeerConnection] = [:]

    static func debug(_ message: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["MEDIATOOL_DEBUG"] != nil {
            NSLog("MediaTool: \(message())")
        }
    }

    init(identity: LocalIdentity) {
        self.identity = identity
    }

    private static func parameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }

    func start() {
        queue.async { self.startListener() }
        queue.async { self.startBrowser() }
    }

    func send(_ message: WireMessage, to peerID: String) {
        queue.async {
            self.connections[peerID]?.send(message)
        }
    }

    // MARK: - Listener

    private func startListener() {
        do {
            let listener = try NWListener(using: Self.parameters())
            listener.service = NWListener.Service(name: identity.id,
                                                  type: Self.serviceType,
                                                  domain: nil,
                                                  txtRecord: NWTXTRecord(["name": identity.name]))
            listener.newConnectionHandler = { [weak self] connection in
                self?.attach(PeerConnection(connection: connection, isOutgoing: false))
            }
            listener.stateUpdateHandler = { [weak self] state in
                Self.debug("listener state: \(state)")
                if case .failed(let error) = state {
                    NSLog("MediaTool: listener failed: \(error)")
                    self?.listener?.cancel()
                    self?.queue.asyncAfter(deadline: .now() + Self.retryDelay) { self?.startListener() }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("MediaTool: could not create listener: \(error)")
        }
    }

    // MARK: - Browser

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
                                using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }
        browser.stateUpdateHandler = { state in
            Self.debug("browser state: \(state)")
            if case .failed(let error) = state {
                NSLog("MediaTool: browser failed: \(error)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var current: [String: (endpoint: NWEndpoint, name: String)] = [:]
        for result in results {
            guard case .service(let id, _, _, _) = result.endpoint, id != identity.id else { continue }
            var name = id
            if case .bonjour(let txt) = result.metadata, let advertised = txt["name"] {
                name = advertised
            }
            current[id] = (result.endpoint, name)
        }

        for id in discovered.keys where current[id] == nil {
            discovered[id] = nil
            deliver { $0.onPeerLost?(id) }
        }
        for (id, entry) in current {
            let isNew = discovered[id] == nil
            discovered[id] = entry.endpoint
            if isNew {
                Self.debug("discovered \(entry.name) [\(id)]")
                deliver { $0.onPeerDiscovered?(id, entry.name) }
                connectIfNeeded(to: id)
            }
        }
    }

    // MARK: - Connections

    private func connectIfNeeded(to peerID: String) {
        guard identity.id < peerID,
              connections[peerID] == nil,
              !handshaking.values.contains(where: { $0.isOutgoing && $0.peerID == peerID }),
              let endpoint = discovered[peerID] else { return }
        let connection = PeerConnection(connection: NWConnection(to: endpoint, using: Self.parameters()),
                                        isOutgoing: true)
        connection.peerID = peerID
        Self.debug("dialing \(peerID)")
        attach(connection)
    }

    private func attach(_ connection: PeerConnection) {
        handshaking[ObjectIdentifier(connection)] = connection
        connection.onReady = { [weak self] connection in
            guard let self else { return }
            connection.send(WireMessage(kind: .hello,
                                        senderID: self.identity.id,
                                        senderName: self.identity.name,
                                        version: WireMessage.protocolVersion))
        }
        connection.onMessage = { [weak self] connection, message in
            self?.handle(message, on: connection)
        }
        connection.onClose = { [weak self] connection in
            self?.handleClose(of: connection)
        }
        connection.start(queue: queue)
    }

    private func handle(_ message: WireMessage, on connection: PeerConnection) {
        if message.kind == .hello {
            let peerID = message.senderID
            guard peerID != identity.id else {
                connection.cancel()
                return
            }
            handshaking[ObjectIdentifier(connection)] = nil
            connection.peerID = peerID
            if let existing = connections[peerID], existing !== connection {
                // Newer connection wins; the old one is probably stale.
                existing.cancel()
            }
            connections[peerID] = connection
            Self.debug("connected to \(message.senderName ?? peerID) [\(peerID)]")
            let name = message.senderName ?? peerID
            deliver { $0.onPeerConnected?(peerID, name) }
            return
        }

        guard let peerID = connection.peerID, connections[peerID] === connection else { return }
        deliver { $0.onMessage?(peerID, message) }
    }

    private func handleClose(of connection: PeerConnection) {
        handshaking[ObjectIdentifier(connection)] = nil
        Self.debug("connection closed: \(connection.peerID ?? "unidentified")")
        guard let peerID = connection.peerID else { return }
        if connections[peerID] === connection {
            connections[peerID] = nil
            deliver { $0.onPeerDisconnected?(peerID) }
        }
        if identity.id < peerID {
            queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.connectIfNeeded(to: peerID)
            }
        }
    }

    private func deliver(_ event: @escaping (PeerService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            event(self)
        }
    }
}
