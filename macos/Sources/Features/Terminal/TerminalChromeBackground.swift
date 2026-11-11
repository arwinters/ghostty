import AppKit
import SwiftUI

/// Status Lab: the background of what Ghostty draws next to the terminal (the status bar
/// and the tab strip). It follows the window: see-through with `background-opacity` while
/// the window is (blur and glass then show through, as behind the terminal), and opaque
/// when Ghostty makes the window opaque, such as in native fullscreen or after
/// toggle_background_opacity.
struct TerminalChromeBackground: NSViewRepresentable {
    let color: Color
    let opacity: Double

    func makeNSView(context: Context) -> ChromeBackgroundView { ChromeBackgroundView() }

    func updateNSView(_ view: ChromeBackgroundView, context: Context) {
        view.color = NSColor(color)
        view.opacity = opacity
    }
}

final class ChromeBackgroundView: NSView {
    var color: NSColor = .black { didSet { refresh() } }
    var opacity: Double = 1 { didSet { refresh() } }
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        // Ghostty changes the window's opacity in place (fullscreen, configuration reload,
        // toggling opacity); a window update follows each change. Only a comparison runs.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func refresh() {
        let alpha = window?.isOpaque == false ? opacity.clamped(to: 0...1) : 1
        let value = color.withAlphaComponent(alpha).cgColor
        if layer?.backgroundColor != value { layer?.backgroundColor = value }
    }

    // A background only: clicks go to the views on top of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
