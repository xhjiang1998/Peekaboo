import Markdown

enum MarkdownDisplayInline: Equatable, Sendable {
    case text(String)
    case strong([Self])
    case emphasis([Self])
    case code(String)
    case link(label: [Self], destination: String)
}

indirect enum MarkdownDisplayBlock: Equatable, Sendable {
    case paragraph([MarkdownDisplayInline])
    case heading(level: Int, inline: [MarkdownDisplayInline])
    case unorderedList([[MarkdownDisplayInline]])
    case orderedList(start: Int, items: [[MarkdownDisplayInline]])
    case quote([MarkdownDisplayBlock])
    case thematicBreak
    case codeBlock(language: String?, code: String)
}

struct MarkdownDisplayDocument: Equatable, Sendable {
    let source: String
    let blocks: [MarkdownDisplayBlock]

    var plainText: String {
        self.blocks.map(Self.plainText).joined(separator: "\n")
    }

    init(source: String) {
        self.source = source

        let document = Document(parsing: source)
        let blocks = document.children.compactMap(Self.displayBlock)
        self.blocks = source.isEmpty || !blocks.isEmpty ? blocks : [.paragraph([.text(source)])]
    }
}

private extension MarkdownDisplayDocument {
    static func displayBlock(_ markup: any Markup) -> MarkdownDisplayBlock? {
        if let heading = markup as? Heading {
            return .heading(level: heading.level, inline: self.inlineNodes(in: heading))
        }

        if let paragraph = markup as? Paragraph {
            return .paragraph(self.inlineNodes(in: paragraph))
        }

        if let list = markup as? UnorderedList {
            return .unorderedList(self.listItems(in: list))
        }

        if let list = markup as? OrderedList {
            return .orderedList(start: Int(list.startIndex), items: self.listItems(in: list))
        }

        if let quote = markup as? BlockQuote {
            return .quote(quote.children.compactMap(self.displayBlock))
        }

        if markup is ThematicBreak {
            return .thematicBreak
        }

        if let codeBlock = markup as? CodeBlock {
            return .codeBlock(language: codeBlock.language, code: codeBlock.code)
        }

        let fallback = self.plainText(for: markup)
        return fallback.isEmpty ? nil : .paragraph([.text(fallback)])
    }

    static func listItems(in list: some Markup) -> [[MarkdownDisplayInline]] {
        list.children.compactMap { $0 as? ListItem }.map { item in
            var inline = [MarkdownDisplayInline]()
            for child in item.children {
                if !inline.isEmpty {
                    inline.append(.text("\n"))
                }

                if let paragraph = child as? Paragraph {
                    inline += self.inlineNodes(in: paragraph)
                } else {
                    inline.append(.text(self.listItemText(for: child)))
                }
            }
            return inline.isEmpty ? [.text(self.plainText(for: item))] : inline
        }
    }

    static func listItemText(for markup: any Markup) -> String {
        if let list = markup as? UnorderedList {
            return self.listItems(in: list)
                .map { "• \(self.plainText($0))" }
                .joined(separator: "\n")
        }

        if let list = markup as? OrderedList {
            return self.listItems(in: list)
                .enumerated()
                .map { "\(Int(list.startIndex) + $0.offset). \(self.plainText($0.element))" }
                .joined(separator: "\n")
        }

        return self.plainText(for: markup)
    }

    static func inlineNodes(in markup: some Markup) -> [MarkdownDisplayInline] {
        markup.children.flatMap { self.inlineNode(for: $0) }
    }

    static func inlineNode(for markup: any Markup) -> [MarkdownDisplayInline] {
        if let text = markup as? Markdown.Text {
            return [.text(text.string)]
        }

        if let strong = markup as? Strong {
            return [.strong(self.inlineNodes(in: strong))]
        }

        if let emphasis = markup as? Emphasis {
            return [.emphasis(self.inlineNodes(in: emphasis))]
        }

        if let code = markup as? InlineCode {
            return [.code(code.code)]
        }

        if let link = markup as? Link {
            return [.link(label: self.inlineNodes(in: link), destination: link.destination ?? "")]
        }

        if markup is SoftBreak {
            return [.text(" ")]
        }

        if markup is LineBreak {
            return [.text("\n")]
        }

        if let html = markup as? InlineHTML {
            return [.text(html.rawHTML)]
        }

        let nested = self.inlineNodes(in: markup)
        return nested.isEmpty ? [.text(self.plainText(for: markup))] : nested
    }

    static func plainText(for markup: any Markup) -> String {
        if let text = markup as? Markdown.Text {
            return text.string
        }

        if let code = markup as? InlineCode {
            return code.code
        }

        if let codeBlock = markup as? CodeBlock {
            return codeBlock.code
        }

        if let html = markup as? HTMLBlock {
            return html.rawHTML
        }

        if let html = markup as? InlineHTML {
            return html.rawHTML
        }

        if markup is SoftBreak {
            return " "
        }

        if markup is LineBreak {
            return "\n"
        }

        return markup.children.map { self.plainText(for: $0) }.joined()
    }

    static func plainText(_ block: MarkdownDisplayBlock) -> String {
        switch block {
        case let .paragraph(inline), let .heading(_, inline):
            return self.plainText(inline)
        case let .unorderedList(items):
            return items.map(self.plainText).joined(separator: "\n")
        case let .orderedList(_, items):
            return items.map(self.plainText).joined(separator: "\n")
        case let .quote(blocks):
            return blocks.map(self.plainText).joined(separator: "\n")
        case .thematicBreak:
            return ""
        case let .codeBlock(_, code):
            return code
        }
    }

    static func plainText(_ inline: [MarkdownDisplayInline]) -> String {
        inline.map(self.plainText).joined()
    }

    static func plainText(_ inline: MarkdownDisplayInline) -> String {
        switch inline {
        case let .text(text), let .code(text):
            return text
        case let .strong(children), let .emphasis(children), let .link(label: children, destination: _):
            return self.plainText(children)
        }
    }
}
