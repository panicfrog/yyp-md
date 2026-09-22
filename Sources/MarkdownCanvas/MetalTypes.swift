import Foundation
import simd

/// 单个绘制实例：一个带纹理或纯色的矩形 quad。
/// 布局与 Shaders.metal 中的 `Instance` 一一对应（40 字节，8 字节对齐），
/// 由 CPU 直接写进环形池共享 MTLBuffer，GPU 顶点着色器按 instance_id 读取。
public struct DrawInstance {
    /// 文档坐标（逻辑 pt），quad 左上角。
    public var position: SIMD2<Float>
    /// quad 尺寸（逻辑 pt）。
    public var size: SIMD2<Float>
    /// UV 左上角。字形（textureIndex == 0）时为**图集纹素坐标**，配合 shader 的
    /// 像素中心对齐做精确采样；图片时为归一化 UV。纯色块时无意义。
    public var uvOrigin: SIMD2<Float>
    /// 字形时为**栅格纹素尺寸**（quad 像素尺寸由 shader 直接采用）；图片时为归一化跨度。
    public var uvSize: SIMD2<Float>
    /// 颜色（straight alpha，8bit/通道）。
    public var color: SIMD4<UInt8>
    /// -1 = 纯色块（solid 管线）；>=0 = 图集层号（glyph 管线）。
    public var textureIndex: Int16
    /// 保留（线条样式等）。
    public var flags: UInt16

    public init(position: SIMD2<Float>, size: SIMD2<Float>,
                uvOrigin: SIMD2<Float> = .zero, uvSize: SIMD2<Float> = .zero,
                color: SIMD4<UInt8>, textureIndex: Int16 = -1, flags: UInt16 = 0) {
        self.position = position
        self.size = size
        self.uvOrigin = uvOrigin
        self.uvSize = uvSize
        self.color = color
        self.textureIndex = textureIndex
        self.flags = flags
    }
}

/// 帧级 uniform：每帧一份，写在环形池槽位的头部。
/// 布局与 Shaders.swift 的 `Uniforms` 一一对应（32 字节）。
public struct FrameUniforms {
    /// drawable 像素尺寸。
    public var viewportSize: SIMD2<Float>
    /// 滚动偏移（逻辑 pt）。
    public var scrollOffset: SIMD2<Float>
    /// 像素 / 逻辑 pt。
    public var scale: Float
    var pad: Float = 0
    /// 字形图集纹素尺寸（shader 里做「像素中心 = 纹素中心」的精确 UV 映射）。
    public var atlasSize: SIMD2<Float>

    public init(viewportSize: SIMD2<Float>, scrollOffset: SIMD2<Float>, scale: Float,
                atlasSize: SIMD2<Float>) {
        self.viewportSize = viewportSize
        self.scrollOffset = scrollOffset
        self.scale = scale
        self.atlasSize = atlasSize
    }
}

/// RGB hex → SIMD4<UInt8>（不透明）。
public func rgba(_ rgb: UInt32, _ alpha: UInt8 = 255) -> SIMD4<UInt8> {
    SIMD4(UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF), alpha)
}

public enum Environment {
    /// demo 诊断开关（环境变量控制）。
    public static var debug: Bool { ProcessInfo.processInfo.environment["MC_DEBUG"] != nil }
}
