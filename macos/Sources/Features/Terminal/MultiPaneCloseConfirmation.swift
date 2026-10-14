import AppKit

/// Asks before closing a tab or window that contains more than one pane, so a split layout
/// is not lost by one click. Status Lab builds only; "Don't ask again" turns it off.
enum MultiPaneCloseConfirmation {
    private static let suppressKey = "StatusLabDoNotConfirmMultiPaneClose"

    static var isEnabled: Bool {
        PluginManager.enabled && !UserDefaults.standard.bool(forKey: suppressKey)
    }

    /// `tabs` is nil when closing a single tab, or the tab count when closing a window.
    static func ask(window: NSWindow, panes: Int, tabs: Int?, running: Bool, close: @escaping () -> Void) {
        // Show the tab being closed, not whichever tab happened to be selected.
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        let what: String
        if let tabs, tabs > 1 {
            what = "window with \(tabs) tabs and \(panes) panes"
        } else {
            what = tabs == nil ? "tab with \(panes) panes" : "window with \(panes) panes"
        }
        alert.messageText = "Close this \(what)?"
        alert.informativeText = running
            ? "At least one pane is still running a program; closing stops it. The split layout is closed too."
            : "All \(panes) panes and their split layout will be closed. Saved sessions in the Session Manager are kept."
        alert.addButton(withTitle: tabs == nil ? "Close Tab" : "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again when closing several panes"
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: suppressKey)
            }
            close()
        }
    }
}
