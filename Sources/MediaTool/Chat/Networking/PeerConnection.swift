import Foundation
import Network

/// Wraps an `NWConnection` with length-prefixed JSON framing.
/// All callbacks run on the queue passed to `start(queue:)`.
final class PeerConnection {
    /// Fits `ChatStore.maxFileSize` once base64-encoded inside the JSON frame.
    private static let maxFrameSize = 16 << 20

    let connection: NWConnection
    let isOutgoing: Bool
    /// Set once the peer's `hello` arrives.
    var peerID: String?
    /// Set when this becomes the active connection for `peerID`.
    var connectedSince: Date?

    var onReady: ((PeerConnection) -> Void)?
    var onMessage: ((PeerConnection, WireMessage) -> Void)?
    var onViabilityChange: ((PeerConnection, Bool) -> Void)?
    var onClose: ((PeerConnection) -> Void)?

    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, isOutgoing: Bool) {
        self.connection = connection
        self.isOutgoing = isOutgoing
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            PeerService.debug("connection \(self.peerID ?? "?") state: \(state)")
            switch state {
            case .ready:
                self.onReady?(self)
            case .waiting:
                // Unreachable or refused; give up and let the service retry later.
                self.cancel()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.viabilityUpdateHandler = { [weak self] isViable in
            guard let self else { return }
            PeerService.debug("connection \(self.peerID ?? "?") viable: \(isViable)")
            self.onViabilityChange?(self, isViable)
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ message: WireMessage) {
        guard !closed, let payload = try? JSONEncoder().encode(message) else { return }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.cancel() }
        })
    }

    func cancel() {
        connection.cancel()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?(self)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                self.cancel()
                return
            }
            if !self.closed { self.receiveNext() }
        }
    }

    private func drainFrames() {
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length <= Self.maxFrameSize else {
                cancel()
                return
            }
            guard buffer.count >= 4 + length else { return }
            let payload = buffer[(start + 4)..<(start + 4 + length)]
            buffer = Data(buffer[(start + 4 + length)...])
            if let message = try? JSONDecoder().decode(WireMessage.self, from: payload) {
                onMessage?(self, message)
            }
        }
    }
}
