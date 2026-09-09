import Testing
@testable import Peekaboo

@Suite(.tags(.ui, .unit))
struct MarkdownMessageViewTests {
    @Test
    func `heading uses a larger base text style than a paragraph`() {
        let heading = MarkdownDisplayBlock.heading(level: 1, inline: [.text("Heading")])
        let paragraph = MarkdownDisplayBlock.paragraph([.text("Paragraph")])

        #expect(MarkdownMessageRenderer.textStyle(for: heading) == .title2)
        #expect(MarkdownMessageRenderer.textStyle(for: paragraph) == .body)
    }
}
