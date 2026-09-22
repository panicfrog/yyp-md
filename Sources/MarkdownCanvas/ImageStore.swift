import Metal
import CoreImage
import CoreGraphics

/// 图片解码与纹理缓存：CoreImage 解码 → CIContext(mtlDevice) 离屏渲染到 MTLTexture。
///
/// 纹理用 .private 存储（GPU 专用，CIContext 直接写入，CPU 不触碰），
/// 渲染时按需绑定 —— 每张图片一次 draw call（demo 图片量小，不做图集）。
/// textureIndex 约定：-1 = solid 色块，0 = 字形图集，>= 1 = ImageStore 槽位 + 1。
public final class ImageStore {

    private let device: MTLDevice
    private let context: CIContext
    private var textures: [MTLTexture] = []
    private var indexBySrc: [String: Int] = [:]

    public init(device: MTLDevice) {
        self.device = device
        self.context = CIContext(mtlDevice: device)
    }

    /// 同步解码注册一张图片。返回槽位与像素尺寸；同 src 重复注册直接命中缓存。
    @discardableResult
    public func register(src: String, cgImage: CGImage) -> (index: Int, pixelSize: CGSize) {
        if let idx = indexBySrc[src], textures.indices.contains(idx) {
            let t = textures[idx]
            return (idx, CGSize(width: t.width, height: t.height))
        }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0,
              let texture = device.makeTexture(
                descriptor: Self.descriptor(width: w, height: h)) else {
            return (0, .zero)
        }
        let ciImage = CIImage(cgImage: cgImage)
        context.render(ciImage, to: texture, commandBuffer: nil,
                       bounds: ciImage.extent,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        let idx = textures.count
        textures.append(texture)
        indexBySrc[src] = idx
        return (idx, CGSize(width: w, height: h))
    }

    public func indexOf(src: String) -> Int? {
        indexBySrc[src]
    }

    public func texture(at index: Int) -> MTLTexture? {
        textures.indices.contains(index) ? textures[index] : nil
    }

    public var count: Int { textures.count }

    private static func descriptor(width: Int, height: Int) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .private
        return d
    }
}
