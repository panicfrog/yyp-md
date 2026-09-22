import AppKit
import UniformTypeIdentifiers
import MetalKit
import MarkdownCanvas

// 虚拟滚动 + 覆盖画布 + 链接点击。
//
// 结构：NSScrollView > NSClipView > 占位 FlipView（高度 = 文档高度，不渲染任何内容）；
//       MTKView 固定覆盖在可视区（scrollView 的子视图，不随内容滚动），
//       contentOffset 变化 → 更新 renderer.scrollOffset + 重绘。
// 滚轮 / 触控板惯性 / 滚动条全部由平台 ScrollView 提供。
//
// 坐标系：实例坐标 = 文档坐标 + margin（displayOffset），滚动偏移由 shader
// 的 uniform（scrollOffset）减去 —— 文档 (0,0) 显示在视口 (margin, margin)。
// 排版宽度 = 实际视口宽度 - 2×margin（overlay 滚动条不占位、经典滚动条占位
// 均正确处理）；窗口 resize 后 debounce 重排。

/// macOS MTKView 无 contentScaleFactor，手动维持 drawableSize = bounds × backingScale。
class HiDPIMTKView: MTKView {
    override func viewDidMoveToWindow() { updateDrawableSize() }
    override func layout() {
        super.layout()
        updateDrawableSize()
        needsDisplay = true
    }
    func updateDrawableSize() {
        guard let window = window else { return }
        let s = window.backingScaleFactor
        drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
    }
}

/// 画布视图：链接点击（mouseUp 触发 + 拖动取消）与悬停反馈（光标 + 变色）。
final class CanvasMTKView: HiDPIMTKView {
    /// view 坐标（y 向下）→ href（点击与悬停共用）
    var linkHitTest: ((CGPoint) -> String?)?
    /// view 坐标（y 向下）→ 文档坐标
    var viewToDoc: ((CGPoint) -> CGPoint)?
    /// 悬停点（文档坐标）。didSet 触发重绘，provider 读取它做链接变色。
    var hoverDocPoint: CGPoint? {
        didSet { if oldValue != hoverDocPoint { needsDisplay = true } }
    }

    private var pressedLinkHref: String?
    private var pressLocation: CGPoint = .zero

    /// 窗口非 key（失焦）时，第一次点击默认被系统当作「激活窗口」吞掉，
    /// 不会派发 mouseDown —— 表现为「点了链接没反应，得点两次」。
    /// 返回 true 让失焦状态下的首次点击也直接交给本视图处理。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// AppKit 视图坐标（y 向上）→ 文档坐标（y 向下）
    private func docPoint(_ viewPoint: NSPoint) -> CGPoint {
        CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self))
    }

    /// 悬停核心：光标形状 + 变色点（p 为本视图坐标，y 向上）。
    private func processHover(atViewPoint p: NSPoint) {
        guard window?.isKeyWindow == true, bounds.contains(p) else {
            hoverDocPoint = nil
            NSCursor.arrow.set()
            return
        }
        let dp = docPoint(p)
        if linkHitTest?(dp) != nil {
            hoverDocPoint = viewToDoc?(dp)
            NSCursor.pointingHand.set()
        } else {
            hoverDocPoint = nil
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        processHover(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoverDocPoint = nil
        NSCursor.arrow.set()
    }

    /// 滚动后内容在光标下移动：用系统鼠标位置重算悬停（无 event 可用）。
    func refreshHoverFromSystemMouse() {
        guard let window else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        processHover(atViewPoint: convert(inWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = docPoint(convert(event.locationInWindow, from: nil))
        pressedLinkHref = linkHitTest?(pressLocation)
        if Environment.debug {
            print("[mouse-down] view=\(pressLocation) href=\(String(describing: pressedLinkHref))")
            fflush(stdout)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // 按下后拖动超过 4pt 视为滚动/选择，取消点击
        let p = docPoint(convert(event.locationInWindow, from: nil))
        if abs(p.x - pressLocation.x) > 4 || abs(p.y - pressLocation.y) > 4 {
            pressedLinkHref = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedLinkHref = nil }
        guard let href = pressedLinkHref else { return }
        if Environment.debug {
            // 自动化验证模式：只打日志不真开浏览器
            print("[link-click] \(href)")
            fflush(stdout)
            return
        }
        if let url = URL(string: href) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 翻转占位视图：flipped 坐标系使 clipView 的 bounds.origin 直接等于
/// 「文档顶部向下滚动距离」（含 margin），与渲染器文档坐标（y 向下）一致。
final class FlipPlaceholder: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// 顶层 guard 绑定不能被 main.swift 里的顶层函数捕获，改为无条件 let
func metalUnavailable() -> Never {
    FileHandle.standardError.write("无法初始化 Metal\n".data(using: .utf8)!)
    exit(1)
}
let device: MTLDevice = {
    guard let d = MTLCreateSystemDefaultDevice() else { metalUnavailable() }
    return d
}()
let renderer: MetalRenderer = {
    guard let r = MetalRenderer(device: device) else { metalUnavailable() }
    return r
}()

// --- 加载文档 ---
// 默认空白（不渲染任何内容），⌘O 手动打开；命令行参数保留为自动化验证入口
var mdPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
var markdown: String
if !mdPath.isEmpty {
    if let data = FileManager.default.contents(atPath: mdPath) {
        markdown = String(decoding: data, as: UTF8.self)
    } else {
        markdown = "# 找不到文件\n\n`\(mdPath)` 不存在，用默认文本代替。\n\n- 项目一\n- 项目二\n"
    }
} else {
    markdown = ""
}

let backingScale = NSScreen.main?.backingScaleFactor ?? 2
let windowSize = CGSize(width: 820, height: 700)
let margin: CGFloat = 16
let docOrigin = CGPoint(x: margin, y: margin)

// ImageStore 按文件加载重建（register 以 src 字符串为缓存键，
// 跨文件的同相对路径会命中上一文件的旧纹理）
var imageStore = ImageStore(device: device)

func refreshImageTextures() {
    renderer.imageTextures = (0..<imageStore.count).compactMap { imageStore.texture(at: $0) }
}
refreshImageTextures()

func loadImage(_ src: String) -> CGImage? {
    let base = URL(fileURLWithPath: mdPath).deletingLastPathComponent()
    let url = src.hasPrefix("/")
        ? URL(fileURLWithPath: src)
        : base.appendingPathComponent(src)
    guard let data = try? Data(contentsOf: url),
          let provider = CGDataProvider(data: data as CFData),
          let cg = CGImage(pngDataProviderSource: provider, decode: nil,
                           shouldInterpolate: true, intent: .defaultIntent) else {
        return nil
    }
    return cg
}

// --- 主题与字号（菜单切换 → 整文档重排，demo 无增量排版） ---
var useLightTheme = false
var fontScale: CGFloat = 1.0

func makeTheme() -> Theme {
    var theme = useLightTheme ? Theme.light() : Theme()
    if fontScale != 1.0 {
        theme.bodySize *= fontScale
        theme.codeSize *= fontScale
        theme.headingSizes = theme.headingSizes.map { $0 * fontScale }
    }
    return theme
}

// --- 滚动容器（先建好，取实际视口宽度做排版宽度） ---
let view = CanvasMTKView(frame: .zero, device: device)
view.delegate = renderer
// 常规模式：内部定时器驱动（前台 app 60fps）；滚动时 syncFromScroll 再主动
// draw() 一次，让新偏移立即上屏而不等下一个 vsync
view.isPaused = false

let scrollView = NSScrollView()
scrollView.hasVerticalScroller = true
scrollView.hasHorizontalScroller = false
scrollView.autohidesScrollers = true
scrollView.borderType = .noBorder
scrollView.drawsBackground = false

let placeholder = FlipPlaceholder(frame: .zero)
placeholder.wantsLayer = false
scrollView.documentView = placeholder

// --- 窗口（先确定 scrollView 尺寸，再按视口宽度排版） ---
let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: windowSize),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false)
window.title = mdPath.isEmpty
    ? "yyp-md"
    : "yyp-md — \(URL(fileURLWithPath: mdPath).lastPathComponent)"
window.contentView = scrollView
scrollView.frame = window.contentView!.bounds
scrollView.autoresizingMask = [.width, .height]
scrollView.addSubview(view)
window.center()
window.layoutIfNeeded()

/// 排版宽度：实际视口宽 - 2×margin - 滚动条占位。
/// overlay 样式滚动条不占 clipView 布局空间，但本机静止时常驻可见
/// （探针验证：alpha=1.0，frame=(805,0,15,700)，autohidesScrollers 不生效），
/// 不预留宽度内容右缘会顶到滚动条；legacy 样式系统已内缩 clipView，
/// 滚动条在 clipView 之外，不能再减（否则双重扣减）。
func currentContentWidth() -> CGFloat {
    let clipWidth = scrollView.contentView.bounds.width
    var scrollerWidth: CGFloat = 0
    if NSScroller.preferredScrollerStyle == .overlay, let scroller = scrollView.verticalScroller {
        scrollerWidth = scroller.frame.width
    }
    return max(200, clipWidth - margin * 2 - scrollerWidth)
}

var doc = CanvasDocument(markdown: markdown, theme: makeTheme(),
                         contentWidth: currentContentWidth(), scale: Int(backingScale),
                         imageStore: imageStore, imageLoader: loadImage)
placeholder.setFrameSize(NSSize(width: scrollView.contentView.bounds.width,
                                height: doc.layout.totalHeight + margin * 2))

// --- 空状态提示（AppKit label：行左对齐，整个块水平/垂直居中；不进 Metal 渲染管线） ---
let hintLabel = NSTextField(wrappingLabelWithString: "")
do {
    let para = NSMutableParagraphStyle()
    para.alignment = .left
    para.lineSpacing = 10
    let lines = [
        "⌘O　打开 Markdown 文件",
        "⌘T　切换明暗主题",
        "⌘+ / ⌘−　调整字号",
        "⌘W　清空画布",
    ].joined(separator: "\n")
    hintLabel.attributedStringValue = NSAttributedString(string: lines, attributes: [
        .font: NSFont.systemFont(ofSize: 14),
        .paragraphStyle: para])
}
scrollView.addSubview(hintLabel)   // 后加 → 在画布之上
// wrappingLabelWithString 默认 selectable：点击会唤起 field editor，
// 用默认字体替换 attributed 字体 → 文字缩小。纯提示用，彻底禁交互。
hintLabel.isEditable = false
hintLabel.isSelectable = false
hintLabel.allowsEditingTextAttributes = false

func layoutHint() {
    let size = scrollView.bounds.size
    let hint = hintLabel.fittingSize   // 自然宽度（不折行）
    hintLabel.frame = NSRect(x: max(0, (size.width - hint.width) / 2),
                             y: max(0, (size.height - hint.height) / 2),
                             width: hint.width, height: hint.height)
}

/// 未加载文件时显示提示，加载后隐藏
func updateHintVisibility() {
    hintLabel.isHidden = !markdown.isEmpty
    if !hintLabel.isHidden { layoutHint() }
}

func applyThemeToView() {
    let theme = makeTheme()
    let bg = theme.background
    view.clearColor = MTLClearColor(red: Double(bg.x) / 255, green: Double(bg.y) / 255,
                                    blue: Double(bg.z) / 255, alpha: 1)
    // 提示文字用比 secondary 更淡的一档（刻意低调）
    let fg = useLightTheme ? rgba(0x9BA1A8) : rgba(0x6E6E74)
    hintLabel.textColor = NSColor(calibratedRed: CGFloat(fg.x) / 255,
                                   green: CGFloat(fg.y) / 255,
                                   blue: CGFloat(fg.z) / 255, alpha: 1)
}

applyThemeToView()
updateHintVisibility()

// 实例生成：视口显示的文档区域 = scrollOffset - 页边距；
// 实例坐标 = 文档坐标 + 页边距（滚动偏移由 shader 的 uniform 减去）。
// rasterScale 用当前 drawable 的实际倍率：跨屏拖动（2x ↔ 1x）时图集
// 按新倍率重栅格化，保证像素:纹素 = 1:1，不发生缩放重采样
renderer.instancesProvider = { [weak renderer] in
    guard let renderer else { return [] }
    let size = view.bounds.size
    let visible = CGRect(
        x: renderer.scrollOffset.x - docOrigin.x,
        y: renderer.scrollOffset.y - docOrigin.y,
        width: size.width, height: size.height)
    let liveScale = view.bounds.height > 0
        ? Int((view.drawableSize.height / view.bounds.height).rounded()) : Int(backingScale)
    return doc.instances(visibleRect: visible, atlas: renderer.atlas,
                         displayOffset: docOrigin, rasterScale: liveScale,
                         hoverPoint: view.hoverDocPoint)
}

/// view 坐标（y 向下）→ 文档坐标（还原滚动偏移、去掉页边距）
func pointToDoc(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x + renderer.scrollOffset.x - docOrigin.x,
            y: point.y + renderer.scrollOffset.y - docOrigin.y)
}

// 链接命中 + 悬停坐标换算：view 坐标（y 向下）→ href / 文档坐标
view.linkHitTest = { point in doc.link(at: pointToDoc(point)) }
view.viewToDoc = { point in pointToDoc(point) }

// clipView 滚动 → 更新画布 frame / scrollOffset / 重绘
func syncFromScroll() {
    let visibleRect = scrollView.contentView.bounds // flipped：origin = 占位视图坐标
    renderer.scrollOffset = visibleRect.origin
    // MTKView 覆盖在可视区（scrollView 坐标系）
    let visInView = scrollView.contentView.convert(visibleRect, to: scrollView)
    view.frame = visInView
    // 滚动后内容在光标下移动，悬停高亮/光标需要重算
    view.refreshHoverFromSystemMouse()
    view.draw()
}

NotificationCenter.default.addObserver(
    forName: NSView.boundsDidChangeNotification,
    object: scrollView.contentView, queue: .main) { _ in
        syncFromScroll()
    }
NotificationCenter.default.addObserver(
    forName: NSView.frameDidChangeNotification,
    object: scrollView.contentView, queue: .main) { _ in
        syncFromScroll()
    }
scrollView.contentView.postsBoundsChangedNotifications = true
scrollView.contentView.postsFrameChangedNotifications = true

// 跨屏拖动（2x Retina ↔ 1x 外接屏）：drawable 尺寸与栅格化倍率都要跟随，
// 否则字形按旧倍率栅格化后被缩放显示 —— 模糊的主因之一
for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
    NotificationCenter.default.addObserver(
        forName: name, object: window, queue: .main) { _ in
            view.updateDrawableSize()
            view.needsDisplay = true
        }
}

/// 主题/字号/宽度变化：重建排版（图片纹理缓存复用）。
/// - Parameter keepingScroll: true 保持滚动位置（主题/字号切换）；
///   false 回到顶部（打开新文件）
func rebuildDocument(keepingScroll: Bool = true) {
    if Environment.debug {
        print("[rebuild] keepingScroll=\(keepingScroll) fontScale=\(fontScale) contentWidth=\(currentContentWidth()) markdownLen=\(markdown.count)")
        fflush(stdout)
    }
    let preservedY = keepingScroll ? scrollView.contentView.bounds.origin.y : 0
    doc = CanvasDocument(markdown: markdown, theme: makeTheme(),
                         contentWidth: currentContentWidth(), scale: Int(backingScale),
                         imageStore: imageStore, imageLoader: loadImage)
    applyThemeToView()
    placeholder.setFrameSize(NSSize(width: scrollView.contentView.bounds.width,
                                    height: doc.layout.totalHeight + margin * 2))
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: preservedY))
    syncFromScroll()
    view.draw()
}

/// 打开新文件：更新内容/标题，重建 ImageStore（避免跨文件纹理缓存污染），回顶部。
func loadMarkdown(at path: String) {
    guard let data = FileManager.default.contents(atPath: path) else {
        let alert = NSAlert()
        alert.messageText = "无法打开文件"
        alert.informativeText = "`\(path)` 不存在或不可读"
        alert.runModal()
        return
    }
    mdPath = path
    markdown = String(decoding: data, as: UTF8.self)
    window.title = "yyp-md — \(URL(fileURLWithPath: path).lastPathComponent)"
    imageStore = ImageStore(device: device)
    refreshImageTextures()
    rebuildDocument(keepingScroll: false)
    updateHintVisibility()
}

/// 关闭文件：清回空白画布。
func clearDocument() {
    mdPath = ""
    markdown = ""
    window.title = "yyp-md"
    imageStore = ImageStore(device: device)
    refreshImageTextures()
    rebuildDocument(keepingScroll: false)
    updateHintVisibility()
}

// 窗口 resize → 占位宽度立即跟随；重排 debounce 250ms（拖动期间不反复重排）
var relayoutWorkItem: DispatchWorkItem?
NotificationCenter.default.addObserver(
    forName: NSWindow.didResizeNotification,
    object: window, queue: .main) { _ in
        placeholder.setFrameSize(NSSize(width: scrollView.contentView.bounds.width,
                                        height: doc.layout.totalHeight + margin * 2))
        layoutHint()
        syncFromScroll()
        relayoutWorkItem?.cancel()
        let item = DispatchWorkItem { rebuildDocument() }
        relayoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

// --- 菜单：文件 / 主题切换 / 字号调节 ---
final class MenuController: NSObject {
    @objc func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"),
            .plainText
        ].compactMap { $0 }
        panel.message = "选择要渲染的 Markdown 文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadMarkdown(at: url.path)
    }
    @objc func closeDocument() {
        clearDocument()
    }
    @objc func toggleTheme() {
        useLightTheme.toggle()
        if Environment.debug { print("[menu] toggleTheme"); fflush(stdout) }
        rebuildDocument()
    }
    @objc func biggerText() {
        fontScale = min(2.0, fontScale + 0.15)
        if Environment.debug { print("[menu] biggerText → \(fontScale)"); fflush(stdout) }
        rebuildDocument()
    }
    @objc func smallerText() {
        fontScale = max(0.6, fontScale - 0.15)
        if Environment.debug { print("[menu] smallerText → \(fontScale)"); fflush(stdout) }
        rebuildDocument()
    }
}
let menuController = MenuController()

/// Finder 双击 / 右键「打开方式」走的是 odoc Apple Event，不是命令行 argv。
/// 没有 delegate 实现时 AppKit 直接弹
/// 「yyp-md cannot open files in the "Markdown Document" format」。
/// app 已在运行时再打开文件，也路由到同一个方法。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        loadMarkdown(at: url.path)
    }
}
let appDelegate = AppDelegate()

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "退出 yyp-md",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let fileMenuItem = NSMenuItem()
mainMenu.addItem(fileMenuItem)
let fileMenu = NSMenu(title: "文件")
fileMenu.addItem(withTitle: "打开…", action: #selector(MenuController.openDocument),
                 keyEquivalent: "o").target = menuController
fileMenu.addItem(NSMenuItem.separator())
fileMenu.addItem(withTitle: "关闭", action: #selector(MenuController.closeDocument),
                 keyEquivalent: "w").target = menuController
fileMenuItem.submenu = fileMenu

let viewMenuItem = NSMenuItem()
mainMenu.addItem(viewMenuItem)
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(withTitle: "切换明暗主题", action: #selector(MenuController.toggleTheme),
                 keyEquivalent: "t").target = menuController
viewMenu.addItem(withTitle: "放大字号", action: #selector(MenuController.biggerText),
                 keyEquivalent: "+").target = menuController
viewMenu.addItem(withTitle: "缩小字号", action: #selector(MenuController.smallerText),
                 keyEquivalent: "-").target = menuController
viewMenuItem.submenu = viewMenu
app.mainMenu = mainMenu

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.delegate = appDelegate
syncFromScroll()
app.run()
