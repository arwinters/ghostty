import AppKit
import SwiftUI

/// Status Lab replacement for `macos-titlebar-style = tabs`.
///
/// Native tabbing (tab groups, keyboard shortcuts, session restore) is kept as is, but the
/// native NSTabBar is hidden. Instead `TerminalView` draws a compact tab strip in the
/// transparent titlebar area. The strip lives in the content view, so it also stays visible
/// in native fullscreen and blends with the terminal background.
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
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(tabStripNeedsRefresh), name: name, object: self)
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

        // The titlebar is layered above the content. It must stay clear so the strip
        // underneath it is visible; the strip paints the background itself.
        if let titlebarView = titlebarContainer?.firstDescendant(withClassName: "NSTitlebarView") {
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

    fileprivate weak var window: StripTabsTerminalWindow?

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
