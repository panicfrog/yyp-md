import Foundation
// NSMax 需要显式导入（Swift 6 起 Foundation 不再隐式暴露部分 NS 内联函数）

/// 极简语法高亮：每语言一组正则，demo 级实现（无状态机、无嵌套语义）。
/// 覆盖 swift / c 系 / json / bash / css；未识别语言返回 nil（调用方用纯色）。
enum CodeHighlighter {

    enum TokenKind {
        case keyword, string, comment, number, type, plain
    }

    struct Rule {
        let pattern: String
        let kind: TokenKind
    }

    static func rules(for lang: String) -> [Rule]? {
        switch lang.lowercased() {
        case "swift":
            return [
                Rule(pattern: #"//[^\n]*"#, kind: .comment),
                Rule(pattern: #"/\*[\s\S]*?\*/"#, kind: .comment),
                Rule(pattern: #""(?:\\.|[^"\\\n])*""#, kind: .string),
                Rule(pattern: #"\b(?:func|let|var|class|struct|enum|protocol|extension|if|else|guard|for|while|return|switch|case|break|continue|import|public|private|internal|static|final|override|init|deinit|self|super|try|catch|throw|throws|async|await|in|where|is|as|nil|true|false|some|any)\b"#, kind: .keyword),
                Rule(pattern: #"\b\d[\d_]*(?:\.\d+)?\b"#, kind: .number),
                Rule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, kind: .type),
            ]
        case "c", "cpp", "c++", "objc", "objective-c", "java", "rust":
            return [
                Rule(pattern: #"//[^\n]*"#, kind: .comment),
                Rule(pattern: #"/\*[\s\S]*?\*/"#, kind: .comment),
                Rule(pattern: #""(?:\\.|[^"\\\n])*""#, kind: .string),
                Rule(pattern: #"'(?:\\.|[^'\\\n])'"#, kind: .string),
                Rule(pattern: #"\b(?:if|else|for|while|return|switch|case|break|continue|struct|enum|union|typedef|static|const|void|int|char|float|double|long|short|unsigned|signed|sizeof|class|public|private|protected|virtual|template|namespace|using|new|delete|this|nullptr|NULL|true|false|let|fn|pub|mut|match|impl|trait|use)\b"#, kind: .keyword),
                Rule(pattern: #"\b\d[\d_]*(?:\.\d+)?[fFulL]*\b"#, kind: .number),
                Rule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, kind: .type),
            ]
        case "json":
            return [
                Rule(pattern: #""(?:\\.|[^"\\\n])*"(?=\s*:)"#, kind: .type),   // key
                Rule(pattern: #""(?:\\.|[^"\\\n])*""#, kind: .string),
                Rule(pattern: #"\b(?:true|false|null)\b"#, kind: .keyword),
                Rule(pattern: #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, kind: .number),
            ]
        case "sh", "bash", "shell", "zsh":
            return [
                Rule(pattern: #"#[^\n]*"#, kind: .comment),
                Rule(pattern: #"(?<!\S)"(?:\\.|[^"\\])*""#, kind: .string),
                Rule(pattern: #"'[^']*'"#, kind: .string),
                Rule(pattern: #"\b(?:if|then|else|elif|fi|for|while|do|done|case|esac|function|return|local|export|source|in|echo|cd|set)\b"#, kind: .keyword),
                Rule(pattern: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, kind: .type),
                Rule(pattern: #"\b\d+\b"#, kind: .number),
            ]
        case "css":
            return [
                Rule(pattern: #"/\*[\s\S]*?\*/"#, kind: .comment),
                Rule(pattern: #"[.#]?[A-Za-z_-][A-Za-z0-9_-]*(?=\s*\{)"#, kind: .type),
                Rule(pattern: #"[A-Za-z-]+(?=\s*:)"#, kind: .keyword),
                Rule(pattern: #"#[0-9a-fA-F]{3,8}\b"#, kind: .number),
                Rule(pattern: #"\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms)?\b"#, kind: .number),
            ]
        default:
            return nil
        }
    }

    /// 整段代码 → 各字符区间的 token 类型（未匹配处为 .plain）。
    /// 返回与 code 等长的数组，O(n·rules)。
    static func tokens(for code: String, lang: String) -> [TokenKind]? {
        guard let rules = rules(for: lang) else { return nil }
        let ns = code as NSString
        let n = ns.length
        var kinds = [TokenKind](repeating: .plain, count: n)

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            regex.enumerateMatches(in: code, range: NSRange(location: 0, length: n)) { match, _, _ in
                guard let r = match?.range, r.location != NSNotFound else { return }
                // 先到先得：已被前面规则（更高优先级）着色的区间跳过
                for i in r.location..<min(r.location + r.length, n) where kinds[i] == .plain {
                    kinds[i] = rule.kind
                }
            }
        }
        return kinds
    }
}
