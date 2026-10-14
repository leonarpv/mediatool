import Foundation
import Network

/// State of the link to one peer, as seen by `PeerService`.
enum LinkState: Equatable {
    case idle                               // no connection and nothing scheduled
    case connecting
    case retrying(attempt: Int, at: Date)
    case connected(since: Date)
    case unstable(since: Date)              // connected, but the network path is currently not viable
}

/// Advertises this Mac over Bonjour, discovers other MediaTool instances on the LAN
/// and keeps one TCP connection per peer, reconnecting with backoff when it drops.
///
/// Either side may dial. If both connections succeed, both peers keep the one dialed by the
/// lexicographically smaller ID, so they always agree on which one survives.
/// All internal state lives on `queue`; the public callbacks are delivered on the main queue.
final class PeerService {
    static let serviceType = "_mediatool._tcp"
    private static let listenerRetryDelay: TimeInterval = 5
    private static let handshakeTimeout: TimeInterval = 10
    /// The higher-ID side waits a bit before dialing, so usually only one connection is made.
    private static let secondaryDialDelay: TimeInterval = 3
    private static let maxRetryDelay: TimeInterval = 30

    var onPeerDiscovered: ((_ id: String, _ name: String) -> Void)?
    var onPeerLost: ((_ id: String) -> Void)?
    var onPeerConnected: ((_ id: String, _ name: String) -> Void)?
    var onLinkStateChanged: ((_ id: String, LinkState) -> Void)?
    var onMessage: ((_ from: String, WireMessage) -> Void)?

    private let identity: LocalIdentity
    private let queue = DispatchQueue(label: "mediatool.peers")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status?
    private var discovered: [String: NWEndpoint] = [:]
    private var connections: [String: PeerConnection] = [:]
    private var handshaking: [ObjectIdentifier: PeerConnection] = [:]
    private var linkStates: [String: LinkState] = [:]
    private var attempts: [String: Int] = [:]
    private var retryWork: [String: DispatchWorkItem] = [:]

    static func debug(_ message: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["MEDIATOOL_DEBUG"] != nil {
            NSLog("MediaTool: \(message())")
        }
    }

    init(identity: LocalIdentity) {
        self.identity = identity
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Detect silently dropped links (Wi-Fi blips, sleep) in ~20s instead of never.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    func start() {
        queue.async {
            self.startListener()
            self.startBrowser()
            self.startPathMonitor()
        }
    }

    func send(_ message: WireMessage, to peerID: String) {
        queue.async {
            self.connections[peerID]?.send(message)
        }
    }

    /// Drops the current connection to `peerID` (if any) and dials again right away.
    /// Works for peers not currently discovered too, by resolving their Bonjour name.
    func reconnect(_ peerID: String) {
        queue.async {
            Self.debug("manual reconnect to \(peerID)")
            self.attempts[peerID] = 0
            if let existing = self.connections[peerID] {
                self.connections[peerID] = nil
                existing.cancel()
            }
            self.dial(peerID)
        }
    }

    /// Restarts discovery and immediately dials every discovered peer that isn't connected.
    func refresh() {
        queue.async {
            Self.debug("refresh")
            self.browser?.cancel()
            self.startBrowser()
            for peerID in self.discovered.keys where self.connections[peerID] == nil {
                self.attempts[peerID] = 0
                self.dial(peerID)
            }
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
                    self?.queue.asyncAfter(deadline: .now() + Self.listenerRetryDelay) { self?.startListener() }
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
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            // Ignore late callbacks from a browser replaced by `refresh()`.
            guard let self, let browser, browser === self.browser else { return }
            self.handleBrowseResults(results)
        }
        browser.stateUpdateHandler = { state in
            Self.debug("browser state: \(state)")
            if case .failed(let error) = state {
                NSLog("MediaTool: browser failed: \(error)")
            }
        }
        self.browser = browser
        browser.start(queue: queue)
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
            guard isNew else { continue }
            Self.debug("discovered \(entry.name) [\(id)]")
            deliver { $0.onPeerDiscovered?(id, entry.name) }
            attempts[id] = 0
            if identity.id < id {
                dial(id)
            } else {
                queue.asyncAfter(deadline: .now() + Self.secondaryDialDelay) { [weak self] in
                    self?.dial(id)
                }
            }
        }
    }

    // MARK: - Network changes

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Self.debug("network path: \(path.status)")
            let recovered = path.status == .satisfied && self.lastPathStatus != nil && self.lastPathStatus != .satisfied
            self.lastPathStatus = path.status
            if recovered { self.refresh() }
        }
        pathMonitor.start(queue: queue)
    }

    // MARK: - Connections

    private func isDialing(_ peerID: String) -> Bool {
        handshaking.values.contains { $0.isOutgoing && $0.peerID == peerID }
    }

    private func dial(_ peerID: String) {
        retryWork[peerID]?.cancel()
        retryWork[peerID] = nil
        guard connections[peerID] == nil, !isDialing(peerID) else { return }
        let endpoint = discovered[peerID]
            ?? .service(name: peerID, type: Self.serviceType, domain: "local.", interface: nil)
        let connection = PeerConnection(connection: NWConnection(to: endpoint, using: Self.parameters()),
                                        isOutgoing: true)
        connection.peerID = peerID
        Self.debug("dialing \(peerID)")
        setLinkState(.connecting, for: peerID)
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
        connection.onViabilityChange = { [weak self] connection, isViable in
            self?.handleViability(isViable, of: connection)
        }
        connection.onClose = { [weak self] connection in
            self?.handleClose(of: connection)
        }
        connection.start(queue: queue)
        // Covers unresolvable names and peers that never say hello.
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.handshaking[ObjectIdentifier(connection)] != nil else { return }
            Self.debug("handshake timed out: \(connection.peerID ?? "unidentified")")
            connection.cancel()
        }
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
                guard prefers(connection, over: existing, peerID: peerID) else {
                    Self.debug("dropping duplicate connection to \(peerID)")
                    connection.cancel()
                    return
                }
                existing.cancel()
            }
            connections[peerID] = connection
            attempts[peerID] = 0
            connection.connectedSince = Date()
            Self.debug("connected to \(message.senderName ?? peerID) [\(peerID)]")
            setLinkState(.connected(since: connection.connectedSince!), for: peerID)
            let name = message.senderName ?? peerID
            deliver { $0.onPeerConnected?(peerID, name) }
            return
        }

        guard let peerID = connection.peerID, connections[peerID] === connection else { return }
        deliver { $0.onMessage?(peerID, message) }
    }

    /// Both sides apply the same rule: keep the connection dialed by the smaller ID;
    /// between two dialed by the same side, the newer one (the old one is probably stale).
    private func prefers(_ candidate: PeerConnection, over existing: PeerConnection, peerID: String) -> Bool {
        func dialer(_ connection: PeerConnection) -> String {
            connection.isOutgoing ? identity.id : peerID
        }
        let candidateDialer = dialer(candidate), existingDialer = dialer(existing)
        return candidateDialer == existingDialer || candidateDialer < existingDialer
    }

    private func handleViability(_ isViable: Bool, of connection: PeerConnection) {
        guard let peerID = connection.peerID, connections[peerID] === connection,
              let since = connection.connectedSince else { return }
        setLinkState(isViable ? .connected(since: since) : .unstable(since: since), for: peerID)
    }

    private func handleClose(of connection: PeerConnection) {
        handshaking[ObjectIdentifier(connection)] = nil
        Self.debug("connection closed: \(connection.peerID ?? "unidentified")")
        guard let peerID = connection.peerID else { return }
        if connections[peerID] === connection {
            connections[peerID] = nil
        }
        guard connections[peerID] == nil, !isDialing(peerID) else { return }
        scheduleRetry(peerID)
    }

    /// Exponential backoff (2, 4, 8, 16, 30s…) while the peer is still advertised on the network.
    private func scheduleRetry(_ peerID: String) {
        guard discovered[peerID] != nil else {
            setLinkState(.idle, for: peerID)
            return
        }
        let attempt = (attempts[peerID] ?? 0) + 1
        attempts[peerID] = attempt
        let delay = min(Self.maxRetryDelay, pow(2, Double(attempt)))
        Self.debug("retry \(attempt) to \(peerID) in \(Int(delay))s")
        setLinkState(.retrying(attempt: attempt, at: Date().addingTimeInterval(delay)), for: peerID)
        let work = DispatchWorkItem { [weak self] in self?.dial(peerID) }
        retryWork[peerID]?.cancel()
        retryWork[peerID] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setLinkState(_ state: LinkState, for peerID: String) {
        guard linkStates[peerID] != state else { return }
        linkStates[peerID] = state
        deliver { $0.onLinkStateChanged?(peerID, state) }
    }

    private func deliver(_ event: @escaping (PeerService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            event(self)
        }
    }
}
