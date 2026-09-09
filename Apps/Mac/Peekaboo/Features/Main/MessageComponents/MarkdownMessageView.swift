import SwiftUI

struct MarkdownMessageView: View {
    let document: MarkdownDisplayDocument

    init(markdown: String) {
        self.document = MarkdownDisplayDocument(source: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(self.document.blocks.enumerated()), id: \.offset) { _, block in
                MarkdownDisplayBlockView(block: block)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MarkdownDisplayBlockView: View {
    let block: MarkdownDisplayBlock

    var body: some View {
        switch self.block {
        case let .paragraph(inline):
            Text(MarkdownMessageRenderer.attributedString(for: inline, block: self.block))
                .fixedSize(horizontal: false, vertical: true)
        case let .heading(_, inline):
            Text(MarkdownMessageRenderer.attributedString(for: inline, block: self.block))
                .fixedSize(horizontal: false, vertical: true)
        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(MarkdownMessageRenderer.attributedString(for: item, block: self.block))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .orderedList(start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + offset).")
                            .monospacedDigit()
                        Text(MarkdownMessageRenderer.attributedString(for: item, block: self.block))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .quote(blocks):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownDisplayBlockView(block: block)
                    }
                }
            }
        case .thematicBreak:
            Divider()
        case let .codeBlock(language, code):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(8)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

}

enum MarkdownMessageTextStyle: Equatable {
    case body
    case title2
    case title3
    case headline
}

enum MarkdownMessageRenderer {
    private static let allowedLinkSchemes = Set(["http", "https", "mailto"])

    static func textStyle(for block: MarkdownDisplayBlock) -> MarkdownMessageTextStyle {
        guard case let .heading(level, _) = block else {
            return .body
        }

        switch level {
        case 1:
            return .title2
        case 2:
            return .title3
        default:
            return .headline
        }
    }

    static func attributedString(for inline: [MarkdownDisplayInline], block: MarkdownDisplayBlock) -> AttributedString {
        var result = AttributedString()
        for node in inline {
            self.append(node, to: &result, style: .init(baseFont: self.font(for: block)))
        }
        return result
    }

    static func safeLinkURL(for destination: String) -> URL? {
        guard let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              self.allowedLinkSchemes.contains(scheme)
        else {
            return nil
        }
        return url
    }

    static func font(for block: MarkdownDisplayBlock) -> Font {
        switch self.textStyle(for: block) {
        case .body:
            return .body
        case .title2:
            return .title2.weight(.bold)
        case .title3:
            return .title3.weight(.bold)
        case .headline:
            return .headline
        }
    }

    private static func append(
        _ inline: MarkdownDisplayInline,
        to result: inout AttributedString,
        style: MarkdownInlineStyle)
    {
        switch inline {
        case let .text(text):
            result += self.fragment(text, style: style)
        case let .strong(children):
            let style = MarkdownInlineStyle(
                baseFont: style.baseFont,
                isStrong: true,
                isEmphasized: style.isEmphasized,
                isCode: style.isCode,
                link: style.link)
            for child in children {
                self.append(child, to: &result, style: style)
            }
        case let .emphasis(children):
            let style = MarkdownInlineStyle(
                baseFont: style.baseFont,
                isStrong: style.isStrong,
                isEmphasized: true,
                isCode: style.isCode,
                link: style.link)
            for child in children {
                self.append(child, to: &result, style: style)
            }
        case let .code(code):
            result += self.fragment(
                code,
                style: MarkdownInlineStyle(
                    baseFont: style.baseFont,
                    isStrong: style.isStrong,
                    isEmphasized: style.isEmphasized,
                    isCode: true,
                    link: style.link))
        case let .link(label, destination):
            let style = MarkdownInlineStyle(
                baseFont: style.baseFont,
                isStrong: style.isStrong,
                isEmphasized: style.isEmphasized,
                isCode: style.isCode,
                link: self.safeLinkURL(for: destination))
            for child in label {
                self.append(child, to: &result, style: style)
            }
        }
    }

    private static func fragment(_ text: String, style: MarkdownInlineStyle) -> AttributedString {
        var fragment = AttributedString(text)
        var font = style.isCode ? style.baseFont.monospaced() : style.baseFont
        if style.isStrong {
            font = font.weight(.bold)
        }
        if style.isEmphasized {
            font = font.italic()
        }
        fragment.font = font
        fragment.link = style.link
        return fragment
    }
}

private struct MarkdownInlineStyle {
    let baseFont: Font
    let isStrong: Bool
    let isEmphasized: Bool
    let isCode: Bool
    let link: URL?

    init(
        baseFont: Font,
        isStrong: Bool = false,
        isEmphasized: Bool = false,
        isCode: Bool = false,
        link: URL? = nil)
    {
        self.baseFont = baseFont
        self.isStrong = isStrong
        self.isEmphasized = isEmphasized
        self.isCode = isCode
        self.link = link
    }
}
