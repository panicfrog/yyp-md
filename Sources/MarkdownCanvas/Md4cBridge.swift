import Foundation
import CMD4C

/// md4c SAX 回调 → Swift 文档树。
///
/// 桥接要点：
/// - 回调是 C 函数指针（不可捕获上下文），builder 通过 userdata 的
///   Unmanaged 指针传递；
/// - md4c 给出的字符串一律**非零终止**，必须用指针 + size 构造；
/// - block/span 都是入栈/出栈式（enter/leave 配对），文本回调落在
///   最内层 span 或最内层文本块（P/H/TD/TH/CODE）上。
public enum MarkdownParser {

    /// demo 使用的解析 flags：表格、删除线、下划线、任务列表、宽松自动链接。
    /// （复合宏 MD_FLAG_PERMISSIVEAUTOLINKS 无法导入 Swift，拆成原子 flag。）
    public static let flags: UInt32 = UInt32(
        MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_UNDERLINE |
        MD_FLAG_TASKLISTS |
        MD_FLAG_PERMISSIVEEMAILAUTOLINKS | MD_FLAG_PERMISSIVEURLAUTOLINKS |
        MD_FLAG_PERMISSIVEWWWAUTOLINKS)

    public static func parse(_ markdown: String) -> BlockNode {
        let builder = DocumentBuilder()
        let bytes = Array(markdown.utf8)

        var parser = MD_PARSER(
            abi_version: 0,
            flags: flags,
            enter_block: { type, detail, userdata in
                documentBuilder(from: userdata)?.enterBlock(type, detail); return 0 },
            leave_block: { type, detail, userdata in
                documentBuilder(from: userdata)?.leaveBlock(type, detail); return 0 },
            enter_span: { type, detail, userdata in
                documentBuilder(from: userdata)?.enterSpan(type, detail); return 0 },
            leave_span: { type, detail, userdata in
                documentBuilder(from: userdata)?.leaveSpan(type, detail); return 0 },
            text: { kind, text, size, userdata in
                documentBuilder(from: userdata)?.text(kind, text, size); return 0 },
            debug_log: { msg, _ in
                if let msg { fputs(String(cString: msg), stderr) }
            },
            syntax: nil
        )

        let code = bytes.withUnsafeBufferPointer { buf -> Int32 in
            let ptr = buf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: MD_CHAR.self) }
            return md_parse(ptr, MD_SIZE(buf.count), &parser,
                            Unmanaged.passUnretained(builder).toOpaque())
        }
        precondition(code == 0, "md_parse failed (\(code))")

        return builder.result
    }
}

private func documentBuilder(from userdata: UnsafeMutableRawPointer?) -> DocumentBuilder? {
    userdata.flatMap { Unmanaged<DocumentBuilder>.fromOpaque($0).takeUnretainedValue() }
}

// MARK: - 树构建器

final class DocumentBuilder {
    private(set) var result: BlockNode = .doc(children: [])
    private var blockStack: [BlockBuilder] = []
    private var spanStack: [SpanBuilder] = []

    init() {
        blockStack.append(BlockBuilder(kind: .doc))
    }

    // MARK: 文本路由

    /// 文本落到最内层：span > 图片 alt > 文本块（P/H/cell）> 代码块原文。
    /// 注意：tight 列表里 md4c 完全不发 MD_BLOCK_P（见 md4c.c
    /// `if(!is_in_tight_list || block->type != MD_BLOCK_P)`），文本直接落在
    /// LI 上下文 —— 收进 li 的 spans，出栈时合成为隐式段落。
    private func appendText(_ s: String, kind: SpanNode.TextKind) {
        if let top = spanStack.last {
            if case .image = top.kind { top.alt += s } else { top.children.append(.text(s, kind: kind)) }
        } else if let b = blockStack.last {
            switch b.kind {
            case .paragraph, .heading, .cell, .li:
                b.spans.append(.text(s, kind: kind))
            case .code, .htmlBlock:
                b.text += s
            default:
                break // 其他容器块不会直接收到文本
            }
        }
    }

    // MARK: Block 回调

    func enterBlock(_ type: MD_BLOCKTYPE, _ detail: UnsafeMutableRawPointer?) {
        switch type {
        case MD_BLOCK_DOC: break
        case MD_BLOCK_QUOTE:
            push(.quote)
        case MD_BLOCK_UL:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_UL_DETAIL.self).pointee
            push(.ul(mark: char(d.mark), isTight: d.is_tight != 0))
        case MD_BLOCK_OL:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_OL_DETAIL.self).pointee
            push(.ol(start: Int(d.start), isTight: d.is_tight != 0))
        case MD_BLOCK_LI:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_LI_DETAIL.self).pointee
            push(.li(isTask: d.is_task != 0,
                     taskMark: d.is_task != 0 ? char(d.task_mark) : nil))
        case MD_BLOCK_HR:
            push(.hr)
        case MD_BLOCK_H:
            let level = Int(detail!.assumingMemoryBound(to: MD_BLOCK_H_DETAIL.self).pointee.level)
            push(.heading(level: level))
        case MD_BLOCK_CODE:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_CODE_DETAIL.self).pointee
            push(.code(lang: attributeString(d.lang)))
        case MD_BLOCK_HTML:
            push(.htmlBlock)
        case MD_BLOCK_P:
            push(.paragraph)
        case MD_BLOCK_TABLE:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_TABLE_DETAIL.self).pointee
            push(.table(colCount: Int(d.col_count)))
        case MD_BLOCK_THEAD:
            push(.tableSection(isHead: true))
        case MD_BLOCK_TBODY:
            push(.tableSection(isHead: false))
        case MD_BLOCK_TR:
            push(.tableRow)
        case MD_BLOCK_TH, MD_BLOCK_TD:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_TD_DETAIL.self).pointee
            push(.cell(align: TableAlign(d.align)))
        default:
            break // 未启用扩展的块类型不会出现
        }
    }

    func leaveBlock(_ type: MD_BLOCKTYPE, _ detail: UnsafeMutableRawPointer?) {
        let b = pop()
        switch type {
        case MD_BLOCK_DOC:
            result = .doc(children: b.children)
        case MD_BLOCK_QUOTE:
            append(.quote(children: b.children))
        case MD_BLOCK_UL:
            if case .ul(let mark, let isTight) = b.kind {
                append(.ul(mark: mark, isTight: isTight, children: b.children))
            }
        case MD_BLOCK_OL:
            if case .ol(let start, let isTight) = b.kind {
                append(.ol(start: start, isTight: isTight, children: b.children))
            }
        case MD_BLOCK_LI:
            if case .li(let isTask, let taskMark) = b.kind {
                // tight 列表：直接落在 li 上的文本合成为隐式段落（置于子块之前）
                let children = b.spans.isEmpty
                    ? b.children
                    : [.paragraph(spans: b.spans)] + b.children
                append(.li(isTask: isTask, taskMark: taskMark, children: children))
            }
        case MD_BLOCK_HR:
            append(.hr)
        case MD_BLOCK_H:
            if case .heading(let level) = b.kind {
                append(.heading(level: level, spans: b.spans))
            }
        case MD_BLOCK_CODE:
            if case .code(let lang) = b.kind {
                append(.code(lang: lang, text: b.text))
            }
        case MD_BLOCK_HTML:
            append(.code(lang: "html", text: b.text))
        case MD_BLOCK_P:
            append(.paragraph(spans: b.spans))
        case MD_BLOCK_TABLE:
            if case .table(let colCount) = b.kind {
                var columns = b.aligns
                while columns.count < colCount { columns.append(.default) }
                append(.table(columns: columns, headRows: b.headRows, bodyRows: b.bodyRows))
            }
        case MD_BLOCK_THEAD, MD_BLOCK_TBODY:
            if case .tableSection(let isHead) = b.kind {
                let table = blockStack.last
                if isHead { table?.headRows.append(contentsOf: b.rows) }
                else { table?.bodyRows.append(contentsOf: b.rows) }
            }
        case MD_BLOCK_TR:
            if case .tableRow = b.kind {
                blockStack.last?.rows.append(b.cells)
            }
        case MD_BLOCK_TH:
            if case .cell(let align) = b.kind {
                // 栈：table → section → row（cell 已弹出）
                if let row = blockStack.last {
                    row.cells.append(TableCell(spans: b.spans))
                }
                // 列对齐以表头行为准
                if let table = blockStack.dropLast(2).last {
                    table.aligns.append(align)
                }
            }
        case MD_BLOCK_TD:
            if case .cell = b.kind {
                blockStack.last?.cells.append(TableCell(spans: b.spans))
            }
        default:
            break
        }
    }

    // MARK: Span 回调

    func enterSpan(_ type: MD_SPANTYPE, _ detail: UnsafeMutableRawPointer?) {
        switch type {
        case MD_SPAN_EM: pushSpan(.em)
        case MD_SPAN_STRONG: pushSpan(.strong)
        case MD_SPAN_CODE: pushSpan(.code)
        case MD_SPAN_DEL: pushSpan(.del)
        case MD_SPAN_U: pushSpan(.u)
        case MD_SPAN_MARK: pushSpan(.mark)
        case MD_SPAN_A:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_A_DETAIL.self).pointee
            pushSpan(.link(href: attributeString(d.href)))
        case MD_SPAN_IMG:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_IMG_DETAIL.self).pointee
            pushSpan(.image(src: attributeString(d.src)))
        case MD_SPAN_LATEXMATH, MD_SPAN_LATEXMATH_DISPLAY:
            pushSpan(.latex)
        default:
            break // 未启用扩展的 span 类型不会出现
        }
    }

    func leaveSpan(_ type: MD_SPANTYPE, _ detail: UnsafeMutableRawPointer?) {
        guard let s = spanStack.popLast() else { return }
        let node: SpanNode
        switch s.kind {
        case .em: node = .em(children: s.children)
        case .strong: node = .strong(children: s.children)
        case .code: node = .code(s.children.map(plainText).joined())
        case .del: node = .del(children: s.children)
        case .u: node = .u(children: s.children)
        case .mark: node = .mark(children: s.children)
        case .link(let href): node = .link(href: href, children: s.children)
        case .image(let src): node = .image(src: src, alt: s.alt)
        case .latex: node = .latex(s.children.map(plainText).joined())
        }
        if let top = spanStack.last {
            if case .image = top.kind { top.alt += plainText(node) } else { top.children.append(node) }
        } else if let b = blockStack.last {
            switch b.kind {
            case .paragraph, .heading, .cell, .li: b.spans.append(node)
            default: break
            }
        }
    }

    // MARK: Text 回调

    func text(_ kind: MD_TEXTTYPE, _ text: UnsafePointer<MD_CHAR>?, _ size: MD_SIZE) {
        guard let text, size > 0 else { return }
        let raw = String(decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self),
            count: Int(size)), as: UTF8.self)
        switch kind {
        case MD_TEXT_NORMAL:
            appendText(raw, kind: .normal)
        case MD_TEXT_NULLCHAR:
            appendText("\u{FFFD}", kind: .normal)
        case MD_TEXT_BR:
            appendText("\n", kind: .normal) // 硬换行：排版层按换行断行
        case MD_TEXT_SOFTBR:
            appendText(" ", kind: .normal)
        case MD_TEXT_ENTITY:
            appendText(EntityDecoder.decode(raw), kind: .normal)
        case MD_TEXT_CODE:
            appendText(raw, kind: .code)
        case MD_TEXT_HTML:
            appendText(raw, kind: .html)
        case MD_TEXT_LATEXMATH:
            appendText(raw, kind: .code)
        default:
            break
        }
    }

    // MARK: 辅助

    private func push(_ kind: BlockBuilder.Kind) {
        blockStack.append(BlockBuilder(kind: kind))
    }

    @discardableResult
    private func pop() -> BlockBuilder {
        blockStack.removeLast()
    }

    private func append(_ node: BlockNode) {
        blockStack.last?.children.append(node)
    }

    private func pushSpan(_ kind: SpanBuilder.Kind) {
        spanStack.append(SpanBuilder(kind: kind))
    }

    /// MD_CHAR（Int8）→ Character
    private func char(_ c: MD_CHAR) -> Character {
        Character(UnicodeScalar(UInt8(bitPattern: c)))
    }

    /// MD_ATTRIBUTE → String（按 substr 切片，实体子串单独解码）。
    private func attributeString(_ attr: MD_ATTRIBUTE) -> String {
        guard attr.size > 0, let text = attr.text else { return "" }
        let total = Int(attr.size)
        let offsets = attr.substr_offsets!
        let types = attr.substr_types!
        var out = ""
        var i = 0
        // 不变量：offsets[0] == 0，offsets[LAST+1] == size
        while i < total {
            let start = Int(offsets[i])
            let end = i + 1 <= total ? Int(offsets[i + 1]) : total
            let endIdx = min(end, total)
            guard start < endIdx else { break }
            let slice = String(decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(text + start).assumingMemoryBound(to: UInt8.self),
                count: endIdx - start), as: UTF8.self)
            out += types[i] == MD_TEXT_ENTITY ? EntityDecoder.decode(slice) : slice
            if endIdx >= total { break }
            i += 1
        }
        return out
    }

    private func plainText(_ span: SpanNode) -> String {
        switch span {
        case .text(let s, _): return s
        case .em(let c), .strong(let c), .del(let c), .u(let c), .mark(let c), .link(_, let c):
            return c.map(plainText).joined()
        case .code(let s), .latex(let s): return s
        case .image(_, let alt): return alt
        }
    }
}

// MARK: - 构建器状态

private final class BlockBuilder {
    enum Kind {
        case doc, quote, hr, paragraph, htmlBlock
        case ul(mark: Character, isTight: Bool)
        case ol(start: Int, isTight: Bool)
        case li(isTask: Bool, taskMark: Character?)
        case heading(level: Int)
        case code(lang: String)
        case table(colCount: Int)
        case tableSection(isHead: Bool)
        case tableRow
        case cell(align: TableAlign)
    }

    let kind: Kind
    var children: [BlockNode] = []
    var spans: [SpanNode] = []
    var text: String = ""              // code / htmlBlock 原文
    var cells: [TableCell] = []        // tableRow
    var rows: [[TableCell]] = []       // tableSection
    var headRows: [[TableCell]] = []   // table
    var bodyRows: [[TableCell]] = []   // table
    var aligns: [TableAlign] = []      // table（表头列对齐）

    init(kind: Kind) {
        self.kind = kind
    }
}

private final class SpanBuilder {
    enum Kind {
        case em, strong, code, del, u, mark, latex
        case link(href: String)
        case image(src: String)
    }

    let kind: Kind
    var children: [SpanNode] = []
    var alt: String = ""               // image

    init(kind: Kind) {
        self.kind = kind
    }
}

extension TableAlign {
    init(_ align: MD_ALIGN) {
        switch align {
        case MD_ALIGN_LEFT: self = .left
        case MD_ALIGN_CENTER: self = .center
        case MD_ALIGN_RIGHT: self = .right
        default: self = .default
        }
    }
}

// MARK: - 实体解码

/// md4c 对实体只给原文（`&amp;`、`&#1234;`、`&#x12AB;`），解码自己来。
/// demo 只内置常见命名实体；未识别的按原文输出。
enum EntityDecoder {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "plusmn": "±",
        "times": "×", "divide": "÷", "middot": "·", "bull": "•",
        "dagger": "†", "sect": "§", "para": "¶", "prime": "′",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "frac12": "½", "frac14": "¼", "frac34": "¾",
        "sup1": "¹", "sup2": "²", "sup3": "³",
        "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "equiv": "≡",
        "alpha": "α", "beta": "β", "gamma": "γ", "pi": "π", "mu": "μ", "omega": "ω",
    ]

    static func decode(_ raw: String) -> String {
        guard raw.hasPrefix("&"), raw.hasSuffix(";"), raw.count >= 3 else { return raw }
        let body = String(raw.dropFirst().dropLast())
        if body.hasPrefix("#x") || body.hasPrefix("#X"),
           let v = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(v) {
            return String(Character(scalar))
        }
        if body.hasPrefix("#"), let v = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(v) {
            return String(Character(scalar))
        }
        return named[body] ?? raw
    }
}
