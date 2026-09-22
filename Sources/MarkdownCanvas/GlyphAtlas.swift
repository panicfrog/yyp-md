import Metal
import CoreText
import CoreGraphics

/// 字形灰度图集：R8Unorm 单纹理 + shelf（行式）装箱。
///
/// key = (字体对象, 字号, HiDPI scale, glyph ID)。命中即返回 UV；
/// 未命中则用 alpha-only CGContext 栅格化该字形并写入纹理。
/// demo 规模（一篇文档几千字形）一张 2048² 图集足够；满了整图重建。
public final class GlyphAtlas {

    public let texture: MTLTexture

    private let size = 2048
    // shelf 分配器状态（像素）
    private var cursorX = 0
    private var shelfTop = 0
    private var shelfHeight = 0
    private var cache: [Key: Rect] = [:]
    private let queue = DispatchQueue(label: "GlyphAtlas.rasterize")

    public struct Key: Hashable {
        let font: ObjectIdentifier
        let fontSize: Int   // 千分位字号，避免浮点 hash 抖动
        let scale: Int
        let glyph: CGGlyph
    }

    /// 图集中一个字形的占位（像素矩形 + 纹素坐标）。
    public struct Rect {
        public let px: CGRect          // 像素（含 padding）
        /// 槽位原点（纹素）。shader 字形路径做「像素中心 = 纹素中心」的精确映射。
        public let uvOrigin: SIMD2<Float>
        /// 栅格尺寸（纹素数）——也用作 quad 的像素尺寸。
        public let uvSize: SIMD2<Float>
    }

    public init(device: MTLDevice) {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2D
        desc.pixelFormat = .r8Unorm
        desc.width = size
        desc.height = size
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        texture = device.makeTexture(descriptor: desc)!
    }

    /// 查询或栅格化字形，返回图集矩形。
    /// - Parameters:
    ///   - glyph: 字形 ID（CTRunGetGlyphs）
    ///   - font: 字形所属字体（CTRun attributes 中取出）
    ///   - scale: backingScaleFactor（2 = Retina）
    /// - Returns: nil 表示字形为空（如空格）或图集已满（demo 不处理溢出，assert）
    public func rect(for glyph: CGGlyph, font: CTFont, scale: Int) -> Rect? {
        let key = Key(font: ObjectIdentifier(font as AnyObject),
                      fontSize: Int(CTFontGetSize(font) * 1000), scale: scale, glyph: glyph)
        if let hit = cache[key] { return hit }

        // 字形边界（pt，y 向上、以基线原点为参考）
        var bounds = CGRect()
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, [glyph], &bounds, 1)
        guard bounds.width > 0 || bounds.height > 0 else {
            cache[key] = Rect(px: .zero, uvOrigin: .zero, uvSize: .zero)
            return nil
        }

        let pad = 1 // 防 linear 采样渗色
        let w = max(1, Int((bounds.width * CGFloat(scale)).rounded()) + pad * 2)
        let h = max(1, Int((bounds.height * CGFloat(scale)).rounded()) + pad * 2)
        guard let slot = allocate(width: w, height: h) else {
            assertionFailure("glyph atlas 已满（demo 未实现溢出重建）")
            return nil
        }

        rasterize(glyph: glyph, font: font, scale: scale,
                  bounds: bounds, slot: slot, pad: pad)

        let rect = Rect(
            px: CGRect(x: slot.x, y: slot.y, width: w, height: h),
            uvOrigin: SIMD2(Float(slot.x), Float(slot.y)),
            uvSize: SIMD2(Float(w), Float(h)))
        cache[key] = rect
        return rect
    }

    // MARK: - 内部

    private struct Slot { let x: Int, y: Int }

    private func allocate(width: Int, height: Int) -> Slot? {
        if cursorX + width > size {
            // 当前行放不下，换行
            shelfTop += shelfHeight
            shelfHeight = 0
            cursorX = 0
        }
        guard shelfTop + height <= size else { return nil }
        let slot = Slot(x: cursorX, y: shelfTop)
        cursorX += width
        shelfHeight = max(shelfHeight, height)
        return slot
    }

    /// 栅格化单个字形：alpha-only 8bpp 位图 → R8Unorm 纹理区域。
    /// 布局：位图包含 padding，字形基线原点位于 (pad - minX, pad - minY)。
    ///
    /// ⚠️ 行距必须 4 字节对齐：Metal replaceRegion 的 bytesPerRow 未对齐时
    /// （Apple GPU 纹理内存按 tile 平铺）写入会越界踩坏相邻字形区域 ——
    /// 曾导致滚动后整屏字形损坏（启动时踩空白区不可见，滚动后踩到已用区域）。
    private func rasterize(glyph: CGGlyph, font: CTFont, scale: Int,
                           bounds: CGRect, slot: Slot, pad: Int) {
        let w = Int((bounds.width * CGFloat(scale)).rounded()) + pad * 2
        let h = Int((bounds.height * CGFloat(scale)).rounded()) + pad * 2
        let rowPitch = (w + 3) & ~3

        var pixels = [UInt8](repeating: 0, count: rowPitch * h)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: rowPitch,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return }
            // CGContext y 向上；字形原点放 (pad - minX, pad - minY)，1pt = scale px
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            let origin = CGPoint(x: CGFloat(pad) / CGFloat(scale) - bounds.minX,
                                 y: CGFloat(pad) / CGFloat(scale) - bounds.minY)
            CTFontDrawGlyphs(font, [glyph], [origin], 1, ctx)
        }

        texture.replace(region: MTLRegionMake2D(slot.x, slot.y, w, h),
                        mipmapLevel: 0,
                        withBytes: pixels,
                        bytesPerRow: rowPitch)
    }
}
