import SwiftUI
import UniformTypeIdentifiers

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
        case .unstable: return .yellow
        case .discovered, .connecting, .retrying: return .orange
        case .offline: return .gray.opacity(0.5)
        }
    }

    /// Human-readable status; `now` drives the retry countdown.
    func label(now: Date, lastSeen: Date?) -> String {
        switch self {
        case .connected(let since):
            return "Connected since \(since.formatted(date: .omitted, time: .shortened))"
        case .unstable:
            return "Connection unstable — waiting for the network…"
        case .connecting:
            return "Connecting…"
        case .retrying(let attempt, let at):
            let seconds = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
            return "Connection lost — retrying in \(seconds)s (attempt \(attempt))"
        case .discovered:
            return "On the network — waiting for connection…"
        case .offline:
            guard let lastSeen else { return "Offline" }
            let relative = RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: now)
            return "Offline — last seen \(relative)"
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var chat: ChatStore
    let peerID: String
    @State private var draft = ""
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

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
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip")
                }
                .help("Attach files (up to \(ByteCountFormatter.string(fromByteCount: Int64(ChatStore.maxFileSize), countStyle: .file)) each)")
                TextField("Message — Markdown supported, ⌥↩ for a new line", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(trimmedDraft.isEmpty)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .alert("Couldn't send file", isPresented: Binding(get: { errorMessage != nil },
                                                          set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        if panel.runModal() == .OK {
            sendFiles(panel.urls)
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { sendFiles(urls) }
    }

    private func sendFiles(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do {
                try chat.sendFile(at: url, to: peerID)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    private var header: some View {
        let status = chat.status(of: peerID)
        let pending = chat.pendingCount(for: peerID)
        return HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.peers[peerID]?.name ?? "Unknown Mac").font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(status.label(now: context.date, lastSeen: chat.peers[peerID]?.lastSeen))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if pending > 0 {
                    Text("\(pending) message\(pending == 1 ? "" : "s") waiting to be delivered")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            if status == .connecting {
                ProgressView().controlSize(.small)
            }
            Button {
                chat.reconnect(peerID)
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .disabled(status == .connecting)
            .help("Drop the current connection and connect again")
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
                if let attachment = message.attachment {
                    AttachmentView(message: message, attachment: attachment)
                }
                if !message.text.isEmpty {
                    MarkdownText(source: message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundColor(message.fromMe ? .white : .primary)
                        .tint(message.fromMe ? .white : .accentColor)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(message.fromMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        )
                }
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
