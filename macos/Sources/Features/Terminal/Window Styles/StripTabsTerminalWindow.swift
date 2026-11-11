import AppKit
import SwiftUI

/// Status Lab replacement for `macos-titlebar-style = tabs`.
///
/// Native tabbing (tab groups, keyboard shortcuts, session restore) is kept as is, but the
/// native NSTabBar is hidden. Instead `TerminalView` draws a compact tab strip in the
/// transparent titlebar area, blending with the terminal background.
///
/// In native fullscreen the strip moves into a titlebar accessory: macOS then hides it and
/// reveals it, with the menu bar, when the pointer reaches the top (also with one tab,
/// where the native tab bar would not appear at all).
class StripTabsTerminalWindow: TransparentTitlebarTerminalWindow {
    let tabStrip = TerminalTabStripModel()

    /// The strip draws the window controls area itself; there is no room for the accessory.
    override var supportsUpdateAccessory: Bool { false }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        tabStrip.window = self
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(tabStripNeedsRefresh),
                           name: .terminalTabStripNeedsRefresh, object: nil)
        center.addObserver(self, selector: #selector(windowWillCloseSomewhere(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterFullScreen),
                           name: NSWindow.willEnterFullScreenNotification, object: self)
        center.addObserver(self, selector: #selector(willExitFullScreen),
                           name: NSWindow.willExitFullScreenNotification, object: self)
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(fullScreenDidChange), name: name, object: self)
        }
        scheduleTabStripRefresh()
    }

    // MARK: Changes that affect the strip

    override var title: String {
        didSet { Self.tabStripChanged() }
    }

    override var keyEquivalent: String? {
        didSet { Self.tabStripChanged() }
    }

    override var tabColor: TerminalTabColor {
        didSet { Self.tabStripChanged() }
    }

    override func becomeKey() {
        super.becomeKey()
        Self.tabStripChanged()
    }

    override func resignKey() {
        super.resignKey()
        Self.tabStripChanged()
    }

    override func becomeMain() {
        super.becomeMain()
        hideNativeTabBar()
        Self.tabStripChanged()
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        lastStripConfig = surfaceConfig

        // The titlebar is layered above the content. It must stay clear so the strip
        // underneath it is visible; the strip paints the background itself. In fullscreen
        // the revealed titlebar keeps the terminal background (set by super), otherwise it
        // would slide over the terminal text transparently.
        if !inNativeFullScreen,
           let titlebarView = titlebarContainer?.firstDescendant(withClassName: "NSTitlebarView") {
            titlebarView.wantsLayer = true
            titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        // macOS 27 moves the scroll edge effect into the titlebar, over the strip.
        if #available(macOS 27, *),
           let scrollPocket = contentView?.superview?.firstDescendant(withClassName: "NSScrollPocket") {
            scrollPocket.isHidden = true
        }

        hideNativeTabBar()
        scheduleTabStripRefresh()
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        if isTabBar(childViewController) {
            childViewController.isHidden = true
        }
    }

    private func hideNativeTabBar() {
        for controller in titlebarAccessoryViewControllers where isTabBar(controller) {
            controller.isHidden = true
        }
    }

    // MARK: Fullscreen

    private var lastStripConfig: Ghostty.SurfaceView.DerivedConfig?
    private var enteringFullScreen = false

    /// Also true during the enter animation, so the strip leaves before the window grows.
    private var inNativeFullScreen: Bool { enteringFullScreen || styleMask.contains(.fullScreen) }

    @objc private func willEnterFullScreen() {
        enteringFullScreen = true
        applyFullScreenState()
    }

    @objc private func willExitFullScreen() {
        enteringFullScreen = false
        // Bring the strip back into the content as the window leaves fullscreen.
        removeFullScreenStrip()
        tabStrip.setVisible(true)
    }

    @objc private func fullScreenDidChange() {
        enteringFullScreen = false
        applyFullScreenState()
    }

    private func applyFullScreenState() {
        tabStrip.setVisible(!inNativeFullScreen)
        if inNativeFullScreen { addFullScreenStrip() } else { removeFullScreenStrip() }
        hideNativeTabBar()
        if let lastStripConfig { syncAppearance(lastStripConfig) }
        scheduleTabStripRefresh()
    }

    /// The strip as a titlebar accessory, shown by macOS in the fullscreen reveal.
    private var fullScreenStrip: NSTitlebarAccessoryViewController?

    private func addFullScreenStrip() {
        guard fullScreenStrip == nil else { return }
        let background = Color(nsColor: preferredBackgroundColor ?? .windowBackgroundColor)
        let host = NSHostingView(rootView: TerminalTabStrip(model: tabStrip, background: background,
                                                            ignoresVisibility: true))
        host.frame = NSRect(x: 0, y: 0, width: frame.width, height: 32)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = host
        accessory.layoutAttribute = .bottom
        // Hidden until the pointer reveals the menu bar and titlebar.
        accessory.fullScreenMinHeight = 0
        addTitlebarAccessoryViewController(accessory)
        fullScreenStrip = accessory
    }

    private func removeFullScreenStrip() {
        guard let accessory = fullScreenStrip else { return }
        fullScreenStrip = nil
        if let index = titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            removeTitlebarAccessoryViewController(at: index)
        }
    }

    // MARK: Refresh

    static func tabStripChanged() {
        NotificationCenter.default.post(name: .terminalTabStripNeedsRefresh, object: nil)
    }

    @objc private func tabStripNeedsRefresh() {
        scheduleTabStripRefresh()
    }

    @objc private func windowWillCloseSomewhere(_ notification: Notification) {
        guard notification.object is StripTabsTerminalWindow else { return }
        // The closing window is still part of its tab group at this point.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.scheduleTabStripRefresh()
        }
    }

    private var refreshScheduled = false

    private func scheduleTabStripRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshTabStrip()
        }
    }

    private func refreshTabStrip() {
        let windows = (tabbedWindows ?? [self]).filter { $0.isVisible || $0 === self }
        let selected = tabGroup?.selectedWindow ?? self
        tabStrip.update(
            tabs: windows.map { window in
                let terminal = window as? TerminalWindow
                let shortcut = terminal?.keyEquivalent.flatMap { $0.isEmpty ? nil : $0 }
                return .init(
                    id: ObjectIdentifier(window),
                    title: window.title.isEmpty ? "Terminal" : window.title,
                    shortcut: shortcut,
                    color: terminal?.tabColor ?? .none,
                    selected: window === selected)
            },
            layout: tabStripLayout,
            isKey: isKeyWindow)
    }

    private var tabStripLayout: TerminalTabStripModel.Layout {
        let fullscreen = styleMask.contains(.fullScreen) ||
            (terminalController?.fullscreenStyle?.isFullscreen ?? false)
        let titlebarHeight = frame.height - contentLayoutRect.height
        guard !fullscreen, titlebarHeight > 0 else {
            return .init(height: 32, leadingInset: 10)
        }

        var leading: CGFloat = 10
        if let zoom = standardWindowButton(.zoomButton), !zoom.isHidden, let superview = zoom.superview {
            leading = superview.convert(zoom.frame, to: nil).maxX + 14
        }
        return .init(height: max(titlebarHeight, 28), leadingInset: leading)
    }

    // MARK: Tab actions

    fileprivate func tabWindow(_ id: ObjectIdentifier) -> NSWindow? {
        (tabbedWindows ?? [self]).first { ObjectIdentifier($0) == id }
    }
}

extension Notification.Name {
    static let terminalTabStripNeedsRefresh = Notification.Name("com.arwinters.ghostty.tabStripNeedsRefresh")
}

/// State for the tab strip of one window. Each window in a tab group owns one; only the
/// selected (visible) window's strip is on screen.
final class TerminalTabStripModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let shortcut: String?
        let color: TerminalTabColor
        let selected: Bool
    }

    struct Layout: Equatable {
        let height: CGFloat
        let leadingInset: CGFloat
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var layout = Layout(height: 32, leadingInset: 78)
    @Published private(set) var isKey = false
    /// False in native fullscreen, where the native tab bar takes over.
    @Published private(set) var visible = true

    fileprivate weak var window: StripTabsTerminalWindow?

    fileprivate func setVisible(_ value: Bool) {
        if visible != value { visible = value }
    }

    fileprivate func update(tabs: [Tab], layout: Layout, isKey: Bool) {
        if self.tabs != tabs { self.tabs = tabs }
        if self.layout != layout { self.layout = layout }
        if self.isKey != isKey { self.isKey = isKey }
    }

    private func controller(_ id: ObjectIdentifier) -> TerminalController? {
        window?.tabWindow(id)?.windowController as? TerminalController
    }

    func select(_ id: ObjectIdentifier) {
        window?.tabWindow(id)?.makeKeyAndOrderFront(nil)
    }

    func close(_ id: ObjectIdentifier) {
        controller(id)?.closeTab(nil)
    }

    func closeOthers(_ id: ObjectIdentifier) {
        controller(id)?.closeOtherTabs(nil)
    }

    func closeToTheRight(_ id: ObjectIdentifier) {
        controller(id)?.closeTabsOnTheRight(nil)
    }

    func rename(_ id: ObjectIdentifier) {
        select(id)
        controller(id)?.promptTabTitle()
    }

    func setColor(_ color: TerminalTabColor, for id: ObjectIdentifier) {
        (window?.tabWindow(id) as? TerminalWindow)?.tabColor = color
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func move(_ id: ObjectIdentifier, by amount: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: index + amount)
    }

    /// Moves a tab to `index` in its window's tab group; the selected tab stays selected.
    func move(_ id: ObjectIdentifier, to index: Int) {
        guard let window, let group = window.tabGroup, let moving = window.tabWindow(id) else { return }
        let windows = group.windows
        guard let from = windows.firstIndex(of: moving) else { return }
        let target = min(max(index, 0), windows.count - 1)
        guard target != from else { return }
        let anchor = windows[target]
        let selected = group.selectedWindow
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        group.removeWindow(moving)
        anchor.addTabbedWindowSafely(moving, ordered: target < from ? .below : .above)
        if let selected {
            group.selectedWindow = selected
            selected.makeKey()
        }
        NSAnimationContext.endGrouping()
        StripTabsTerminalWindow.tabStripChanged()
    }
}

private struct TerminalTabStripKey: EnvironmentKey {
    static let defaultValue: TerminalTabStripModel? = nil
}

extension EnvironmentValues {
    /// Set when the window uses the Status Lab tab strip instead of native tabs.
    var terminalTabStrip: TerminalTabStripModel? {
        get { self[TerminalTabStripKey.self] }
        set { self[TerminalTabStripKey.self] = newValue }
    }
}
