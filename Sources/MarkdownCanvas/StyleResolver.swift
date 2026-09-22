import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 渲染主题：调色板 + 字体。
/// demo 默认暗色（画布 clearColor 深色），M6 增加亮色与切换。
public struct Theme {

    // MARK: 调色板

    public var background: SIMD4<UInt8> = rgba(0x1C1C1E)
    public var text: SIMD4<UInt8> = rgba(0xE8E8E8)
    public var secondary: SIMD4<UInt8> = rgba(0x9D9DA3)
    public var heading: SIMD4<UInt8> = rgba(0xFFFFFF)
    public var link: SIMD4<UInt8> = rgba(0x6CB6FF)
    /// 链接悬停色（hover 时字形与下划线换色）
    public var linkHover: SIMD4<UInt8> = rgba(0x9BD1FF)
    public var inlineCodeText: SIMD4<UInt8> = rgba(0xE6C07B)
    public var inlineCodeBackground: SIMD4<UInt8> = rgba(0x2C2C30)
    public var codeText: SIMD4<UInt8> = rgba(0xD5D5DB)
    public var codeBackground: SIMD4<UInt8> = rgba(0x242428)
    public var quoteText: SIMD4<UInt8> = rgba(0xB8B8BE)
    public var quoteBar: SIMD4<UInt8> = rgba(0x5A5A60)
    public var hr: SIMD4<UInt8> = rgba(0x3A3A3E)
    public var tableBorder: SIMD4<UInt8> = rgba(0x4A4A50)
    public var tableZebra: SIMD4<UInt8> = rgba(0x242428)
    public var markBackground: SIMD4<UInt8> = rgba(0x665C1E)
    public var taskDone: SIMD4<UInt8> = rgba(0x4CAF50)
    public var taskPending: SIMD4<UInt8> = rgba(0x66666A)

    // 语法高亮（M3 CodeHighlighter 使用）
    public var hlKeyword: SIMD4<UInt8> = rgba(0xC678DD)
    public var hlString: SIMD4<UInt8> = rgba(0x98C379)
    public var hlComment: SIMD4<UInt8> = rgba(0x7F848E)
    public var hlNumber: SIMD4<UInt8> = rgba(0xD19A66)
    public var hlType: SIMD4<UInt8> = rgba(0xE5C07B)

    // MARK: 字体

    public var bodySize: CGFloat = 16
    public var codeSize: CGFloat = 14
    public var headingSizes: [CGFloat] = [28, 24, 20, 17, 15, 14]   // h1...h6
    public var contentWidth: CGFloat = 720
    /// 列表/引用每级缩进
    public var indentPerLevel: CGFloat = 22

    public init() {}

    /// 亮色主题（默认构造为暗色）。
    public static func light() -> Theme {
        var t = Theme()
        t.background = rgba(0xFFFFFF)
        t.text = rgba(0x24292F)
        t.secondary = rgba(0x57606A)
        t.heading = rgba(0x1F2328)
        t.link = rgba(0x0969DA)
        t.linkHover = rgba(0x0550AE)
        t.inlineCodeText = rgba(0x953800)
        t.inlineCodeBackground = rgba(0xEFF1F3)
        t.codeText = rgba(0x24292F)
        t.codeBackground = rgba(0xF6F8FA)
        t.quoteText = rgba(0x57606A)
        t.quoteBar = rgba(0xD0D7DE)
        t.hr = rgba(0xD8DEE4)
        t.tableBorder = rgba(0xD0D7DE)
        t.tableZebra = rgba(0xF6F8FA)
        t.markBackground = rgba(0xFFF8C5)
        t.hlKeyword = rgba(0xCF222E)
        t.hlString = rgba(0x0A3069)
        t.hlComment = rgba(0x6E7781)
        t.hlNumber = rgba(0x0550AE)
        t.hlType = rgba(0x8250DF)
        return t
    }

    public func bodyFont(italic: Bool = false, bold: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, bodySize, "zh-Hans" as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, bodySize, nil)
        return scaled(base, italic: italic, bold: bold)
    }

    public func headingFont(level: Int) -> CTFont {
        let size = headingSizes[max(0, min(5, level - 1))]
        return CTFontCreateUIFontForLanguage(.system, size, "zh-Hans" as CFString)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// 等宽字体：macOS 用 Menlo；iOS 用 UIFont.monospacedSystemFont（toll-free 桥接 CTFont）。
    public func monoFont(size: CGFloat? = nil) -> CTFont {
        let s = size ?? codeSize
        #if canImport(UIKit)
        return UIFont.monospacedSystemFont(ofSize: s, weight: .regular) as CTFont
        #else
        return CTFontCreateWithName("Menlo" as CFString, s, nil)
        #endif
    }

    private func scaled(_ base: CTFont, italic: Bool, bold: Bool) -> CTFont {
        var font = base
        if bold {
            var traits = CTFontSymbolicTraits(rawValue: CTFontGetSymbolicTraits(font).rawValue)
            traits.insert(.boldTrait)
            if let f = CTFontCreateCopyWithSymbolicTraits(font, CTFontGetSize(font), nil, traits, [.boldTrait]) {
                font = f
            }
        }
        if italic {
            var traits = CTFontSymbolicTraits(rawValue: CTFontGetSymbolicTraits(font).rawValue)
            traits.insert(.italicTrait)
            if let f = CTFontCreateCopyWithSymbolicTraits(font, CTFontGetSize(font), nil, traits, [.italicTrait]) {
                font = f
            }
        }
        return font
    }
}

/// 行内样式：排版时挂在 NSAttributedString 上，实例生成时读取。
public final class SpanStyleBox {
    public let color: SIMD4<UInt8>
    public let underline: Bool
    public let strikethrough: Bool
    /// 行内背景（行内代码等），作为装饰矩形绘制。
    public let background: SIMD4<UInt8>?

    public init(color: SIMD4<UInt8>, underline: Bool = false,
                strikethrough: Bool = false, background: SIMD4<UInt8>? = nil) {
        self.color = color
        self.underline = underline
        self.strikethrough = strikethrough
        self.background = background
    }
}

/// NSAttributedString 自定义 key（CoreText 不消费，仅回读）。
public let SpanStyleAttributeName = NSAttributedString.Key("MarkdownCanvas.SpanStyle")

/// span 树 → NSAttributedString（字体 + 自定义样式）。
/// 样式叠加在递归过程中完成（em × strong × link 可任意嵌套）。
struct SpanFlattener {

    let theme: Theme

    struct Context {
        var italic = false
        var bold = false
        var mono = false
        var color: SIMD4<UInt8>
        var underline = false
        var strikethrough = false
        var background: SIMD4<UInt8>? = nil
        /// 链接 href（用于 linkRects）
        var href: String? = nil
    }

    func flatten(_ spans: [SpanNode], base: Context) -> [(NSAttributedString, Context)] {
        var out: [(NSAttributedString, Context)] = []
        for span in spans {
            var ctx = base
            let piece: NSAttributedString
            switch span {
            case .text(let s, let kind):
                if s.isEmpty { continue }
                let font: CTFont = ctx.mono
                    ? theme.monoFont()
                    : theme.bodyFont(italic: ctx.italic, bold: ctx.bold)
                var attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    SpanStyleAttributeName: SpanStyleBox(
                        color: ctx.color, underline: ctx.underline,
                        strikethrough: ctx.strikethrough, background: ctx.background),
                ]
                if let href = ctx.href {
                    attrs[LinkHrefAttributeName] = href
                }
                if kind == .html || kind == .entityRaw {
                    // demo：HTML 行内原文按等宽浅色渲染
                    attrs[NSAttributedString.Key(kCTFontAttributeName as String)] = theme.monoFont()
                }
                piece = NSAttributedString(string: s, attributes: attrs)
            case .em(let children):
                ctx.italic = true
                out += flatten(children, base: ctx)
                continue
            case .strong(let children):
                ctx.bold = true
                out += flatten(children, base: ctx)
                continue
            case .code(let s):
                ctx.mono = true
                ctx.color = theme.inlineCodeText
                ctx.background = theme.inlineCodeBackground
                let font = theme.monoFont()
                piece = NSAttributedString(string: s, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    SpanStyleAttributeName: SpanStyleBox(
                        color: ctx.color, underline: ctx.underline,
                        strikethrough: ctx.strikethrough, background: ctx.background),
                ])
            case .del(let children):
                ctx.strikethrough = true
                ctx.color = theme.secondary
                out += flatten(children, base: ctx)
                continue
            case .u(let children):
                ctx.underline = true
                out += flatten(children, base: ctx)
                continue
            case .mark(let children):
                ctx.background = theme.markBackground
                out += flatten(children, base: ctx)
                continue
            case .link(let href, let children):
                ctx.color = theme.link
                ctx.underline = true
                ctx.href = href
                out += flatten(children, base: ctx)
                continue
            case .image:
                // M4：块级图片提升在 LayoutEngine 处理，这里跳过
                continue
            case .latex(let s):
                piece = NSAttributedString(string: s, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): theme.monoFont(),
                    SpanStyleAttributeName: SpanStyleBox(color: theme.inlineCodeText),
                ])
            }
            out.append((piece, ctx))
        }
        return out
    }
}

/// 链接 href 挂到 NSAttributedString 上（命中测试用）。
public let LinkHrefAttributeName = NSAttributedString.Key("MarkdownCanvas.LinkHref")
