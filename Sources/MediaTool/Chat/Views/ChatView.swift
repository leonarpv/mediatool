import SwiftUI

struct PeerRow: View {
    let peer: Peer
    let status: PeerStatus
    let unread: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
            Text(peer.name).lineLimit(1)
            Spacer()
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
        }
    }
}

extension PeerStatus {
    var color: Color {
        switch self {
        case .connected: return .green
        case .discovered: return .orange
        case .offline: return .gray.opacity(0.5)
        }
    }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .discovered: return "Connecting…"
        case .offline: return "Offline — messages will be sent when it reconnects"
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var chat: ChatStore
    let peerID: String
    @State private var draft = ""

    private var messages: [ChatMessage] { chat.messages[peerID] ?? [] }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: messages.last?.id) { id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(trimmedDraft.isEmpty)
            }
            .padding(10)
        }
    }

    private var header: some View {
        let status = chat.status(of: peerID)
        return HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.peers[peerID]?.name ?? "Unknown Mac").font(.headline)
                Text(status.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        chat.send(text, to: peerID)
        draft = ""
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 60) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundColor(message.fromMe ? .white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(message.fromMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    )
                HStack(spacing: 4) {
                    Text(message.sentAt, style: .time)
                    if message.fromMe {
                        Image(systemName: message.status == .delivered ? "checkmark" : "clock")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !message.fromMe { Spacer(minLength: 60) }
        }
    }
}
