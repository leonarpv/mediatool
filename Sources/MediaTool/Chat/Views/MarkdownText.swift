import SwiftUI

/// Lightweight Markdown renderer for chat bubbles.
/// Block level (code fences, headings, lists) is parsed here; inline syntax
/// (bold, italic, `code`, ~~strike~~, links) is handled by `AttributedString`.
struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                Text(Self.inline(text))
            }
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.12)))
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, text: String)
    case code(String)

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]? = nil

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = trimmed.firstMatch(of: #/^(#{1,6})\s+(.+)$/#) {
                flushParagraph()
                blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
            } else if let item = trimmed.firstMatch(of: #/^[-*+]\s+(.+)$/#) {
                flushParagraph()
                blocks.append(.listItem(marker: "•", text: String(item.1)))
            } else if let item = trimmed.firstMatch(of: #/^(\d+)[.)]\s+(.+)$/#) {
                flushParagraph()
                blocks.append(.listItem(marker: "\(item.1).", text: String(item.2)))
            } else {
                paragraph.append(line)
            }
        }

        // An unclosed fence still renders as code.
        if let lines = code {
            blocks.append(.code(lines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }
}
