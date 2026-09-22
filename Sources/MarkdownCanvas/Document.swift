import Foundation

/// md4c 解析结果：块级文档树。
/// 设计取舍：demo 用值类型树（indirect enum）就够 —— 无编辑、无增量更新需求；
/// 节点类型一一对应 md4c 的 MD_BLOCKTYPE / MD_SPANTYPE，桥接层零转换损耗。
public enum BlockNode: Equatable {
    case doc(children: [BlockNode])
    case quote(children: [BlockNode])
    /// 无序列表。mark 是源码符号（- / + / *），仅用于渲染 bullet。
    case ul(mark: Character, isTight: Bool, children: [BlockNode])
    /// 有序列表。start 是起始序号。
    case ol(start: Int, isTight: Bool, children: [BlockNode])
    /// 列表项。isTask 时渲染复选框（taskMark 为 'x'/'X'/' '）。
    case li(isTask: Bool, taskMark: Character?, children: [BlockNode])
    case hr
    case heading(level: Int, spans: [SpanNode])
    /// 围栏/缩进代码块。lang 来自 info string（可为空）。
    case code(lang: String, text: String)
    case paragraph(spans: [SpanNode])
    /// 块级图片：解析层图片是 span，纯图片段落由排版层提升（见 LayoutEngine）。
    case image(src: String, alt: String)
    case table(columns: [TableAlign], headRows: [[TableCell]], bodyRows: [[TableCell]])
}

public enum TableAlign: Equatable {
    case `default`, left, center, right
}

/// 表格单元格：内容是 span 序列，空段落即空单元格。
public struct TableCell: Equatable {
    public var spans: [SpanNode]
    public init(spans: [SpanNode]) {
        self.spans = spans
    }
}

/// 行内 span。文本始终以最内层节点携带（.text），样式由祖先节点叠加。
public enum SpanNode: Equatable {
    case text(String, kind: TextKind)
    case em(children: [SpanNode])
    case strong(children: [SpanNode])
    case code(String)
    case del(children: [SpanNode])
    case u(children: [SpanNode])
    case mark(children: [SpanNode])
    case link(href: String, children: [SpanNode])
    /// 图片 span。md4c 中图片是行内节点；纯图片段落由 LayoutEngine 提升为块级图片。
    case image(src: String, alt: String)
    /// 行内 LaTeX：demo 按等宽字体原样渲染。
    case latex(String)

    /// md4c 的 MD_TEXTTYPE 归并：BR/SOFTBR 在桥接层已转成 text(" ") / 分行。
    public enum TextKind: Equatable {
        case normal
        case code
        case html          // demo 原样输出
        case entityRaw     // 未识别的实体原文（如 &nbsp;），高亮阶段再解码
    }
}

public extension BlockNode {
    /// 深度优先遍历块节点（含自身，不进入 span）。
    func walk(_ visit: (BlockNode) -> Void) {
        visit(self)
        switch self {
        case .doc(let children), .quote(let children),
             .ul(_, _, let children), .ol(_, _, let children), .li(_, _, let children):
            children.forEach { $0.walk(visit) }
        case .table, .heading, .paragraph, .hr, .code, .image:
            break
        }
    }

    var childBlocks: [BlockNode] {
        switch self {
        case .doc(let c), .quote(let c), .ul(_, _, let c), .ol(_, _, let c), .li(_, _, let c):
            return c
        default: return []
        }
    }
}

extension SpanNode {
    func walk(_ visit: (SpanNode) -> Void) {
        visit(self)
        switch self {
        case .em(let c), .strong(let c), .del(let c), .u(let c), .mark(let c), .link(_, let c):
            c.forEach { $0.walk(visit) }
        case .text, .code, .image, .latex: break
        }
    }
}
