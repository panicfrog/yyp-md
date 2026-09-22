import XCTest
@testable import MarkdownCanvas

final class Md4cBridgeTests: XCTestCase {

    func testParagraphWithStyledSpans() {
        let doc = MarkdownParser.parse("hello **world** and *italic* `code`")
        guard case .doc(let blocks) = doc, case .paragraph(let spans)? = blocks.first else {
            return XCTFail("期望 doc > paragraph")
        }
        XCTAssertEqual(spans.count, 6)
        XCTAssertEqual(spans[0], .text("hello ", kind: .normal))
        XCTAssertEqual(spans[1], .strong(children: [.text("world", kind: .normal)]))
        XCTAssertEqual(spans[3], .em(children: [.text("italic", kind: .normal)]))
        XCTAssertEqual(spans[5], .code("code"))
    }

    func testHeadings() {
        let doc = MarkdownParser.parse("## 标题二级")
        guard case .doc(let blocks) = doc,
              case .heading(let level, let spans)? = blocks.first else {
            return XCTFail("期望 heading")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(spans, [.text("标题二级", kind: .normal)])
    }

    func testStrikethroughUnderline() {
        let doc = MarkdownParser.parse("~~gone~~ __kept__")
        guard case .doc(let blocks) = doc, case .paragraph(let spans)? = blocks.first else {
            return XCTFail("期望 paragraph")
        }
        XCTAssertEqual(spans[0], .del(children: [.text("gone", kind: .normal)]))
        // MD_FLAG_UNDERLINE 下每个 `_` 字符各产生一层 U span（见 md4c.c 的
        // `while(off < mark->end) MD_ENTER_SPAN(MD_SPAN_U, ...)`）
        XCTAssertEqual(spans[2], .u(children: [.u(children: [.text("kept", kind: .normal)])]))
    }

    func testNestedList() {
        let md = "- a\n- b\n    - c\n"
        let doc = MarkdownParser.parse(md)
        guard case .doc(let blocks) = doc,
              case .ul(let mark, _, let items)? = blocks.first else {
            return XCTFail("期望 ul")
        }
        XCTAssertEqual(mark, "-")
        XCTAssertEqual(items.count, 2)
        guard case .li(_, _, let inner)? = items.last else { return XCTFail("期望 li") }
        // tight li: children = [合成段落, 嵌套 ul]
        guard case .ul(_, _, let nested)? = inner.last else {
            return XCTFail("期望嵌套 ul")
        }
        XCTAssertEqual(nested.count, 1)
    }

    func testTaskList() {
        let doc = MarkdownParser.parse("- [x] done\n- [ ] todo\n")
        guard case .doc(let blocks) = doc, case .ul(_, _, let items)? = blocks.first else {
            return XCTFail("期望 ul")
        }
        XCTAssertEqual(items.count, 2)
        guard case .li(let isTask, let mark, _) = items[0] else { return XCTFail() }
        XCTAssertTrue(isTask)
        XCTAssertEqual(mark, "x")
    }

    func testCodeBlockWithLang() {
        let doc = MarkdownParser.parse("```swift\nlet a = 1\n```\n")
        guard case .doc(let blocks) = doc, case .code(let lang, let text)? = blocks.first else {
            return XCTFail("期望 code")
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(text, "let a = 1\n")
    }

    func testTable() {
        let md = "| L | C | R |\n|:--|:-:|--:|\n| a | b | c |\n"
        let doc = MarkdownParser.parse(md)
        guard case .doc(let blocks) = doc,
              case .table(let columns, let head, let body)? = blocks.first else {
            return XCTFail("期望 table")
        }
        XCTAssertEqual(columns, [.left, .center, .right])
        XCTAssertEqual(head.count, 1)
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(head[0][0].spans, [.text("L", kind: .normal)])
        XCTAssertEqual(body[0][0].spans, [.text("a", kind: .normal)])
    }

    func testBlockquoteAndHr() {
        let doc = MarkdownParser.parse("> quoted\n\n---\n")
        guard case .doc(let blocks) = doc else { return XCTFail() }
        guard case .quote(let children)? = blocks.first,
              case .paragraph(let spans)? = children.first else {
            return XCTFail("期望 quote > paragraph")
        }
        XCTAssertEqual(spans, [.text("quoted", kind: .normal)])
        guard case .hr = blocks[1] else { return XCTFail("期望 hr") }
    }

    func testEntities() {
        let doc = MarkdownParser.parse("a &amp; b &#x4E2D; c")
        guard case .doc(let blocks) = doc, case .paragraph(let spans)? = blocks.first else {
            return XCTFail("期望 paragraph")
        }
        let text = spans.compactMap { span -> String? in
            if case .text(let s, _) = span { return s } else { return nil }
        }.joined()
        XCTAssertEqual(text, "a & b 中 c")
    }

    func testImage() {
        let doc = MarkdownParser.parse("![alt text](img/pic.png)")
        guard case .doc(let blocks) = doc, case .paragraph(let spans)? = blocks.first else {
            return XCTFail("期望 paragraph")
        }
        XCTAssertEqual(spans, [.image(src: "img/pic.png", alt: "alt text")])
    }

    func testLink() {
        let doc = MarkdownParser.parse("see [docs](https://example.com/a?b=1)")
        guard case .doc(let blocks) = doc, case .paragraph(let spans)? = blocks.first else {
            return XCTFail("期望 paragraph")
        }
        XCTAssertEqual(spans[1], .link(href: "https://example.com/a?b=1",
                                        children: [.text("docs", kind: .normal)]))
    }

    func testHardBreak() {
        let doc = MarkdownParser.parse("line1  \nline2")
        guard case .doc(let blocks) = doc, case .paragraph(let spans)? = blocks.first else {
            return XCTFail("期望 paragraph")
        }
        XCTAssertTrue(spans.contains { if case .text("\n", kind: .normal) = $0 { return true }; return false })
    }

    func testTightListHasNoParagraphs() {
        // tight 列表：md4c 完全不发 MD_BLOCK_P，文本直接落在 LI 上下文，
        // 桥接层须把它合成为隐式段落。
        let doc = MarkdownParser.parse("- a\n- b\n")
        guard case .doc(let blocks) = doc,
              case .ul(_, let isTight, let items)? = blocks.first else { return XCTFail() }
        XCTAssertTrue(isTight)
        guard case .li(_, _, let children)? = items.first,
              case .paragraph(let spans)? = children.first,
              case .text("a", kind: .normal)? = spans.first else {
            return XCTFail("tight li 的文本应合成为隐式段落")
        }
    }
}
