import Foundation
import MarkdownCanvas

// 用法：swift run mdprint <file.md>
// 若无参数，读 stdin。打印 md4c 解析出的文档树。

let input: String
if CommandLine.arguments.count > 1 {
    let path = CommandLine.arguments[1]
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write("无法读取文件: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    input = String(decoding: data, as: UTF8.self)
} else {
    input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

let doc = MarkdownParser.parse(input)
print(pretty(doc))

func pretty(_ node: BlockNode, indent: String = "") -> String {
    let child = indent + "  "
    switch node {
    case .doc(let c):
        return indent + "doc\n" + c.map { pretty($0, indent: child) }.joined()
    case .quote(let c):
        return indent + "quote\n" + c.map { pretty($0, indent: child) }.joined()
    case .ul(let mark, let isTight, let c):
        return indent + "ul(mark:\(mark) tight:\(isTight))\n"
            + c.map { pretty($0, indent: child) }.joined()
    case .ol(let start, let isTight, let c):
        return indent + "ol(start:\(start) tight:\(isTight))\n"
            + c.map { pretty($0, indent: child) }.joined()
    case .li(let isTask, let taskMark, let c):
        let task = isTask ? " task:\(taskMark.map(String.init) ?? "?")" : ""
        return indent + "li\(task)\n" + c.map { pretty($0, indent: child) }.joined()
    case .hr:
        return indent + "hr\n"
    case .heading(let level, let spans):
        return indent + "h\(level) " + spans.map(pretty).joined() + "\n"
    case .code(let lang, let text):
        let preview = text.prefix(40).replacingOccurrences(of: "\n", with: "\\n")
        return indent + "code(\(lang)) \"\(preview)\"\n"
    case .paragraph(let spans):
        return indent + "p " + spans.map(pretty).joined() + "\n"
    case .image(let src, let alt):
        return indent + "image(\(src)) alt:\(alt)\n"
    case .table(let columns, let head, let body):
        let aligns = columns.map { "\($0)" }.joined(separator: ",")
        var s = indent + "table(\(aligns))\n"
        s += head.map { indent + "  th-row " + $0.map { $0.spans.map(pretty).joined() }.joined(separator: " | ") + "\n" }.joined()
        s += body.map { indent + "  td-row " + $0.map { $0.spans.map(pretty).joined() }.joined(separator: " | ") + "\n" }.joined()
        return s
    }
}

func pretty(_ span: SpanNode) -> String {
    switch span {
    case .text(let s, let kind):
        let tag = kind == .normal ? "" : "!\(kind)"
        return "\(s.replacingOccurrences(of: "\n", with: "\\n"))\(tag)"
    case .em(let c): return "<em>" + c.map(pretty).joined() + "</em>"
    case .strong(let c): return "<strong>" + c.map(pretty).joined() + "</strong>"
    case .code(let s): return "<code>\(s)</code>"
    case .del(let c): return "<del>" + c.map(pretty).joined() + "</del>"
    case .u(let c): return "<u>" + c.map(pretty).joined() + "</u>"
    case .mark(let c): return "<mark>" + c.map(pretty).joined() + "</mark>"
    case .link(let href, let c): return "<a:\(href)>" + c.map(pretty).joined() + "</a>"
    case .image(let src, let alt): return "<img:\(src) alt:\(alt)>"
    case .latex(let s): return "<math>\(s)</math>"
    }
}
