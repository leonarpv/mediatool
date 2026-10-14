import Foundation

/// This Mac's identity on the local network. The ID is generated once and persisted.
/// Set `MEDIATOOL_INSTANCE=<name>` to run a second, independent instance on the same Mac for testing.
struct LocalIdentity {
    let id: String
    let name: String
    let instance: String?

    static let current: LocalIdentity = {
        let env = ProcessInfo.processInfo.environment["MEDIATOOL_INSTANCE"]
        let instance = (env?.isEmpty ?? true) ? nil : env
        let key = "peerID" + (instance.map { "-\($0)" } ?? "")
        let defaults = UserDefaults.standard
        let id: String
        if let saved = defaults.string(forKey: key) {
            id = saved
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: key)
        }
        var name = Host.current().localizedName ?? "Mac"
        if let instance { name += " (\(instance))" }
        return LocalIdentity(id: id, name: name, instance: instance)
    }()

    var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MediaTool" + (instance.map { "-\($0)" } ?? ""))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

struct Peer: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var lastSeen: Date?
}

enum PeerStatus {
    case offline      // known from history, not visible on the network
    case discovered   // advertised via Bonjour, not connected yet
    case connected    // handshake done, messages flow
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case pending    // sent by me, not yet acknowledged
        case delivered  // sent by me, acknowledged by the peer
        case received   // sent by the peer
    }

    let id: UUID
    let peerID: String
    let fromMe: Bool
    let text: String
    let sentAt: Date
    var status: Status
    var attachment: Attachment? = nil
}

/// A file sent along with a message. The bytes live on disk, see `ChatStore.fileURL(for:)`.
struct Attachment: Codable, Hashable {
    let fileName: String
    let size: Int
}

/// Message exchanged over the wire, framed as a 4-byte big-endian length + JSON payload.
struct WireMessage: Codable {
    static let protocolVersion = 1

    enum Kind: String, Codable {
        case hello  // first message on every connection: who am I
        case text
        case file   // `fileName` + `fileData`, sent in a single frame
        case ack    // confirms receipt of `messageID`
    }

    var kind: Kind
    var senderID: String
    var senderName: String? = nil
    var version: Int? = nil
    var messageID: UUID? = nil
    var text: String? = nil
    var sentAt: Date? = nil
    var fileName: String? = nil
    var fileData: Data? = nil
}
