// iOS 入口：UIScrollView 虚拟滚动 + MTKView 覆盖画布，与 macOS 入口同构。
// 核心（MarkdownCanvas library）完全复用，平台差异只在滚动容器与视图生命周期。
//
// macOS `swift build` 时本文件为空（canImport(UIKit) 不成立）；
// iOS 编译：xcrun -sdk iphonesimulator swift build --target MarkdownCanvasIOS

#if canImport(UIKit)
import UIKit
import MetalKit
import MarkdownCanvas

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var coordinator: SceneCoordinator?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let frame = UIScreen.main.bounds
        let window = UIWindow(frame: frame)
        let coordinator = SceneCoordinator(window: window)
        self.window = window
        self.coordinator = coordinator
        window.makeKeyAndVisible()
        return true
    }
}

/// 画布视图：tap → 链接命中 → 打开。
/// UITapGestureRecognizer 与 UIScrollView 的 pan 自动区分（tap 无位移）。
final class CanvasMTKView: MTKView {
    /// view 坐标（y 向下）→ href
    var linkHitTest: ((CGPoint) -> String?)?

    func installTapHandler() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        let p = gr.location(in: self)
        // UIKit 视图坐标 y 向上，文档坐标 y 向下
        let docPoint = CGPoint(x: p.x, y: bounds.height - p.y)
        guard let href = linkHitTest?(docPoint), let url = URL(string: href) else { return }
        UIApplication.shared.open(url)
    }
}

/// 组装：MTKView（覆盖可视区，不随内容滚动） + UIScrollView（占位 contentSize）。
final class SceneCoordinator: NSObject, UIScrollViewDelegate {

    let renderer: MetalRenderer
    let doc: CanvasDocument
    let scrollView = UIScrollView()
    let view: CanvasMTKView

    init(window: UIWindow) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MetalRenderer(device: device) else {
            fatalError("无法初始化 Metal")
        }
        self.renderer = renderer

        let size = window.bounds.size
        let scale = Int(UIScreen.main.scale)
        let margin: CGFloat = 16
        let contentWidth = size.width - margin * 2

        // demo 内置文档（SPM executable 无 bundle 资源）
        let markdown = """
        # MarkdownCanvas on iOS

        纯平台原生渲染管线：**md4c** 解析 → **CoreText** 排版 → **Metal** 绘制。

        - 14 槽环形缓冲池共享 CPU/GPU
        - 滚动时只生成可视区实例
        - `行内代码` 与 ~~删除线~~

        > 引用块：竖线由 Metal 矩形绘制。

        ```swift
        let doc = CanvasDocument(markdown: text,
                                 contentWidth: width, scale: 2)
        ```

        | 引擎 | 职责 |
        |:--|:--|
        | md4c | 解析 |
        | CoreText | 排版 |
        | Metal | 绘制 |

        滚动试试 —— 布局只发生一次，滚动路径只做几何 → 字节转换。
        """

        let doc = CanvasDocument(markdown: markdown, theme: Theme(),
                                 contentWidth: contentWidth, scale: scale)
        self.doc = doc

        let view = CanvasMTKView(frame: .zero, device: device)
        view.delegate = renderer
        view.clearColor = MTLClearColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        view.isPaused = false
        view.contentScaleFactor = UIScreen.main.scale
        view.installTapHandler()
        self.view = view

        super.init()

        let docHeight = doc.layout.totalHeight + margin * 2
        scrollView.delegate = self
        scrollView.contentSize = CGSize(width: size.width, height: docHeight)
        scrollView.showsVerticalScrollIndicator = true
        scrollView.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        scrollView.addSubview(view)
        window.rootViewController = UIViewController()
        window.rootViewController?.view = scrollView

        let docOrigin = CGPoint(x: margin, y: margin)
        // 链接命中：view 坐标（y 向下）→ 文档坐标（还原滚动偏移、去掉页边距）
        view.linkHitTest = { [weak self] point in
            guard let self else { return nil }
            let docPoint = CGPoint(x: point.x + self.scrollView.contentOffset.x - docOrigin.x,
                                   y: point.y + self.scrollView.contentOffset.y - docOrigin.y)
            return self.doc.link(at: docPoint)
        }
        renderer.instancesProvider = { [weak self] in
            guard let self else { return [] }
            let size = self.scrollView.bounds.size
            let visible = CGRect(
                x: self.scrollView.contentOffset.x - docOrigin.x,
                y: self.scrollView.contentOffset.y - docOrigin.y,
                width: size.width, height: size.height)
            return self.doc.instances(visibleRect: visible, atlas: self.renderer.atlas,
                                      displayOffset: docOrigin)
        }
        layoutCanvas()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "bounds" {
            layoutCanvas()
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func layoutCanvas() {
        let size = scrollView.bounds.size
        view.frame = CGRect(origin: scrollView.contentOffset, size: size)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        renderer.scrollOffset = scrollView.contentOffset
        layoutCanvas()
        view.draw()
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                  NSStringFromClass(AppDelegate.self))
#endif
