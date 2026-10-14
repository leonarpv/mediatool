import Foundation

/// UI-facing chat state: known peers, their status, and message history.
/// Lives on the main thread; networking is delegated to `PeerService`.
final class ChatStore: ObservableObject {
    static let maxFileSize = 8 * 1024 * 1024

    enum ChatError: LocalizedError {
        case fileTooLarge(String)

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let name):
                let limit = ByteCountFormatter.string(fromByteCount: Int64(ChatStore.maxFileSize), countStyle: .file)
                return "\"\(name)\" is larger than the \(limit) limit."
            }
        }
    }

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
    private let filesDirectory: URL

    init(identity: LocalIdentity = .current) {
        self.identity = identity
        self.service = PeerService(identity: identity)
        self.peersFile = identity.storageDirectory.appendingPathComponent("peers.json")
        self.chatsDirectory = identity.storageDirectory.appendingPathComponent("chats")
        self.filesDirectory = identity.storageDirectory.appendingPathComponent("files")
        try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
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

    /// Copies the file into the chat's storage (so resends survive the original moving) and sends it.
    func sendFile(at url: URL, to peerID: String) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxFileSize else { throw ChatError.fileTooLarge(url.lastPathComponent) }
        let attachment = Attachment(fileName: Self.safeFileName(url.lastPathComponent), size: data.count)
        let message = ChatMessage(id: UUID(), peerID: peerID, fromMe: true, text: "",
                                  sentAt: Date(), status: .pending, attachment: attachment)
        try store(data, for: message)
        messages[peerID, default: []].append(message)
        saveMessages(for: peerID)
        transmit(message)
    }

    /// Forgets a peer: deletes its history and received/sent files.
    /// A peer that is still on the network stays listed, with an empty history.
    func removePeer(_ peerID: String) {
        guard let peer = peers[peerID] else { return }
        for message in messages[peerID] ?? [] where message.attachment != nil {
            try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(message.id.uuidString))
        }
        try? FileManager.default.removeItem(at: chatFile(for: peerID))
        messages[peerID] = nil
        unread[peerID] = nil
        peers[peerID] = nil
        if status(of: peerID) != .offline {
            peers[peerID] = peer
        }
        savePeers()
    }

    /// Where an attachment's bytes live: `files/<message id>/<file name>`.
    func fileURL(for message: ChatMessage) -> URL? {
        guard let attachment = message.attachment else { return nil }
        return filesDirectory
            .appendingPathComponent(message.id.uuidString)
            .appendingPathComponent(attachment.fileName)
    }

    /// Copies an attachment to ~/Downloads, adding " (n)" if the name is taken.
    func saveToDownloads(_ message: ChatMessage) throws -> URL {
        guard let source = fileURL(for: message) else { throw CocoaError(.fileNoSuchFile) }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = downloads.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = "\(base) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
            destination = downloads.appendingPathComponent(name)
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Strips any directory components a peer might send, so files can't escape `filesDirectory`.
    private static func safeFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
        return (base.isEmpty || base == "." || base == "..") ? "file" : base
    }

    private func store(_ data: Data, for message: ChatMessage) throws {
        guard let url = fileURL(for: message) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Incoming

    private func handle(_ message: WireMessage, from peerID: String) {
        switch message.kind {
        case .text, .file:
            guard let id = message.messageID else { return }
            let ack = WireMessage(kind: .ack, senderID: identity.id, messageID: id)
            // Duplicates are acked again so the sender stops resending.
            if messages[peerID]?.contains(where: { $0.id == id }) ?? false {
                service.send(ack, to: peerID)
                return
            }
            var received = ChatMessage(id: id, peerID: peerID, fromMe: false, text: message.text ?? "",
                                       sentAt: message.sentAt ?? Date(), status: .received)
            if message.kind == .file {
                guard let name = message.fileName, let data = message.fileData else { return }
                received.attachment = Attachment(fileName: Self.safeFileName(name), size: data.count)
                // Not acked on failure, so the sender retries on the next connection.
                guard (try? store(data, for: received)) != nil else { return }
            }
            service.send(ack, to: peerID)
            messages[peerID, default: []].append(received)
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
        var wire = WireMessage(kind: .text, senderID: identity.id, messageID: message.id,
                               text: message.text, sentAt: message.sentAt)
        if let attachment = message.attachment {
            guard let url = fileURL(for: message), let data = try? Data(contentsOf: url) else { return }
            wire.kind = .file
            wire.fileName = attachment.fileName
            wire.fileData = data
        }
        service.send(wire, to: message.peerID)
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
