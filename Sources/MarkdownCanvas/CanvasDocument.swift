import CoreGraphics
import Foundation

/// 文档运行时对象：解析 + 排版 + 可视区实例生成 + 命中测试。
///
/// 滚动路径只走 `instances(visibleRect:)`：
/// LayoutBlock 全程缓存，字形 atlas 命中，纯几何 → 字节的转换。
/// 绘制顺序由渲染器保证：背景/划线（solid 管线）先画，字形后画。
public final class CanvasDocument {

    public let layout: LayoutResult
    public let theme: Theme
    /// HiDPI 栅格化倍率（2 = Retina）。
    public let scale: Int
    /// 图片纹理存储（可选；传入时块级图片渲染为纹理 quad）。
    private let imageStore: ImageStore?

    public init(markdown: String, theme: Theme = Theme(), contentWidth: CGFloat, scale: Int,
                imageStore: ImageStore? = nil,
                imageLoader: ((String) -> CGImage?)? = nil) {
        self.theme = theme
        self.scale = scale
        self.imageStore = imageStore
        let doc = MarkdownParser.parse(markdown)
        var sizes: [String: CGSize] = [:]
        if let imageStore, let imageLoader {
            var srcs: [String] = []
            doc.walk { if case .image(let src, _) = $0 { srcs.append(src) } }
            for src in srcs {
                if let cg = imageLoader(src) {
                    let r = imageStore.register(src: src, cgImage: cg)
                    if r.pixelSize != .zero { sizes[src] = r.pixelSize }
                }
            }
        }
        self.layout = LayoutEngine(theme: theme).layout(doc, contentWidth: contentWidth,
                                                        imageSizes: sizes)
    }

    public init(doc: BlockNode, theme: Theme = Theme(), contentWidth: CGFloat, scale: Int) {
        self.theme = theme
        self.scale = scale
        self.imageStore = nil
        self.layout = LayoutEngine(theme: theme).layout(doc, contentWidth: contentWidth)
    }

    // MARK: - 实例生成

    /// 生成可视区域内的全部绘制实例。
    /// - Parameters:
    ///   - visibleRect: 可视区域（文档坐标）
    ///   - displayOffset: 显示偏移，**加到**文档坐标上（如页边距 margin ——
    ///     文档 x=0 应显示在视图 x=margin 处）。滚动偏移由渲染器的
    ///     uniform（shader 里减去 scrollOffset）处理，不在这里。
    ///   - atlas: 字形图集（未命中字形栅格化并缓存）
    ///   - rasterScale: 当前 drawable 的实际倍率（跨屏拖动时与创建时的
    ///     `scale` 不同，图集按它重栅格化，保证 1:1 采样不缩放）
    ///   - hoverPoint: 悬停点（文档坐标）。非 nil 时命中链接的字形/下划线
    ///     改用 theme.linkHover 高亮；nil 时零额外开销
    public func instances(visibleRect: CGRect, atlas: GlyphAtlas,
                          displayOffset: CGPoint = .zero,
                          rasterScale: Int? = nil,
                          hoverPoint: CGPoint? = nil) -> [DrawInstance] {
        var out: [DrawInstance] = []
        out.reserveCapacity(4096)
        let ox = Float(displayOffset.x), oy = Float(displayOffset.y)
        let rasterScale = CGFloat(rasterScale ?? scale)
        // 与 GlyphAtlas 的栅格 padding 一致：quad 覆盖完整栅格（含 padding），
        // position 内缩 pad/scale 个逻辑点，shader 里 snap 后像素:纹素 = 1:1
        let pad = CGFloat(1) / rasterScale

        // 二分定位起始块（blocks 的 frame.minY 随 append 单调不减），
        // 再向前回溯覆盖「跨视区顶」的长块（引用竖线 / 大图片）
        let blocks = layout.blocks
        var lo = 0, hi = blocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].frame.minY < visibleRect.minY { lo = mid + 1 } else { hi = mid }
        }
        var start = lo
        while start > 0 && blocks[start - 1].frame.maxY > visibleRect.minY {
            start -= 1
        }

        for i in start..<blocks.count {
            let block = blocks[i]
            if block.frame.minY >= visibleRect.maxY { break }
            guard block.frame.intersects(visibleRect) else { continue }

            // 背景矩形（solid，渲染器先画）
            for bg in block.backgrounds where bg.rect.intersects(visibleRect) {
                out.append(solidInstance(bg.rect, color: bg.color, ox: ox, oy: oy))
            }

            // 悬停高亮：命中悬停点的链接矩形（字形中心/划线中心落在其中即换色）
            let hoveredRects = hoverPoint.flatMap { p in
                block.linkRects.filter { $0.0.contains(p) }.map(\.0)
            } ?? []
            let hoverColor = theme.linkHover

            for line in block.lines {
                guard line.baselineY - line.ascent <= visibleRect.maxY,
                      line.baselineY + line.descent >= visibleRect.minY else { continue }

                // 字形（glyph，渲染器后画）
                for g in line.glyphs {
                    guard let tex = atlas.rect(for: g.glyph, font: g.font,
                                               scale: Int(rasterScale)) else {
                        continue
                    }
                    var color = g.style.color
                    if !hoveredRects.isEmpty {
                        let center = CGPoint(x: line.originX + g.position.x + g.bounds.midX,
                                             y: line.baselineY - g.bounds.midY)
                        if hoveredRects.contains(where: { $0.contains(center) }) {
                            color = hoverColor
                        }
                    }
                    out.append(DrawInstance(
                        position: SIMD2(Float(line.originX + g.position.x + g.bounds.minX) + ox - Float(pad),
                                        Float(line.baselineY - g.bounds.maxY) + oy - Float(pad)),
                        size: SIMD2(Float(g.bounds.width) + Float(pad * 2),
                                    Float(g.bounds.height) + Float(pad * 2)),
                        uvOrigin: tex.uvOrigin, uvSize: tex.uvSize,
                        color: color, textureIndex: 0))
                }

                // 划线 / 行内背景（solid）
                for d in line.decorations {
                    switch d.kind {
                    case .underline, .strikethrough:
                        let y = line.baselineY - d.offsetY - d.thickness / 2
                        let rect = CGRect(x: line.originX + d.x, y: y,
                                          width: d.width, height: d.thickness)
                        var color = d.color
                        if !hoveredRects.isEmpty,
                           hoveredRects.contains(where: { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }) {
                            color = hoverColor
                        }
                        out.append(solidInstance(rect, color: color, ox: ox, oy: oy))
                    case .background:
                        if let rect = d.backgroundRect {
                            out.append(solidInstance(rect, color: d.color, ox: ox, oy: oy))
                        }
                    }
                }
            }

            // 图片块：纹理 quad（textureIndex = 槽位 + 1）
            if case .image(let src) = block.kind,
               let store = imageStore,
               let idx = store.indexOf(src: src) {
                out.append(DrawInstance(
                    position: SIMD2(Float(block.frame.minX) + ox, Float(block.frame.minY) + oy),
                    size: SIMD2(Float(block.frame.width), Float(block.frame.height)),
                    uvOrigin: SIMD2(0, 1),   // CI 坐标系 y 向上，纹理 v 翻转
                    uvSize: SIMD2(1, -1),
                    color: SIMD4(255, 255, 255, 255),
                    textureIndex: Int16(idx + 1)))
            }
        }
        return out
    }

    // MARK: - 命中测试

    /// 文档坐标点 → 链接 href。
    public func link(at point: CGPoint) -> String? {
        for block in layout.blocks where block.frame.insetBy(dx: -4, dy: -4).contains(point) {
            for (rect, href) in block.linkRects where rect.contains(point) {
                return href
            }
        }
        return nil
    }

    // MARK: - 内部

    private func solidInstance(_ rect: CGRect, color: SIMD4<UInt8>,
                               ox: Float = 0, oy: Float = 0) -> DrawInstance {
        DrawInstance(
            position: SIMD2(Float(rect.minX) + ox, Float(rect.minY) + oy),
            size: SIMD2(Float(rect.width), Float(rect.height)),
            color: color, textureIndex: -1)
    }
}
