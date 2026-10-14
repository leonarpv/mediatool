import Foundation

/// UI-facing chat state: known peers, their status, and message history.
/// Lives on the main thread; networking is delegated to `PeerService`.
final class ChatStore: ObservableObject {
    @Published private(set) var peers: [String: Peer] = [:]
    @Published private(set) var messages: [String: [ChatMessage]] = [:]
    @Published private(set) var unread: [String: Int] = [:]
    @Published private var discovered: Set<String> = []
    @Published private var connected: Set<String> = []

    /// The peer whose chat is currently open; its messages don't count as unread.
    var activePeerID: String? {
        didSet {
            if let id = activePeerID { unread[id] = nil }
        }
    }

    let identity: LocalIdentity
    private let service: PeerService
    private let peersFile: URL
    private let chatsDirectory: URL

    init(identity: LocalIdentity = .current) {
        self.identity = identity
        self.service = PeerService(identity: identity)
        self.peersFile = identity.storageDirectory.appendingPathComponent("peers.json")
        self.chatsDirectory = identity.storageDirectory.appendingPathComponent("chats")
        try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        load()

        service.onPeerDiscovered = { [weak self] id, name in
            self?.discovered.insert(id)
            self?.upsertPeer(id: id, name: name)
        }
        service.onPeerLost = { [weak self] id in
            self?.discovered.remove(id)
        }
        service.onPeerConnected = { [weak self] id, name in
            guard let self else { return }
            self.connected.insert(id)
            self.upsertPeer(id: id, name: name)
            self.flushPending(to: id)
        }
        service.onPeerDisconnected = { [weak self] id in
            self?.connected.remove(id)
        }
        service.onMessage = { [weak self] from, message in
            self?.handle(message, from: from)
        }
        service.start()
    }

    var sortedPeers: [Peer] {
        peers.values.sorted { lhs, rhs in
            let l = status(of: lhs.id), r = status(of: rhs.id)
            if (l == .offline) != (r == .offline) { return r == .offline }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func status(of peerID: String) -> PeerStatus {
        if connected.contains(peerID) { return .connected }
        if discovered.contains(peerID) { return .discovered }
        return .offline
    }

    func send(_ text: String, to peerID: String) {
        let message = ChatMessage(id: UUID(), peerID: peerID, fromMe: true, text: text,
                                  sentAt: Date(), status: .pending)
        messages[peerID, default: []].append(message)
        saveMessages(for: peerID)
        transmit(message)
    }

    // MARK: - Incoming

    private func handle(_ message: WireMessage, from peerID: String) {
        switch message.kind {
        case .text:
            guard let id = message.messageID, let text = message.text else { return }
            // Always ack, even duplicates, so the sender stops resending.
            service.send(WireMessage(kind: .ack, senderID: identity.id, messageID: id), to: peerID)
            guard !(messages[peerID]?.contains { $0.id == id } ?? false) else { return }
            messages[peerID, default: []].append(
                ChatMessage(id: id, peerID: peerID, fromMe: false, text: text,
                            sentAt: message.sentAt ?? Date(), status: .received))
            if activePeerID != peerID {
                unread[peerID, default: 0] += 1
            }
            saveMessages(for: peerID)
        case .ack:
            guard let id = message.messageID,
                  let index = messages[peerID]?.firstIndex(where: { $0.id == id }) else { return }
            messages[peerID]?[index].status = .delivered
            saveMessages(for: peerID)
        case .hello:
            break
        }
    }

    // MARK: - Outgoing

    private func transmit(_ message: ChatMessage) {
        service.send(WireMessage(kind: .text, senderID: identity.id, messageID: message.id,
                                 text: message.text, sentAt: message.sentAt),
                     to: message.peerID)
    }

    /// Resends everything not yet acknowledged; the receiver dedupes by message ID.
    private func flushPending(to peerID: String) {
        for message in messages[peerID] ?? [] where message.status == .pending {
            transmit(message)
        }
    }

    private func upsertPeer(id: String, name: String) {
        peers[id] = Peer(id: id, name: name, lastSeen: Date())
        savePeers()
    }

    // MARK: - Persistence

    private func chatFile(for peerID: String) -> URL {
        chatsDirectory.appendingPathComponent("\(peerID).json")
    }

    private func load() {
        if let data = try? Data(contentsOf: peersFile),
           let saved = try? JSONDecoder().decode([Peer].self, from: data) {
            peers = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }
        for id in peers.keys {
            if let data = try? Data(contentsOf: chatFile(for: id)),
               let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                messages[id] = saved
            }
        }
    }

    private func savePeers() {
        if let data = try? JSONEncoder().encode(Array(peers.values)) {
            try? data.write(to: peersFile, options: .atomic)
        }
    }

    private func saveMessages(for peerID: String) {
        if let data = try? JSONEncoder().encode(messages[peerID] ?? []) {
            try? data.write(to: chatFile(for: peerID), options: .atomic)
        }
    }
}
