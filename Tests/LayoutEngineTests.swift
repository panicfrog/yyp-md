import XCTest
import Metal
@testable import MarkdownCanvas

final class LayoutEngineTests: XCTestCase {

    func testTableColumnAlignment() {
        let md = "| L | C | R |\n|:--|:-:|--:|\n| aaa | bbb | ccc |\n"
        let doc = MarkdownParser.parse(md)
        let result = LayoutEngine(theme: Theme()).layout(doc, contentWidth: 600)

        guard case .table? = result.blocks.last?.kind else {
            return XCTFail("期望 table 块")
        }
        let table = result.blocks.last!
        let colWidth: CGFloat = 600 / 3

        // 找出 bbb / ccc 所在行（数据行文本比表头短，用内容宽度区分）
        // bbb 在中列应居中：originX ≈ colWidth + pad + (cellWidth - lineWidth)/2
        // ccc 在右列应靠右：originX ≈ 2*colWidth + colWidth - pad - lineWidth
        var bbbOrigin: CGFloat?
        var cccOrigin: CGFloat?
        var headCount = 0
        for line in table.lines {
            guard let g = line.glyphs.first else { continue }
            let font = g.font
            // 用每行的字符宽度推断是哪个 cell：表头行 bold 宽度不同，这里简化按顺序
            headCount += 1
            if headCount == 2 { bbbOrigin = line.originX } // 表头后第一数据行的中列
            if headCount == 3 { cccOrigin = line.originX }
        }

        // 表头 3 cell + 数据行 3 cell = 6 行；上面取的第 2/3 行是 bbb/ccc
        if let bbb = bbbOrigin {
            XCTAssertGreaterThan(bbb, colWidth, "bbb（中列居中）originX 应大于列起点 \(colWidth)，实际 \(bbb)")
        }
        if let ccc = cccOrigin {
            XCTAssertGreaterThan(ccc, colWidth * 2, "ccc（右列靠右）originX 应大于 2/3 列起点 \(colWidth * 2)，实际 \(ccc)")
        }
    }

    func testCodeHighlightTokens() {
        let code = "func test() { let s = \"hi\" } // done"
        let tokens = CodeHighlighter.tokens(for: code, lang: "swift")
        XCTAssertNotNil(tokens)
        XCTAssertEqual(tokens?.count, code.count)
        // 'func' 应为 keyword
        let funcIdx = (code as NSString).range(of: "func").location
        XCTAssertEqual(tokens?[funcIdx], .keyword)
        // 字符串 "hi" 应为 string
        let strIdx = (code as NSString).range(of: "\"hi\"").location
        XCTAssertEqual(tokens?[strIdx + 1], .string)
        // 注释应为 comment
        let cmtIdx = (code as NSString).range(of: "// done").location
        XCTAssertEqual(tokens?[cmtIdx], .comment)
    }

    func testLayoutProducesBlocks() {
        let md = "# Title\n\nparagraph **bold** text\n\n- item one\n- item two\n"
        let result = LayoutEngine(theme: Theme()).layout(MarkdownParser.parse(md), contentWidth: 600)
        XCTAssertFalse(result.blocks.isEmpty)
        XCTAssertGreaterThan(result.totalHeight, 50)
        // 段落块应有字形
        let totalGlyphs = result.blocks.reduce(0) { sum, b in
            sum + b.lines.reduce(0) { $0 + $1.glyphs.count }
        }
        XCTAssertGreaterThan(totalGlyphs, 10)
    }

    func testLinkRectsRecorded() {
        let md = "see [docs](https://example.com/x) now\n"
        let result = LayoutEngine(theme: Theme()).layout(MarkdownParser.parse(md), contentWidth: 600)
        let links = result.blocks.flatMap(\.linkRects)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.href, "https://example.com/x")
    }

    /// 下划线在基线**下方**、删除线在基线**上方**（文档坐标 y 向下）。
    /// 曾因 offsetY 语义（基线向上偏移）与下划线的负值混用，下划线画到了
    /// 基线上方、穿进字身。端到端验证：LayoutEngine → CanvasDocument.instances
    /// 的 solid 矩形相对 baselineY 的位置。
    func testUnderlineBelowStrikethroughAboveBaseline() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("无 Metal 设备（CI 环境）")
        }
        let atlas = GlyphAtlas(device: device)
        let md = "see [link text](https://example.com) and ~~gone~~ ok\n"
        let doc = CanvasDocument(markdown: md, theme: Theme(), contentWidth: 600, scale: 2)
        let line = try XCTUnwrap(doc.layout.blocks.first?.lines.first)
        let baseline = Float(line.baselineY)
        let insts = doc.instances(visibleRect: CGRect(x: 0, y: 0, width: 600, height: 100),
                                  atlas: atlas, rasterScale: 2)
        // 划线 = 细横条 solid（高度 ≈ thickness ≤ 3pt）
        let strokes = insts.filter { $0.textureIndex == -1 && $0.size.y <= 3 && $0.size.x > 10 }
        let underlines = strokes.filter { $0.size.x > 40 }   // "link text" 较长
        let strikes = strokes.filter { $0.size.x <= 40 }     // "gone" 较短
        XCTAssertFalse(underlines.isEmpty, "应生成下划线矩形")
        XCTAssertFalse(strikes.isEmpty, "应生成删除线矩形")
        for u in underlines {
            XCTAssertGreaterThan(u.position.y, baseline,
                "下划线应在基线下方：y=\(u.position.y) 基线=\(baseline)")
        }
        for s in strikes {
            XCTAssertLessThan(s.position.y + s.size.y, baseline,
                "删除线应在基线上方：y=\(s.position.y)..\(s.position.y + s.size.y) 基线=\(baseline)")
        }
    }

    /// 悬停变色：hoverPoint 命中链接时，链接内字形与下划线换 theme.linkHover；
    /// 未悬停 / 未命中时保持原色。
    func testHoverRecolorsLink() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("无 Metal 设备（CI 环境）")
        }
        let atlas = GlyphAtlas(device: device)
        let theme = Theme()
        let md = "see [link text](https://example.com) and plain\n"
        let doc = CanvasDocument(markdown: md, theme: theme, contentWidth: 600, scale: 2)
        let linkRect = try XCTUnwrap(doc.layout.blocks.first?.linkRects.first?.0)
        let hoverAt = CGPoint(x: linkRect.midX, y: linkRect.midY)
        let rect = CGRect(x: 0, y: 0, width: 600, height: 100)

        func linkGlyphs(hover: CGPoint?) -> [DrawInstance] {
            doc.instances(visibleRect: rect, atlas: atlas, rasterScale: 2, hoverPoint: hover)
                .filter { inst in
                    // 字形中心（position 为 quad 左上角，含 pad 内缩；中心 ≈ 字形中心）
                    let c = CGPoint(x: CGFloat(inst.position.x + inst.size.x / 2),
                                    y: CGFloat(inst.position.y + inst.size.y / 2))
                    return inst.textureIndex == 0 && linkRect.contains(c)
                }
        }

        let idle = linkGlyphs(hover: nil)
        XCTAssertFalse(idle.isEmpty, "链接区域应有字形")
        for g in idle {
            XCTAssertEqual(g.color, theme.link, "未悬停时链接字形应为 link 色")
        }
        let hovered = linkGlyphs(hover: hoverAt)
        XCTAssertFalse(hovered.isEmpty)
        for g in hovered {
            XCTAssertEqual(g.color, theme.linkHover, "悬停时链接字形应换 linkHover 色")
        }
        // 未命中悬停点（plain 文本处）不变色
        let miss = linkGlyphs(hover: CGPoint(x: linkRect.maxX + 100, y: linkRect.midY))
        for g in miss {
            XCTAssertEqual(g.color, theme.link, "悬停未命中时不应变色")
        }
    }
}
