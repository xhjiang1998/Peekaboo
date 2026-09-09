import Testing
@testable import Peekaboo

@Suite(.tags(.ui, .unit))
struct MarkdownDisplayModelTests {
    @Test
    func `parses supported block markdown in source order`() {
        let source = """
        # 标题

        - 第一项
        - 第二项

        ---

        > 引用

        ```swift
        let value = 1
        ```
        """

        let document = MarkdownDisplayDocument(source: source)

        #expect(document.blocks == [
            .heading(level: 1, inline: [.text("标题")]),
            .unorderedList([
                [.text("第一项")],
                [.text("第二项")],
            ]),
            .thematicBreak,
            .quote([.paragraph([.text("引用")])]),
            .codeBlock(language: "swift", code: "let value = 1\n"),
        ])
    }

    @Test
    func `parses supported inline markdown`() {
        let document = MarkdownDisplayDocument(
            source: "**粗体** *斜体* `代码` [链接](https://example.com)")

        #expect(document.blocks == [
            .paragraph([
                .strong([.text("粗体")]),
                .text(" "),
                .emphasis([.text("斜体")]),
                .text(" "),
                .code("代码"),
                .text(" "),
                .link(label: [.text("链接")], destination: "https://example.com"),
            ]),
        ])
    }

    @Test
    func `keeps nonempty source readable when markdown is unsupported`() {
        let source = "<details>保留这段文本</details>"
        let document = MarkdownDisplayDocument(source: source)

        #expect(!document.blocks.isEmpty)
        #expect(document.plainText.contains("保留这段文本"))
    }

    @Test
    func `keeps nested list items visibly separated`() {
        let document = MarkdownDisplayDocument(source: """
        - Parent
          - Child
        """)

        #expect(document.blocks == [
            .unorderedList([
                [.text("Parent"), .text("\n"), .text("• Child")],
            ]),
        ])
    }

    @Test
    func `separates multiple paragraphs in one list item`() {
        let document = MarkdownDisplayDocument(source: """
        - First paragraph

          Second paragraph
        """)

        #expect(document.blocks == [
            .unorderedList([
                [.text("First paragraph"), .text("\n"), .text("Second paragraph")],
            ]),
        ])
    }
}
