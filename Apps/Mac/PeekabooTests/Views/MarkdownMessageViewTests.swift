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

    @Test
    func `links only allow web and email destinations`() {
        #expect(MarkdownMessageRenderer.safeLinkURL(for: "https://example.com") != nil)
        #expect(MarkdownMessageRenderer.safeLinkURL(for: "mailto:hello@example.com") != nil)
        #expect(MarkdownMessageRenderer.safeLinkURL(for: "javascript:alert(1)") == nil)
        #expect(MarkdownMessageRenderer.safeLinkURL(for: "file:///etc/passwd") == nil)
    }
}
