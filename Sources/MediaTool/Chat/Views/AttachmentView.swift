import SwiftUI
import AppKit

/// File card shown in the chat: icon, name, size, text/JSON preview and actions.
struct AttachmentView: View {
    @EnvironmentObject private var chat: ChatStore
    let message: ChatMessage
    let attachment: Attachment

    private static let collapsedLines = 12
    private static let maxPreviewBytes = 1024 * 1024

    @State private var preview: String?
    @State private var expanded = false
    @State private var errorMessage: String?

    private var url: URL? { chat.fileURL(for: message) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName).font(.body.weight(.medium)).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let preview {
                let lines = preview.components(separatedBy: "\n")
                ScrollView(.horizontal) {
                    Text(lines.prefix(expanded ? 500 : Self.collapsedLines).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                if lines.count > Self.collapsedLines {
                    Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            HStack(spacing: 12) {
                Button { saveToDownloads() } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
                Button { reveal(url) } label: { Label("Show in Finder", systemImage: "folder") }
                if let preview {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(preview, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundColor(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .onAppear(perform: loadPreview)
    }

    private func loadPreview() {
        guard let url, attachment.size <= Self.maxPreviewBytes else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: url), let text = Self.previewText(data) else { return }
            DispatchQueue.main.async { preview = text }
        }
    }

    /// UTF-8 text only; minified (single-line) JSON is pretty-printed for readability.
    private static func previewText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("\n"),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let prettyText = String(data: pretty, encoding: .utf8) {
            return prettyText
        }
        return text
    }

    private func saveToDownloads() {
        do {
            reveal(try chat.saveToDownloads(message))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
