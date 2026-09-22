import CoreText
import CoreGraphics
import Foundation

/// 排版结果：一次排版、滚动零排版的数据基础。
/// 所有坐标为文档坐标（逻辑 pt，y 向下，原点在文档左上角）。
public final class LayoutResult {
    public private(set) var blocks: [LayoutBlock] = []   // 按 y 排序
    public private(set) var totalHeight: CGFloat = 0
    public let contentWidth: CGFloat

    init(contentWidth: CGFloat) {
        self.contentWidth = contentWidth
    }

    func append(_ block: LayoutBlock) {
        blocks.append(block)
        totalHeight = max(totalHeight, block.frame.maxY)
    }
}

/// 一个可独立绘制的块（段落、标题、代码块、表格……）。
/// 块是可视区裁剪的最小单位。
public final class LayoutBlock {
    public enum Kind {
        case text
        case code(lang: String)
        case quoteBar
        case hr
        case table(columns: [TableAlign])
        case image(src: String)
    }

    /// 可变：文本块排版完成后回填总高度。
    public internal(set) var frame: CGRect
    public let kind: Kind
    /// 文本行（text/code/table 块）。
    public private(set) var lines: [LayoutLine] = []
    /// 背景矩形（代码底色、表格斑马纹、引用竖线……，文档坐标）。
    public private(set) var backgrounds: [BackgroundRect] = []
    /// 链接命中矩形。
    public private(set) var linkRects: [(rect: CGRect, href: String)] = []

    init(frame: CGRect, kind: Kind) {
        self.frame = frame
        self.kind = kind
    }

    func addLine(_ line: LayoutLine) { lines.append(line) }
    func addBackground(_ bg: BackgroundRect) { backgrounds.append(bg) }
    func addLink(rect: CGRect, href: String) { linkRects.append((rect, href)) }
    func extendHeight(to y: CGFloat) {
        frame.size.height = max(frame.height, y - frame.minY)
    }
}

public struct BackgroundRect {
    public let rect: CGRect
    public let color: SIMD4<UInt8>
}

/// 一行文本：字形（延迟栅格化）+ 装饰 + 度量。
public final class LayoutLine {
    /// 行内容左原点（文档坐标；字形/划线的 x 均相对它）。
    public let originX: CGFloat
    /// 基线 y（文档坐标）。
    public let baselineY: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public private(set) var glyphs: [LaidGlyph] = []
    public private(set) var decorations: [LaidDecoration] = []

    init(originX: CGFloat, baselineY: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.originX = originX
        self.baselineY = baselineY
        self.ascent = ascent
        self.descent = descent
    }

    func addGlyph(_ g: LaidGlyph) { glyphs.append(g) }
    func addDecoration(_ d: LaidDecoration) { decorations.append(d) }

    var height: CGFloat { ascent + descent }
}

/// 字形记录：排版时只存几何与样式，栅格化延迟到实例生成（atlas 按需填充）。
public struct LaidGlyph {
    public let font: CTFont
    public let glyph: CGGlyph
    /// 基线相对原点（pt，y 向上，CoreText 坐标）。
    public let position: CGPoint
    /// 字形边界（pt，y 向上）。
    public let bounds: CGRect
    public let style: SpanStyleBox
}

/// 装饰：划线（相对基线，y 向上）或行内背景矩形。
public struct LaidDecoration {
    public enum Kind { case underline, strikethrough, background }

    public let kind: Kind
    /// 划线：线段 x / 宽度；背景：忽略。
    public let x: CGFloat
    public let width: CGFloat
    /// 划线：基线向上偏移（y 向上语义：删除线为正，下划线为负）；
    /// 绘制时 y = baselineY - offsetY - thickness/2（文档坐标 y 向下）。背景：忽略。
    public let offsetY: CGFloat
    public let thickness: CGFloat
    public let color: SIMD4<UInt8>
    /// 背景（.background kind）的文档坐标矩形。
    public let backgroundRect: CGRect?
}

/// 文档树 → LayoutResult。
/// demo 在调用线程同步排版（无增量需求）；块间距采用类 GitHub 的取值。
public final class LayoutEngine {

    private let theme: Theme
    private let flattener: SpanFlattener
    /// extractGlyphs 期间收集的链接矩形，随所属行落进当前块。
    private var pendingLinkRects: [(CGRect, String)] = []

    public init(theme: Theme = Theme()) {
        self.theme = theme
        self.flattener = SpanFlattener(theme: theme)
    }

    public func layout(_ doc: BlockNode, contentWidth: CGFloat? = nil,
                       imageSizes: [String: CGSize] = [:]) -> LayoutResult {
        let width = contentWidth ?? theme.contentWidth
        let result = LayoutResult(contentWidth: width)
        var cursor: CGFloat = 12
        self.imageSizes = imageSizes

        if case .doc(let children) = doc {
            for child in children {
                layout(child, into: result, x: 0, width: width,
                       cursor: &cursor, level: 0, marker: nil)
            }
        }
        return result
    }

    /// 图片像素尺寸（ImageStore 预解码后传入）。
    private var imageSizes: [String: CGSize] = [:]

    // MARK: - 块级

    private func layout(_ block: BlockNode, into result: LayoutResult,
                        x: CGFloat, width: CGFloat, cursor: inout CGFloat,
                        level: Int, marker: NSAttributedString?) {
        switch block {
        case .doc:
            break

        case .heading(let hLevel, let spans):
            let font = theme.headingFont(level: hLevel)
            let attr = attributed(spans, font: font, color: theme.heading)
            cursor += hLevel <= 2 ? 16 : 12
            layoutTextBlock(attr, kind: .text, marker: marker,
                            into: result, x: x, width: width, cursor: &cursor)
            cursor += 8

        case .paragraph(let spans):
            // 纯图片段落提升为块级图片
            if spans.count == 1, case .image(let src, let alt)? = spans.first {
                layout(.image(src: src, alt: alt), into: result, x: x, width: width,
                       cursor: &cursor, level: level, marker: nil)
                return
            }
            let attr = attributed(spans, font: theme.bodyFont(), color: theme.text)
            layoutTextBlock(attr, kind: .text, marker: marker,
                            into: result, x: x, width: width, cursor: &cursor)
            cursor += 10

        case .quote(let children):
            let barX = x + 2
            let innerX = x + theme.indentPerLevel * 0.8 + 6
            let quoteStart = cursor
            for child in children {
                layout(child, into: result, x: innerX,
                       width: width - (innerX - x), cursor: &cursor,
                       level: level + 1, marker: nil)
            }
            let height = max(0, cursor - quoteStart - 4)
            // 引用竖线（背景矩形复用为线条）
            let bar = LayoutBlock(frame: CGRect(x: barX, y: quoteStart, width: 3, height: height),
                                  kind: .quoteBar)
            bar.addBackground(BackgroundRect(
                rect: CGRect(x: barX, y: quoteStart, width: 3, height: height),
                color: theme.quoteBar))
            result.append(bar)
            cursor += 6

        case .ul(_, _, let items):
            for item in items {
                layout(item, into: result, x: x, width: width,
                       cursor: &cursor, level: level, marker: bulletMarker())
            }
            cursor += 4

        case .ol(let start, _, let items):
            for (i, item) in items.enumerated() {
                layout(item, into: result, x: x, width: width, cursor: &cursor,
                       level: level, marker: numberMarker("\(start + i)."))
            }
            cursor += 4

        case .li(_, let taskMark, let children):
            let indent = theme.indentPerLevel
            var firstMarker = marker
            if let mark = taskMark {
                firstMarker = taskMarker(checked: mark != " ")
            }
            var firstTextDone = false
            for child in children {
                if firstTextDone {
                    layout(child, into: result, x: x + indent, width: width - indent,
                           cursor: &cursor, level: level + 1, marker: nil)
                    continue
                }
                switch child {
                case .paragraph(let spans):
                    let attr = attributed(spans, font: theme.bodyFont(), color: theme.text)
                    layoutTextBlock(attr, kind: .text, marker: firstMarker,
                                    into: result, x: x, width: width, cursor: &cursor)
                    firstTextDone = true
                case .heading(let h, let spans):
                    let attr = attributed(spans, font: theme.headingFont(level: h),
                                          color: theme.heading)
                    layoutTextBlock(attr, kind: .text, marker: firstMarker,
                                    into: result, x: x, width: width, cursor: &cursor)
                    firstTextDone = true
                default:
                    layout(child, into: result, x: x, width: width,
                           cursor: &cursor, level: level + 1, marker: firstMarker)
                    firstTextDone = true
                }
            }
            cursor += 2

        case .hr:
            let b = LayoutBlock(frame: CGRect(x: x, y: cursor + 8, width: width, height: 2), kind: .hr)
            b.addBackground(BackgroundRect(rect: b.frame, color: theme.hr))
            result.append(b)
            cursor += 20

        case .code(let lang, let text):
            layoutCodeBlock(lang: lang, text: text, into: result, x: x, width: width, cursor: &cursor)

        case .table(let columns, let headRows, let bodyRows):
            layoutTable(columns: columns, headRows: headRows, bodyRows: bodyRows,
                        into: result, x: x, width: width, cursor: &cursor)

        case .image(let src, _):
            // 按内容宽度等比缩放（不放大）；未解码的图用 3:2 占位
            let pixel = imageSizes[src] ?? CGSize(width: width * 2, height: width * 1.33)
            let dispW = min(pixel.width, width)
            let dispH = pixel.width > 0 ? dispW * pixel.height / pixel.width : width * 0.66
            cursor += 6
            let b = LayoutBlock(frame: CGRect(x: x, y: cursor, width: dispW, height: dispH),
                                kind: .image(src: src))
            result.append(b)
            cursor += dispH + 12
        }
    }

    // MARK: - 列表标记

    private func bulletMarker() -> NSAttributedString {
        markerText("•", color: theme.secondary)
    }

    private func numberMarker(_ text: String) -> NSAttributedString {
        markerText(text, color: theme.text)
    }

    private func taskMarker(checked: Bool) -> NSAttributedString {
        markerText(checked ? "☑" : "☐", color: checked ? theme.taskDone : theme.taskPending)
    }

    private func markerText(_ text: String, color: SIMD4<UInt8>) -> NSAttributedString {
        NSAttributedString(string: text + "  ", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): theme.bodyFont(),
            SpanStyleAttributeName: SpanStyleBox(color: color),
        ])
    }

    // MARK: - 文本块

    private func attributed(_ spans: [SpanNode], font: CTFont, color: SIMD4<UInt8>) -> NSAttributedString {
        let pieces = flattener.flatten(spans, base: .init(color: color))
        let out = NSMutableAttributedString()
        for (piece, _) in pieces { out.append(piece) }
        return out
    }

    /// CTTypesetter 逐行断行；同一文本块的所有行聚合进一个 LayoutBlock。
    private func layoutTextBlock(_ attr: NSAttributedString, kind: LayoutBlock.Kind,
                                 marker: NSAttributedString?,
                                 into result: LayoutResult, x: CGFloat, width: CGFloat,
                                 cursor: inout CGFloat) {
        let full: NSAttributedString
        if let marker {
            let combined = NSMutableAttributedString(attributedString: marker)
            combined.append(attr)
            full = combined
        } else {
            full = attr
        }
        guard full.length > 0 else { return }

        let typesetter = CTTypesetterCreateWithAttributedString(full)
        let block = LayoutBlock(frame: CGRect(x: x, y: cursor, width: width, height: 0), kind: kind)
        var index = 0
        let total = full.length

        while index < total {
            // SuggestLineBreak 返回断行位置（CFIndex），不是 CFRange
            let breakIndex = CTTypesetterSuggestLineBreakWithOffset(typesetter, index, Double(width), 0)
            guard breakIndex > index else { break }
            let lineRange = CFRange(location: index, length: breakIndex - index)
            let line = CTTypesetterCreateLineWithOffset(typesetter, lineRange, 0)

            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let baseline = cursor + ascent
            let laid = LayoutLine(originX: x, baselineY: baseline, ascent: ascent, descent: descent)
            extractGlyphs(from: line, into: laid)
            block.addLine(laid)
            cursor += ascent + descent
            index = breakIndex
        }

        guard !block.lines.isEmpty else { return }
        block.extendHeight(to: cursor)
        for (rect, href) in pendingLinkRects { block.addLink(rect: rect, href: href) }
        pendingLinkRects.removeAll()
        result.append(block)
    }

    /// 从 CTLine 提取字形与装饰（全部文档坐标 / 基线相对量）。
    /// 字体行高（CTFont 无 lineHeight 属性）。
    private func lineHeight(of font: CTFont) -> CGFloat {
        CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    private func extractGlyphs(from line: CTLine, into laid: LayoutLine) {
        let originX = laid.originX
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let style = attrs[SpanStyleAttributeName] as? SpanStyleBox
                ?? SpanStyleBox(color: theme.text)
            let font = attrs[kCTFontAttributeName as String] != nil
                ? unsafeBitCast(attrs[kCTFontAttributeName as String] as AnyObject, to: CTFont.self)
                : theme.bodyFont()
            let href = attrs[LinkHrefAttributeName] as? String

            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            var runMinX = CGFloat.greatestFiniteMagnitude
            var runMaxX = -CGFloat.greatestFiniteMagnitude

            for i in 0..<count {
                var bounds = CGRect()
                CTFontGetBoundingRectsForGlyphs(font, .horizontal, [glyphs[i]], &bounds, 1)
                if bounds.width == 0 && bounds.height == 0 { continue } // 空格等空字形
                laid.addGlyph(LaidGlyph(font: font, glyph: glyphs[i],
                                        position: positions[i], bounds: bounds, style: style))
                runMinX = min(runMinX, positions[i].x + bounds.minX)
                runMaxX = max(runMaxX, positions[i].x + bounds.maxX)
            }
            guard runMaxX > runMinX else { continue }
            let runWidth = runMaxX - runMinX

            if style.underline {
                laid.addDecoration(LaidDecoration(
                    kind: .underline, x: runMinX, width: runWidth,
                    // CTFontGetUnderlinePosition 为负值（y 向上坐标系里基线下方），
                    // 直接作为「基线向上偏移」使用 —— 负号一旦写反，下划线就跑到
                    // 基线上方穿进字身（曾由 testUnderlineBelowStrikethroughAboveBaseline 捕获）
                    offsetY: CTFontGetUnderlinePosition(font),
                    thickness: max(1, CTFontGetUnderlineThickness(font)),
                    color: style.color, backgroundRect: nil))
            }
            if style.strikethrough {
                laid.addDecoration(LaidDecoration(
                    kind: .strikethrough, x: runMinX, width: runWidth,
                    offsetY: laid.ascent * 0.28,
                    thickness: max(1, CTFontGetUnderlineThickness(font)),
                    color: style.color, backgroundRect: nil))
            }
            if let bg = style.background {
                laid.addDecoration(LaidDecoration(
                    kind: .background, x: 0, width: 0, offsetY: 0, thickness: 0,
                    color: bg,
                    backgroundRect: CGRect(x: originX + runMinX - 3,
                                           y: laid.baselineY - laid.ascent + 2,
                                           width: runWidth + 6,
                                           height: laid.ascent + laid.descent - 2)))
            }
            if let href {
                pendingLinkRects.append((CGRect(x: originX + runMinX,
                                                y: laid.baselineY - laid.ascent,
                                                width: runWidth,
                                                height: laid.ascent + laid.descent), href))
            }
        }
    }

    // MARK: - 代码块（CodeHighlighter 着色）

    /// token 类型 → 主题色
    private func color(for kind: CodeHighlighter.TokenKind) -> SIMD4<UInt8> {
        switch kind {
        case .keyword: return theme.hlKeyword
        case .string: return theme.hlString
        case .comment: return theme.hlComment
        case .number: return theme.hlNumber
        case .type: return theme.hlType
        case .plain: return theme.codeText
        }
    }

    private func layoutCodeBlock(lang: String, text: String, into result: LayoutResult,
                                 x: CGFloat, width: CGFloat, cursor: inout CGFloat) {
        let font = theme.monoFont()
        let pad: CGFloat = 12
        cursor += 6
        let top = cursor
        let block = LayoutBlock(frame: .zero, kind: .code(lang: lang))

        // 整段 tokenize（跨行注释/字符串正确），再按行切 attributed
        let nsText = text as NSString
        let tokenKinds = CodeHighlighter.tokens(for: text, lang: lang)
        let plainStyle = SpanStyleBox(color: theme.codeText)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)

        var lineStart = 0
        while lineStart < nsText.length {
            var ls = lineStart, le = lineStart, se = lineStart
            nsText.getLineStart(&ls, end: &le, contentsEnd: &se, for: NSRange(location: lineStart, length: 0))
            let content = String(nsText.substring(with: NSRange(location: ls, length: se - ls)))
            let attr = NSMutableAttributedString()
            if content.isEmpty {
                attr.append(NSAttributedString(string: " ", attributes: [
                    fontKey: font, SpanStyleAttributeName: plainStyle,
                ]))
            } else if let kinds = tokenKinds, se > ls {
                // 合并连续同色区间
                var runStart = ls
                var runKind = kinds[ls]
                var i = ls + 1
                while i <= se {
                    if i == se || kinds[i] != runKind {
                        let sub = nsText.substring(with: NSRange(location: runStart, length: i - runStart))
                        attr.append(NSAttributedString(string: sub, attributes: [
                            fontKey: font,
                            SpanStyleAttributeName: SpanStyleBox(color: color(for: runKind)),
                        ]))
                        if i < se {
                            runStart = i
                            runKind = kinds[i]
                        }
                    }
                    i += 1
                }
            } else {
                attr.append(NSAttributedString(string: content, attributes: [
                    fontKey: font, SpanStyleAttributeName: plainStyle,
                ]))
            }

            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let baseline = cursor + ascent
            let laid = LayoutLine(originX: x + pad, baselineY: baseline, ascent: ascent, descent: descent)
            extractGlyphs(from: line, into: laid)
            block.addLine(laid)
            cursor += ascent + descent
            lineStart = le
        }
        if nsText.length == 0 {
            let attr = NSAttributedString(string: " ", attributes: [
                fontKey: font, SpanStyleAttributeName: plainStyle,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let laid = LayoutLine(originX: x + pad, baselineY: cursor + ascent, ascent: ascent, descent: descent)
            extractGlyphs(from: line, into: laid)
            block.addLine(laid)
            cursor += ascent + descent
        }

        let frame = CGRect(x: x, y: top - 6, width: width,
                           height: cursor - top + 12)
        block.frame = frame
        block.addBackground(BackgroundRect(rect: frame, color: theme.codeBackground))
        for (rect, href) in pendingLinkRects { block.addLink(rect: rect, href: href) }
        pendingLinkRects.removeAll()
        result.append(block)
        cursor += 14
    }

    // MARK: - 表格（列对齐 + 边框 + 斑马纹）

    private func layoutTable(columns: [TableAlign], headRows: [[TableCell]], bodyRows: [[TableCell]],
                             into result: LayoutResult, x: CGFloat, width: CGFloat,
                             cursor: inout CGFloat) {
        let colCount = max(1, columns.count)
        let colWidth = width / CGFloat(colCount)
        let cellPad: CGFloat = 8
        let font = theme.bodyFont()
        let headFont = theme.bodyFont(bold: true)
        let rowHeight = lineHeight(of: font) + 10

        let top = cursor
        let block = LayoutBlock(frame: CGRect(x: x, y: top, width: width, height: 0),
                                kind: .table(columns: columns))
        var y = cursor

        func layoutRow(_ cells: [TableCell], isHead: Bool) {
            let rowTop = y
            for (col, cell) in cells.enumerated() where col < colCount {
                let colX = x + CGFloat(col) * colWidth
                let cellWidth = colWidth - cellPad * 2
                let attr = attributed(cell.spans,
                                      font: isHead ? headFont : font,
                                      color: isHead ? theme.heading : theme.text)
                guard attr.length > 0 else { continue }
                let typesetter = CTTypesetterCreateWithAttributedString(attr)
                var index = 0
                let total = attr.length
                var lineY = y
                while index < total {
                    let breakIndex = CTTypesetterSuggestLineBreakWithOffset(
                        typesetter, index, Double(cellWidth), 0)
                    guard breakIndex > index else { break }
                    let lineRange = CFRange(location: index, length: breakIndex - index)
                    let line = CTTypesetterCreateLineWithOffset(typesetter, lineRange, 0)
                    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                    // 列对齐：default/left 靠左，center 居中，right 靠右
                    let align = col < columns.count ? columns[col] : TableAlign.default
                    let originX: CGFloat
                    switch align {
                    case .center: originX = colX + cellPad + (cellWidth - lineWidth) / 2
                    case .right: originX = colX + colWidth - cellPad - lineWidth
                    default: originX = colX + cellPad
                    }
                    let baseline = lineY + ascent
                    let laid = LayoutLine(originX: originX, baselineY: baseline,
                                          ascent: ascent, descent: descent)
                    extractGlyphs(from: line, into: laid)
                    block.addLine(laid)
                    lineY += ascent + descent
                    index = breakIndex
                }
            }
            y = rowTop + rowHeight
        }

        for row in headRows { layoutRow(row, isHead: true) }
        for row in bodyRows { layoutRow(row, isHead: false) }

        block.frame.size.height = y - top
        if !headRows.isEmpty {
            block.addBackground(BackgroundRect(
                rect: CGRect(x: x, y: top, width: width, height: rowHeight),
                color: theme.inlineCodeBackground))
        }
        for (i, _) in bodyRows.enumerated() where i % 2 == 1 {
            block.addBackground(BackgroundRect(
                rect: CGRect(x: x, y: top + rowHeight * CGFloat(i + 1),
                             width: width, height: rowHeight),
                color: theme.tableZebra))
        }
        // 边框：每行水平线（表头上下沿加粗）+ 每列竖线
        let rowCount = headRows.count + bodyRows.count
        let totalHeight = rowHeight * CGFloat(rowCount)
        for i in 0...rowCount {
            let ly = top + rowHeight * CGFloat(i)
            let thickness: CGFloat = (i == 0 || i == 1 || i == rowCount) ? 1 : 0.5
            block.addBackground(BackgroundRect(
                rect: CGRect(x: x, y: ly - thickness / 2, width: width, height: thickness),
                color: theme.tableBorder))
        }
        for col in 0...colCount {
            let lx = x + colWidth * CGFloat(col)
            block.addBackground(BackgroundRect(
                rect: CGRect(x: lx - 0.25, y: top, width: 0.5, height: totalHeight),
                color: theme.tableBorder))
        }
        for (rect, href) in pendingLinkRects { block.addLink(rect: rect, href: href) }
        pendingLinkRects.removeAll()
        result.append(block)
        cursor = y + 12
    }
}
