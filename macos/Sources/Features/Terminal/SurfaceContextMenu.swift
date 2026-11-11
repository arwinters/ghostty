import AppKit
import GhosttyKit

/// Status Lab: the right-click menu of a terminal pane.
///
/// Right-click always opens this menu, also inside tmux (see `rightClickMods` in
/// SurfaceView_AppKit). Actions that concern the clicked pane target it directly; the
/// clicked pane is not necessarily the focused one.
extension Ghostty.SurfaceView {
    func statusLabContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        @discardableResult
        func add(_ title: String, _ action: Selector, symbol: String? = nil, target: AnyObject? = nil,
                 enabled: Bool = true, tip: String? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target ?? self
            item.isEnabled = enabled
            item.toolTip = tip
            if let symbol { item.setImageIfDesired(systemSymbolName: symbol) }
            return item
        }

        // Clipboard
        let hasSelection = (accessibilitySelectedText()?.isEmpty == false)
        add("Copy", #selector(copy(_:)), symbol: "doc.on.doc", enabled: hasSelection)
        add("Paste", #selector(paste(_:)), symbol: "doc.on.clipboard",
            enabled: NSPasteboard.general.string(forType: .string) != nil)
        add("Select All", #selector(selectAll(_:)), symbol: "selection.pin.in.out")
        add("Find…", #selector(find(_:)), symbol: "magnifyingglass")

        // Layout
        menu.addItem(.separator())
        add("New Tab", #selector(contextNewTab(_:)), symbol: "plus.rectangle.on.rectangle")
        add("Split Right", #selector(splitRight(_:)), symbol: "rectangle.righthalf.inset.filled")
        add("Split Down", #selector(splitDown(_:)), symbol: "rectangle.bottomhalf.inset.filled")
        let more = NSMenu()
        for (title, action, symbol) in [
            ("Split Left", #selector(splitLeft(_:)), "rectangle.leadinghalf.inset.filled"),
            ("Split Up", #selector(splitUp(_:)), "rectangle.tophalf.inset.filled"),
        ] {
            let item = more.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.setImageIfDesired(systemSymbolName: symbol)
        }
        let inSplit = (window?.windowController as? BaseTerminalController)?.surfaceTree.isSplit ?? false
        if inSplit {
            more.addItem(.separator())
            let zoom = more.addItem(withTitle: "Zoom Pane", action: #selector(contextToggleZoom(_:)), keyEquivalent: "")
            zoom.target = self
            zoom.setImageIfDesired(systemSymbolName: "arrow.up.left.and.arrow.down.right")
            let equalize = more.addItem(withTitle: "Make Panes Equal", action: #selector(contextEqualize(_:)), keyEquivalent: "")
            equalize.target = self
            equalize.setImageIfDesired(systemSymbolName: "equal.square")
        }
        let moreItem = menu.addItem(withTitle: "More Splits", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        moreItem.setImageIfDesired(systemSymbolName: "rectangle.split.2x2")
        if inSplit {
            add("Close Split", #selector(closeSurface(_:)), symbol: "xmark.rectangle")
        }

        // Working directory
        if let directory = contextDirectory {
            menu.addItem(.separator())
            let header = menu.addItem(withTitle: (directory as NSString).abbreviatingWithTildeInPath,
                                      action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.setImageIfDesired(systemSymbolName: "folder")
            add("Open in Finder", #selector(contextOpenDirectory(_:)), symbol: "arrow.up.forward.app")
            add("Copy Path", #selector(contextCopyDirectory(_:)), symbol: "link")
        }

        // Status Lab: tmux profiles and detached sessions, opened next to this pane.
        let tmux = TmuxPlugin.shared.contextMenuItem(for: self)
        let sessions = SessionManager.shared.enabled
        if tmux != nil || sessions { menu.addItem(.separator()) }
        if let tmux { menu.addItem(tmux) }
        if sessions {
            let submenu = NSMenu()
            SessionManager.shared.addWorkspaceItems(to: submenu)
            submenu.addItem(.separator())
            let manager = submenu.addItem(withTitle: "Session Manager…",
                                          action: #selector(SessionManager.showSessions), keyEquivalent: "")
            manager.target = SessionManager.shared
            manager.setImageIfDesired(systemSymbolName: "square.stack.3d.up")
            let item = menu.addItem(withTitle: SessionManager.shared.activeName.map { "Workspace: \($0)" } ?? "Workspaces",
                                    action: nil, keyEquivalent: "")
            item.submenu = submenu
            item.setImageIfDesired(systemSymbolName: "square.stack.3d.up")
        }

        // Terminal
        menu.addItem(.separator())
        add("Restart Terminal…", #selector(restartTerminal(_:)), symbol: "arrow.clockwise.circle",
            tip: "For a stuck pane: stops every program in this pane and starts a new shell in the same directory.")
        add("Clear Garbled Screen", #selector(resetTerminal(_:)), symbol: "eraser",
            tip: "Resets the screen and terminal modes after garbled output. Programs keep running.")
        add("Terminal Read-only", #selector(toggleReadonly(_:)), symbol: "eye.fill").state = readonly ? .on : .off
        add("Toggle Terminal Inspector", #selector(toggleTerminalInspector(_:)), symbol: "scope")

        // Titles
        menu.addItem(.separator())
        let tabTitle = menu.addItem(withTitle: "Change Tab Title…",
                                    action: #selector(BaseTerminalController.changeTabTitle(_:)), keyEquivalent: "")
        tabTitle.setImageIfDesired(systemSymbolName: "pencil.line")
        add("Change Terminal Title…", #selector(changeTitle(_:)))

        return menu
    }

    /// The pane's directory; tmux panes report theirs through tmux.
    private var contextDirectory: String? {
        let directory = TmuxPlugin.shared.path(for: id) ?? pwd
        guard let directory, directory.hasPrefix("/") else { return nil }
        return directory
    }

    private func bindingAction(_ action: String) {
        guard let surface else { return }
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
            AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
        }
    }

    @objc fileprivate func contextNewTab(_ sender: Any?) { bindingAction("new_tab") }
    @objc fileprivate func contextToggleZoom(_ sender: Any?) { bindingAction("toggle_split_zoom") }
    @objc fileprivate func contextEqualize(_ sender: Any?) { bindingAction("equalize_splits") }

    @objc fileprivate func contextOpenDirectory(_ sender: Any?) {
        guard let directory = contextDirectory else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
    }

    @objc fileprivate func contextCopyDirectory(_ sender: Any?) {
        guard let directory = contextDirectory else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory, forType: .string)
    }
}
