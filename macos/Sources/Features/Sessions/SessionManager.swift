import AppKit
import SwiftUI
import GhosttyKit

/// App-owned persistence is independent of external status-plugin processes.
///
/// The open windows always belong to a workspace. The current workspace saves itself:
/// opening another workspace saves and closes the open windows first. When no workspace
/// exists, one is created from the open windows.
///
/// Checkpoints are cheap by design. Every few seconds only the layout is compared
/// (windows, tabs, splits, directories, tmux state): no terminal text is read. A layout
/// change is saved at once, together with the *visible* screen of each pane. Without a
/// layout change, the visible screens are saved at most once a minute. The expensive read
/// of scrollback happens only when quitting, before sleep and when switching workspaces.
/// Every save also keeps an automatic checkpoint: the workspace's earlier versions, and
/// what the next launch restores.
final class SessionManager: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = SessionManager()

    /// Stored snapshots, newest first. Summaries only: saved output stays on disk.
    @Published private(set) var sessions: [SessionSnapshot.Summary] = []
    @Published private(set) var message = "Waiting for first checkpoint"
    @Published private(set) var failed = false
    @Published private(set) var lastSaved: Date?
    /// The windows that are open now, as the next checkpoint would save them.
    @Published private(set) var current: SessionSnapshot.Summary?
    /// The checkpoint this launch restored, so a wrong pick is easy to spot and correct.
    @Published private(set) var restoredAtLaunch: SessionSnapshot.Summary?
    @Published private(set) var storageBytes = 0
    /// The workspace the open windows are saved in.
    @Published private(set) var activeWorkspace: UUID? {
        didSet { UserDefaults.standard.set(activeWorkspace?.uuidString, forKey: Self.activeWorkspaceKey) }
    }

    @Published var restoreOnLaunch: Bool {
        didSet { UserDefaults.standard.set(restoreOnLaunch, forKey: Self.restoreOnLaunchKey) }
    }
    @Published var saveOutput: Bool {
        didSet { UserDefaults.standard.set(saveOutput, forKey: Self.saveOutputKey) }
    }
    private static let restoreOnLaunchKey = "StatusLabSessionsRestoreOnLaunch"
    private static let saveOutputKey = "StatusLabSessionsSaveOutput"
    private static let activeWorkspaceKey = "StatusLabSessionsActiveWorkspace"

    /// Seconds between layout comparisons, and between saves of only the visible output.
    static let tickInterval: TimeInterval = 5
    static let outputInterval: TimeInterval = 60

    private enum Depth {
        /// Structure only; for change detection and the live summary.
        case layout
        /// Plus the visible screen of each pane: cheap, for periodic checkpoints.
        case visible
        /// Plus recent scrollback: for quit, sleep and switching workspaces.
        case full
    }

    private var timer: Timer?
    private var panel: NSWindow?
    private var restoring = false
    private var started = false
    private var lastLayout: Data?
    private var lastContent: Data?
    private var lastWrite = Date.distantPast
    private var retainedControllers: [TerminalController] = []
    /// Windows of the previous workspace while they close; never saved again.
    private var closing = Set<ObjectIdentifier>()
    private var fontSizes: [UUID: (NSSize, Float)] = [:]
    private var launchSnapshot: SessionSnapshot.Summary?
    private var launchRestorationHandled = false
    /// Name for the workspace created by the next save, for "New Workspace".
    private var pendingWorkspaceName: String?
    /// Set once termination is certain. While AppKit tears windows down it detaches tabs
    /// from their groups first, so any later checkpoint would save tabs as separate windows.
    private var terminating = false
    private let store: SessionStore

    var enabled: Bool {
        // This experimental feature ships in Status Lab builds only (see
        // examples/status-plugins/status-lab), which run beside a normal Ghostty.
        PluginManager.enabled &&
            (NSApp.delegate as? AppDelegate)?.ghostty.config.windowSaveState != "never"
    }

    /// The Session Manager decides what opens at launch, also when it opens nothing:
    /// macOS window restoration would otherwise open a second copy of the windows.
    var ownsLaunchRestoration: Bool {
        enabled && (launchSnapshot != nil || launchRestorationHandled || !restoreOnLaunch)
    }

    var workspaces: [SessionSnapshot.Summary] { sessions.filter(\.isWorkspace) }
    var activeSummary: SessionSnapshot.Summary? {
        activeWorkspace.flatMap { id in sessions.first { $0.id == id && $0.isWorkspace } }
    }
    var activeName: String? { activeSummary?.name }

    /// Automatic checkpoints of a workspace, newest first.
    func history(of workspace: UUID) -> [SessionSnapshot.Summary] {
        sessions.filter { $0.isAutomatic && $0.workspace == workspace }
    }

    private override init() {
        store = SessionStore(directory: PluginManager.supportDirectory.appendingPathComponent("sessions"))
        let defaults = UserDefaults.standard
        restoreOnLaunch = defaults.object(forKey: Self.restoreOnLaunchKey) as? Bool ?? true
        saveOutput = defaults.object(forKey: Self.saveOutputKey) as? Bool ?? true
        activeWorkspace = defaults.string(forKey: Self.activeWorkspaceKey).flatMap(UUID.init(uuidString:))
        super.init()
        // Replay files are read once by the shells of the previous launch's restore. They
        // contain plain terminal output, so do not keep them around.
        if let entries = try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("replay-") {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        reload()
        launchSnapshot = sessions.first(where: \.isAutomatic)
    }

    func start() {
        guard enabled, !started else { return }
        started = true
        let menu = NSMenu(title: "Sessions")
        menu.delegate = self
        let root = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        root.submenu = menu
        NSApp.mainMenu?.insertBeforeHelp(root)
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        // Let macOS coalesce the wakeups with other timers.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkpointBeforeSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
    }

    @objc private func checkpointBeforeSleep() { checkpoint() }

    @discardableResult func restoreAtLaunch() -> Bool {
        guard ownsLaunchRestoration else { return false }
        launchRestorationHandled = true
        guard restoreOnLaunch, let summary = launchSnapshot else {
            // A fresh start must not overwrite the workspace that was open last time.
            if !restoreOnLaunch { activeWorkspace = nil }
            return false
        }
        launchSnapshot = nil
        do {
            let snapshot = try store.load(summary.id)
            // Preserve the previous launch independently of the rolling autosave queue.
            var recovery = snapshot
            recovery.id = UUID()
            recovery.name = SessionSnapshot.recoveryPrefix + Date().formatted(date: .numeric, time: .shortened)
            try store.save(recovery)
            // Recovery points are named, so the automatic rotation skips them; keep 10.
            for old in store.summaries().filter(\.isRecoveryPoint).dropFirst(10) { try store.delete(old.id) }
            reload()
            if let workspace = snapshot.workspace, workspaces.contains(where: { $0.id == workspace }) {
                activeWorkspace = workspace
            }
            guard restore(snapshot, skipOpenTmux: false) else { return false }
            restoredAtLaunch = summary
            return true
        } catch { report(error); return false }
    }

    /// Freeze persistence; the checkpoint from applicationShouldTerminate is final.
    func prepareForTermination() {
        terminating = true
        timer?.invalidate()
    }

    // MARK: Checkpoints

    /// Saves the open windows now, including recent scrollback.
    func checkpoint() {
        guard enabled, !restoring, started, !terminating else { return }
        // Before quit or sleep the status bar polling may be paused; ask tmux once.
        TmuxPlugin.shared.refreshPaths(synchronously: true)
        save(depth: .full)
    }

    private func tick() {
        guard enabled, !restoring, started, !terminating else { return }
        let windows = capture(.layout)
        let summary = windows.isEmpty ? nil : SessionSnapshot(windows: windows).summary
        // Each capture is a new snapshot: compare content, or the status bar redraws every tick.
        let unchanged = summary.map { $0.hasSameContent(as: current) } ?? (current == nil)
        if !unchanged { current = summary }
        guard !windows.isEmpty, let layout = try? Self.encode(windows) else { return }
        if layout != lastLayout || activeSummary == nil {
            save(depth: .visible, layout: layout)
        } else if saveOutput, Date().timeIntervalSince(lastWrite) >= Self.outputInterval {
            save(depth: .visible, layout: layout)
        }
    }

    /// Writes an automatic checkpoint and the current workspace, creating the workspace
    /// when there is none.
    private func save(depth: Depth, layout: Data? = nil) {
        do {
            let windows = capture(depth)
            // Closing windows, failed startup, or a transient empty UI must never erase the last session.
            guard !windows.isEmpty else { return }
            let content = try Self.encode(windows)
            lastLayout = try layout ?? Self.encode(capture(.layout))
            let created = try ensureWorkspace(windows)
            guard content != lastContent || created != nil,
                  let workspace = activeSummary else { return }
            let checkpoint = SessionSnapshot(windows: windows, workspace: workspace.id)
            try store.save(checkpoint)
            try store.save(SessionSnapshot(id: workspace.id, date: checkpoint.date, name: workspace.name,
                                           windows: windows))
            lastContent = content
            lastWrite = Date()
            lastSaved = checkpoint.date
            failed = false
            reload()
            message = created.map { "Created workspace “\($0)”" }
                ?? "Saved \(checkpoint.date.formatted(date: .omitted, time: .standard))"
        } catch { report(error) }
    }

    /// Creates a workspace for the open windows when they have none. Returns its name.
    private func ensureWorkspace(_ windows: [SessionSnapshot.Window]) throws -> String? {
        guard activeSummary == nil else { return nil }
        let name = uniqueName(pendingWorkspaceName ?? (workspaces.isEmpty ? "Default" : "Workspace"))
        let snapshot = SessionSnapshot(name: name, windows: windows)
        try store.save(snapshot)
        pendingWorkspaceName = nil
        activeWorkspace = snapshot.id
        reload()
        return name
    }

    private static func encode(_ windows: [SessionSnapshot.Window]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(windows)
    }

    private func capture(_ depth: Depth) -> [SessionSnapshot.Window] {
        var groups: [ObjectIdentifier: Int] = [:]
        var windows: [SessionSnapshot.Window] = []
        var seen = Set<ObjectIdentifier>()
        let ordered = TerminalController.all.flatMap { controller in
            (controller.window?.tabbedWindows ?? [controller.window].compactMap { $0 })
                .compactMap { $0.windowController as? TerminalController }
        }.filter { seen.insert(ObjectIdentifier($0)).inserted && !closing.contains(ObjectIdentifier($0)) }
        for controller in ordered {
            guard let window = controller.window, window.isRestorable,
                  let root = controller.surfaceTree.root else { continue }
            let groupKey = ObjectIdentifier(window.tabGroup ?? window)
            let group = groups[groupKey] ?? groups.count
            groups[groupKey] = group
            let frame = window.frame
            windows.append(.init(
                group: group, selected: window.tabGroup?.selectedWindow === window || window.tabGroup == nil,
                key: window.isKeyWindow,
                frame: [frame.origin.x, frame.origin.y, frame.width, frame.height],
                fullscreen: window.styleMask.contains(.fullScreen), title: controller.titleOverride,
                tabColor: (window as? TerminalWindow).map { String($0.tabColor.rawValue) },
                focused: controller.focusedSurface?.id,
                zoomed: controller.surfaceTree.zoomed?.leaves().first?.id,
                tree: capture(root, depth)))
        }
        return windows
    }

    private func capture(_ node: SplitTree<Ghostty.SurfaceView>.Node, _ depth: Depth) -> SessionSnapshot.Node {
        switch node {
        case .leaf(let view):
            // The inherited-config API allocates a working-directory copy. Do not call it every tick.
            if fontSizes[view.id]?.0 != view.cellSize {
                fontSizes[view.id] = (view.cellSize, view.surface.map {
                    ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size
                } ?? 0)
            }
            let size = fontSizes[view.id]?.1 ?? 0
            // tmux keeps its own scrollback; saving the screen of a tmux pane adds nothing.
            let tmux = TmuxPlugin.shared.snapshotPane(for: view.id)
            let transcript = tmux == nil ? self.transcript(of: view, depth) : ""
            // Programs animate their titles (spinners); only a custom title is layout.
            let title = depth == .layout && !view.sessionHasCustomTitle ? "" : view.title
            return .pane(.init(id: view.id, directory: SessionSnapshot.safeDirectory(view.pwd), title: title,
                               customTitle: view.sessionHasCustomTitle, fontSize: size,
                               transcript: transcript, tmux: tmux))
        case .split(let split):
            return .split(horizontal: split.direction == .horizontal, ratio: split.ratio,
                          left: capture(split.left, depth), right: capture(split.right, depth))
        }
    }

    private func transcript(of view: Ghostty.SurfaceView, _ depth: Depth) -> String {
        guard saveOutput else { return "" }
        switch depth {
        case .layout:
            return ""
        case .visible:
            return SessionSnapshot.safeTranscript(Self.activeScreenText(view))
        case .full:
            return SessionSnapshot.safeTranscript(view.cachedScreenContents.get())
        }
    }

    /// The rows of the active screen only, never the scrollback above it.
    private static func activeScreenText(_ view: Ghostty.SurfaceView) -> String {
        guard let surface = view.surface else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        var value = String(cString: text.text)
        while let last = value.last, last.isWhitespace { value.removeLast() }
        return value
    }

    // MARK: Workspaces

    /// Opens a workspace in place of the open windows, which are saved in the current
    /// workspace first. Other snapshots open next to the open windows.
    func open(_ summary: SessionSnapshot.Summary) {
        guard summary.isWorkspace else { return restore(summary) }
        guard summary.id != activeWorkspace else {
            // Already open: bring its windows forward.
            TerminalController.all.first?.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard confirmClosingOpenWindows(for: summary.name ?? "Workspace") else { return }
        do {
            let snapshot = try store.load(summary.id)
            // The windows being replaced may show the same tmux sessions: attach them anyway.
            guard replaceOpenWindows({ restore(snapshot, skipOpenTmux: false) }) else { return }
            activeWorkspace = summary.id
        } catch {
            reload()
            report(error)
        }
    }

    /// Opens a stored snapshot next to the open windows, as part of the current workspace.
    func restore(_ summary: SessionSnapshot.Summary) {
        do {
            let snapshot = try store.load(summary.id)
            restore(snapshot, skipOpenTmux: true)
        } catch {
            reload()
            report(error)
        }
    }

    /// Starts a new workspace with one new window; the open windows stay in their workspace.
    @objc func promptNewWorkspace(_ sender: Any?) {
        guard let name = Self.askName(title: "New Workspace",
                                      message: "Opens one new window. The open windows are saved in “\(activeName ?? "the current workspace")” and closed.",
                                      value: "", button: "Create") else { return }
        guard confirmClosingOpenWindows(for: name) else { return }
        guard replaceOpenWindows({ openEmptyWindow() }) else { return }
        activeWorkspace = nil
        pendingWorkspaceName = Self.clean(name)
        tick()
    }

    /// Saves the open windows as a new workspace, which becomes the current one. The
    /// previous workspace keeps its state from just before.
    @objc func promptSaveAsWorkspace(_ sender: Any?) {
        let suggestion = current?.places.prefix(3).joined(separator: ", ") ?? ""
        guard let name = Self.askName(title: "Save as New Workspace",
                                      message: "The open windows continue in the new workspace. “\(activeName ?? "The current workspace")” keeps its current state.",
                                      value: suggestion, button: "Save") else { return }
        saveAsWorkspace(name)
    }

    func saveAsWorkspace(_ name: String) {
        guard enabled, started, !restoring else { return }
        checkpoint()
        let windows = capture(.full)
        guard !windows.isEmpty else { return }
        do {
            let snapshot = SessionSnapshot(name: uniqueName(Self.clean(name)), windows: windows)
            try store.save(snapshot)
            activeWorkspace = snapshot.id
            reload()
            message = "Saved workspace “\(snapshot.name!)”"
        } catch { report(error) }
    }

    @objc private func openWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let summary = workspaces.first(where: { $0.id == id }) else { return }
        open(summary)
    }

    /// Asks before programs in the open windows are stopped. tmux sessions keep running.
    private func confirmClosingOpenWindows(for name: String) -> Bool {
        let running = TerminalController.all.contains { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) }
        guard running else { return true }
        let alert = NSAlert()
        alert.messageText = "Open “\(name)”?"
        alert.informativeText = "The open windows are saved in “\(activeName ?? "the current workspace")” and closed. " +
            "Programs running in them stop; tmux sessions keep running."
        alert.addButton(withTitle: "Open Workspace")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Saves the open windows, opens the new ones, then closes the old ones. Opening first
    /// keeps the app from quitting when its last window closes.
    private func replaceOpenWindows(_ openNew: () -> Bool) -> Bool {
        checkpoint()
        let old = TerminalController.all
        guard openNew() else { return false }
        closing.formUnion(old.map(ObjectIdentifier.init))
        lastLayout = nil
        lastContent = nil
        let undo = (NSApp.delegate as? AppDelegate)?.undoManager
        undo?.disableUndoRegistration()
        var groups = Set<ObjectIdentifier>()
        for controller in old {
            guard let window = controller.window,
                  groups.insert(ObjectIdentifier(window.tabGroup ?? window)).inserted else { continue }
            controller.closeWindowImmediately()
        }
        undo?.enableUndoRegistration()
        return true
    }

    private func openEmptyWindow() -> Bool {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty, let handle = app.app else { return false }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = NSHomeDirectory()
        let view = Ghostty.SurfaceView(handle, baseConfig: config)
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        retainedControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: Restoring

    /// Every pane is restored at launch and when switching workspaces. When opening a
    /// snapshot next to the open windows, tmux sessions that are already shown in a pane are
    /// skipped: a second client would mirror the same session in two places.
    @discardableResult private func restore(_ snapshot: SessionSnapshot, skipOpenTmux: Bool) -> Bool {
        guard !restoring, let app = (NSApp.delegate as? AppDelegate)?.ghostty, let handle = app.app else { return false }
        restoring = true
        defer { restoring = false }
        do {
            try snapshot.validate()
            // Prepare every transcript before creating any terminal.
            try store.prepare()
            let replay = store.directory.appendingPathComponent("replay-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: replay, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            for pane in snapshot.windows.flatMap({ $0.tree.panes }) where pane.tmux == nil {
                let saved = SessionSnapshot.safeTranscript(pane.transcript)
                let text = saved + (saved.isEmpty ? "" : "\n") + "— Restored session · new shell —\n"
                try text.write(to: replay.appendingPathComponent(pane.id.uuidString), atomically: true, encoding: .utf8)
            }
            let skip: Set<String> = skipOpenTmux ? TmuxPlugin.shared.shownSessions : []
            var groups: [Int: NSWindow] = [:]
            var selected: [NSWindow] = []
            var key: NSWindow?
            var opened = 0
            var skipped = 0
            for saved in snapshot.windows {
                var views: [UUID: Ghostty.SurfaceView] = [:]
                guard let root = makeTree(saved.tree, app: handle, replay: replay, skip: skip,
                                          skipped: &skipped, views: &views) else { continue }
                opened += views.count
                var tree = SplitTree<Ghostty.SurfaceView>(root: root, zoomed: nil)
                if let id = saved.zoomed, let view = views[id] { tree = .init(root: root, zoomed: tree.find(id: view.id)) }
                let controller = TerminalController(app, withSurfaceTree: tree)
                retainedControllers.append(controller)
                controller.titleOverride = saved.title
                controller.showWindow(nil)
                guard let window = controller.window else { continue }
                window.tabbingMode = .disallowed
                window.setFrame(NSRect(x: saved.frame[0], y: saved.frame[1],
                                       width: saved.frame[2], height: saved.frame[3]), display: true)
                window.constrainToScreen()
                if let color = saved.tabColor.flatMap(Int.init).flatMap(TerminalTabColor.init(rawValue:)) {
                    (window as? TerminalWindow)?.tabColor = color
                }
                if let first = groups[saved.group] {
                    first.addTabbedWindowSafely(window, ordered: .above)
                } else {
                    groups[saved.group] = window
                }
                window.tabbingMode = .automatic
                if saved.selected { selected.append(window) }
                if saved.key { key = window }
                if let id = saved.focused, let view = views[id] {
                    controller.focusedSurface = view
                    TerminalWindowRestoration.restoreFocus(to: view, inWindow: window)
                }
                if saved.fullscreen, saved.selected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { window.toggleFullScreen(nil) }
                }
            }
            selected.forEach { $0.tabGroup?.selectedWindow = $0 }
            (key ?? selected.first)?.makeKeyAndOrderFront(nil)
            reload()
            failed = false
            if opened == 0 {
                message = "Nothing to restore: its \(skipped) tmux session\(skipped == 1 ? " is" : "s are") already open"
                return false
            }
            message = "Restored \(opened) pane\(opened == 1 ? "" : "s")" +
                (skipped > 0 ? "; \(skipped) open tmux session\(skipped == 1 ? "" : "s") skipped" : "")
            // Replay files are read by newly starting shells. Keep them until the next launch.
            return true
        } catch { report(error); return false }
    }

    /// nil when every pane of the subtree was skipped; a split then collapses to its other side.
    private func makeTree(_ node: SessionSnapshot.Node, app: ghostty_app_t, replay: URL, skip: Set<String>,
                          skipped: inout Int, views: inout [UUID: Ghostty.SurfaceView]) -> SplitTree<Ghostty.SurfaceView>.Node? {
        switch node {
        case .pane(let pane):
            if let tmux = pane.tmux {
                if skip.contains(tmux.session) {
                    skipped += 1
                    return nil
                }
                // Reattaches when tmux survived (app crash); recreates it after a restart.
                let view = TmuxPlugin.shared.restoreView(tmux, app: app, fontSize: pane.fontSize)
                view.sessionRestoreTitle(pane.title, custom: pane.customTitle)
                views[pane.id] = view
                return .leaf(view: view)
            }
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = pane.directory
            config.fontSize = pane.fontSize
            let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
            let file = replay.appendingPathComponent(pane.id.uuidString).path
            let script = "/bin/cat " + SessionSnapshot.shellQuote(file) + "; exec " + SessionSnapshot.shellQuote(shell) + " -l"
            config.command = "/bin/sh -c " + SessionSnapshot.shellQuote(script)
            // The wrapper is sh, but the final shell still needs native Ghostty zsh integration.
            if URL(fileURLWithPath: shell).lastPathComponent == "zsh", let resources = Bundle.main.resourceURL {
                if let original = ProcessInfo.processInfo.environment["ZDOTDIR"] {
                    config.environmentVariables["GHOSTTY_ZSH_ZDOTDIR"] = original
                }
                config.environmentVariables["ZDOTDIR"] = resources.appendingPathComponent("ghostty/shell-integration/zsh").path
            }
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            view.sessionRestoreTitle(pane.title, custom: pane.customTitle)
            views[pane.id] = view
            return .leaf(view: view)
        case .split(let horizontal, let ratio, let left, let right):
            let first = makeTree(left, app: app, replay: replay, skip: skip, skipped: &skipped, views: &views)
            let second = makeTree(right, app: app, replay: replay, skip: skip, skipped: &skipped, views: &views)
            guard let first else { return second }
            guard let second else { return first }
            return .split(.init(direction: horizontal ? .horizontal : .vertical, ratio: ratio,
                                left: first, right: second))
        }
    }

    func closed(_ controller: TerminalController) {
        retainedControllers.removeAll { $0 === controller }
        closing.remove(ObjectIdentifier(controller))
        for view in controller.surfaceTree {
            fontSizes.removeValue(forKey: view.id)
            TmuxPlugin.shared.forget(view.id)
        }
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = NSMenuItem(title: "Session Manager…", action: #selector(showSessions), keyEquivalent: "S")
        manager.keyEquivalentModifierMask = [.command, .shift]
        manager.target = self
        menu.addItem(manager)
        menu.addItem(.separator())
        addWorkspaceItems(to: menu)
    }

    /// The workspaces, with the current one checked, and the actions that create one.
    func addWorkspaceItems(to menu: NSMenu) {
        if !workspaces.isEmpty {
            let header = menu.addItem(withTitle: "Workspaces", action: nil, keyEquivalent: "")
            header.isEnabled = false
            for workspace in workspaces.sorted(by: { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }) {
                let item = menu.addItem(withTitle: workspace.name ?? "Workspace",
                                        action: #selector(openWorkspaceFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = workspace.id
                item.state = workspace.id == activeWorkspace ? .on : .off
                item.indentationLevel = 1
            }
            menu.addItem(.separator())
        }
        for (title, action, symbol) in [
            ("New Workspace…", #selector(promptNewWorkspace(_:)), "plus.square.on.square"),
            ("Save as New Workspace…", #selector(promptSaveAsWorkspace(_:)), "square.and.arrow.down"),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.setImageIfDesired(systemSymbolName: symbol)
        }
    }

    // MARK: Managing stored sessions

    @objc func showSessions() {
        if panel == nil {
            panel = ManagerWindow.make(title: "Session Manager", autosave: "StatusLabSessionManager",
                                       rootView: SessionManagerView(manager: self))
        }
        tick()
        storageBytes = store.size()
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Removes stored snapshots after confirmation. The current workspace is kept: the
    /// open windows are saved in it. A deleted workspace takes its earlier versions along.
    func delete(_ ids: Set<UUID>) {
        let targets = sessions.filter { ids.contains($0.id) && $0.id != activeWorkspace }
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        if targets.count == 1, let only = targets.first {
            alert.messageText = "Delete “\(only.name ?? "checkpoint")”?"
        } else {
            alert.messageText = "Delete \(targets.count) items?"
        }
        alert.informativeText = targets.contains(where: \.isWorkspace)
            ? "Workspaces are deleted with their earlier versions. This cannot be undone."
            : "This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            for target in targets {
                if target.isWorkspace {
                    for version in history(of: target.id) { try store.delete(version.id) }
                }
                try store.delete(target.id)
            }
            reload()
            message = targets.count == 1 ? "Deleted “\(targets[0].name ?? "checkpoint")”" : "Deleted \(targets.count) items"
        } catch { report(error) }
    }

    /// Deletes every automatic checkpoint except the newest, which the next launch restores.
    func deleteOlderCheckpoints() {
        do {
            for old in sessions.filter(\.isAutomatic).dropFirst() { try store.delete(old.id) }
            reload()
            message = "Deleted earlier versions"
        } catch { report(error) }
    }

    /// Renames a workspace, or keeps a backup as a new workspace.
    func rename(_ summary: SessionSnapshot.Summary) {
        let keep = !summary.isWorkspace
        guard let name = Self.askName(title: keep ? "Keep as Workspace" : "Rename Workspace",
                                      message: keep ? "Workspaces are kept until you delete them." : "",
                                      value: keep ? summary.places.prefix(3).joined(separator: ", ") : summary.name ?? "",
                                      button: keep ? "Keep" : "Rename") else { return }
        do {
            var snapshot = try store.load(summary.id)
            snapshot.name = uniqueName(Self.clean(name), except: keep ? nil : summary.id)
            snapshot.workspace = nil
            // A kept backup becomes a copy; the original stays where it was.
            if keep { snapshot.id = UUID() }
            try store.save(snapshot)
            reload()
            message = keep ? "Kept as workspace “\(snapshot.name!)”" : "Renamed to “\(snapshot.name!)”"
        } catch { report(error) }
    }

    func revealStorage() {
        try? store.prepare()
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }

    private func reload() {
        let value = store.summaries()
        if value != sessions { sessions = value }
        if panel?.isVisible == true { storageBytes = store.size() }
    }

    private static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Workspace" : String(trimmed.prefix(80))
    }

    /// The name, or the name with the lowest free number appended.
    private func uniqueName(_ name: String, except id: UUID? = nil) -> String {
        let taken = Set(workspaces.filter { $0.id != id }.compactMap { $0.name?.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    private static func askName(title: String, message: String, value: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        field.placeholderString = "For example: Client project"
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func report(_ error: Error) {
        failed = true
        message = "Session recovery error: \(error.localizedDescription)"
        AppDelegate.logger.error("\(self.message, privacy: .public)")
    }
}

// MARK: - Session Manager window

private struct SessionManagerView: View {
    @ObservedObject var manager: SessionManager
    @State private var page: Page = .workspaces

    enum Page: String, CaseIterable, Identifiable {
        case workspaces, backups, settings
        var id: String { rawValue }
    }

    private var backups: [SessionSnapshot.Summary] { manager.sessions.filter(\.isRecoveryPoint) }

    var body: some View {
        ManagerLayout(pages: Page.allCases, selection: $page, row: row) { page in
            switch page {
            case .workspaces:
                WorkspacesPage(manager: manager)
            case .backups:
                SnapshotSection(
                    manager: manager, title: "Before launch", items: backups,
                    empty: "No backups yet.",
                    footer: "At every launch a copy is kept of the windows that were open before, so they are never lost. The latest 10 are kept.")
                if let restored = manager.restoredAtLaunch {
                    Section {
                        Text("This launch restored the windows of \(SnapshotRow.time(restored.date)). Not what you expected? Open an earlier version from a workspace's menu, or a backup above.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            case .settings:
                SettingsPage(manager: manager)
            }
        } footer: {
            Circle()
                .fill(manager.failed ? Color.orange : Color.green.opacity(0.8))
                .frame(width: 7, height: 7)
            Text(manager.message)
                .font(.caption)
                .foregroundStyle(manager.failed ? Color.orange : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Save Now") { manager.checkpoint() }
                .help("Save the open windows in the current workspace, including recent scrollback")
        }
    }

    private func row(_ page: Page) -> ManagerLayoutRow {
        switch page {
        case .workspaces: .init(title: "Workspaces", symbol: "square.stack.3d.up", badge: "\(manager.workspaces.count)")
        case .backups: .init(title: "Backups", symbol: "lifepreserver", badge: backups.isEmpty ? nil : "\(backups.count)")
        case .settings: .init(title: "Settings", symbol: "gearshape")
        }
    }
}

/// The current workspace, then the others.
private struct WorkspacesPage: View {
    @ObservedObject var manager: SessionManager

    var body: some View {
        Section {
            CurrentWorkspace(manager: manager)
        } header: {
            Text("Open now")
        }

        SnapshotSection(
            manager: manager, title: "Other workspaces",
            items: manager.workspaces.filter { $0.id != manager.activeWorkspace },
            empty: "Workspaces you create appear here. Opening one saves and closes the open windows.",
            footer: "Each workspace saves itself while it is open.") {
            Button("New Workspace…") { manager.promptNewWorkspace(nil) }
                .buttonStyle(.link)
        }
    }
}

private struct CurrentWorkspace: View {
    @ObservedObject var manager: SessionManager
    @State private var expanded = false

    var body: some View {
        let summary = manager.current
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.activeName ?? "No workspace yet")
                        .font(.headline)
                    if let summary {
                        Text(SnapshotRow.counts(summary) + places(summary))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No terminal windows are open.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let saved = manager.lastSaved {
                    Text("Saved \(Text(saved, style: .relative)) ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Menu {
                    if let active = manager.activeSummary {
                        Button("Rename…") { manager.rename(active) }
                        VersionsMenu(manager: manager, workspace: active.id)
                    }
                    Button("Save as New Workspace…") { manager.promptSaveAsWorkspace(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let summary {
                DisclosureGroup(isExpanded: $expanded) {
                    LayoutPreview(summary: summary).padding(.top, 4)
                } label: {
                    Text("Layout").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 4)
    }

    private func places(_ summary: SessionSnapshot.Summary) -> String {
        let places = summary.places.prefix(3).joined(separator: ", ")
        return places.isEmpty ? "" : " · " + places
    }
}

/// Earlier versions of a workspace, opened next to the open windows.
private struct VersionsMenu: View {
    @ObservedObject var manager: SessionManager
    let workspace: UUID

    var body: some View {
        let versions = Array(manager.history(of: workspace).prefix(12))
        Menu("Open Earlier Version") {
            ForEach(versions) { version in
                Button(SnapshotRow.time(version.date) + " — " + SnapshotRow.counts(version)) {
                    manager.restore(version)
                }
            }
        }
        .disabled(versions.isEmpty)
    }
}

/// A list of stored snapshots with search and a selection mode for deleting several.
private struct SnapshotSection<Accessory: View>: View {
    @ObservedObject var manager: SessionManager
    let title: String
    let items: [SessionSnapshot.Summary]
    let empty: String
    let footer: String
    @ViewBuilder var accessory: () -> Accessory
    @State private var query = ""
    @State private var selecting = false
    @State private var selection = Set<UUID>()

    private var filtered: [SessionSnapshot.Summary] {
        items.filter { $0.matches(query) }.sorted { lhs, rhs in
            lhs.isWorkspace ? (lhs.name ?? "").localizedStandardCompare(rhs.name ?? "") == .orderedAscending
                : lhs.date > rhs.date
        }
    }

    private var allSelected: Bool { !filtered.isEmpty && filtered.allSatisfy { selection.contains($0.id) } }

    var body: some View {
        Section {
            if items.count > 6 {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query, prompt: Text("Search by name, folder or tmux session"))
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if selecting {
                HStack {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected { selection.removeAll() } else { selection = Set(filtered.map(\.id)) }
                    }
                    Text(selection.isEmpty ? "None selected" : "\(selection.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        manager.delete(selection)
                    }
                    .disabled(selection.isEmpty)
                }
            }
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else if filtered.isEmpty {
                Text("Nothing matches “\(query)”.").foregroundStyle(.secondary)
            }
            ForEach(filtered) { summary in
                SnapshotRow(manager: manager, summary: summary, selecting: selecting,
                            selected: Binding(get: { selection.contains(summary.id) },
                                              set: { if $0 { selection.insert(summary.id) } else { selection.remove(summary.id) } }))
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                accessory()
                if !items.isEmpty {
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        selection.removeAll()
                    }
                    .buttonStyle(.link)
                }
            }
        } footer: {
            Text(footer)
        }
        .onChange(of: items) { items in
            // Drop deleted items from the selection; leave selection mode when nothing is left.
            selection.formIntersection(items.map(\.id))
            if items.isEmpty { selecting = false }
        }
    }
}

extension SnapshotSection where Accessory == EmptyView {
    init(manager: SessionManager, title: String, items: [SessionSnapshot.Summary], empty: String, footer: String) {
        self.init(manager: manager, title: title, items: items, empty: empty, footer: footer) { EmptyView() }
    }
}

private struct SnapshotRow: View {
    @ObservedObject var manager: SessionManager
    let summary: SessionSnapshot.Summary
    let selecting: Bool
    @Binding var selected: Bool
    @State private var expanded = false

    private var title: String {
        if summary.isWorkspace, let name = summary.name { return name }
        let places = summary.places.prefix(3).joined(separator: ", ")
        return places.isEmpty ? "Session" : places
    }

    private var detail: String {
        var parts = [Self.counts(summary)]
        if summary.isWorkspace {
            let places = summary.places.prefix(3).joined(separator: ", ")
            if !places.isEmpty { parts.append(places) }
        }
        parts.append(Self.time(summary.date))
        return parts.joined(separator: " · ")
    }

    static func counts(_ summary: SessionSnapshot.Summary) -> String {
        var parts = ["\(summary.windows) window\(summary.windows == 1 ? "" : "s")"]
        if summary.tabs.count != summary.windows {
            parts.append("\(summary.tabs.count) tab\(summary.tabs.count == 1 ? "" : "s")")
        }
        parts.append("\(summary.panes) pane\(summary.panes == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    static func time(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if selecting {
                    Toggle("", isOn: $selected)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                } else {
                    Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide layout" : "Show layout")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer(minLength: 8)

                if !selecting {
                    Button(summary.isWorkspace ? "Open" : "Restore") { manager.open(summary) }
                        .help(summary.isWorkspace
                            ? "Save and close the open windows, and open this workspace"
                            : "Open these windows next to the current ones")
                    Menu {
                        if summary.isWorkspace {
                            Button("Add to Open Windows") { manager.restore(summary) }
                            VersionsMenu(manager: manager, workspace: summary.id)
                            Divider()
                            Button("Rename…") { manager.rename(summary) }
                        } else {
                            Button("Keep as Workspace…") { manager.rename(summary) }
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { manager.delete([summary.id]) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if !selecting { manager.open(summary) } }
            .onTapGesture { if selecting { selected.toggle() } }

            if expanded && !selecting {
                LayoutPreview(summary: summary)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Windows, tabs and panes of a snapshot, as a compact outline.
private struct LayoutPreview: View {
    let summary: SessionSnapshot.Summary

    var body: some View {
        let windows = Dictionary(grouping: summary.tabs.enumerated(), by: { $0.element.group })
        VStack(alignment: .leading, spacing: 6) {
            ForEach(windows.keys.sorted(), id: \.self) { group in
                VStack(alignment: .leading, spacing: 3) {
                    if summary.windows > 1 {
                        Label("Window \(group + 1)", systemImage: "macwindow")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(windows[group]!, id: \.offset) { _, tab in
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = tab.title, !title.isEmpty {
                                Text(title).font(.caption.weight(.medium))
                            }
                            ForEach(Array(tab.panes.enumerated()), id: \.offset) { _, pane in
                                PaneLine(pane: pane)
                            }
                        }
                        .padding(.leading, summary.windows > 1 ? 14 : 0)
                    }
                }
            }
        }
    }

    private struct PaneLine: View {
        let pane: SessionSnapshot.Summary.PaneInfo

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: pane.tmuxSession == nil ? "terminal" : "rectangle.split.3x1")
                    .foregroundStyle(pane.tmuxSession == nil ? Color.secondary : Color.green)
                    .frame(width: 14)
                Text(pane.location.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Unknown directory")
                    .foregroundStyle(pane.location == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let session = pane.tmuxSession {
                    Text(session).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
    }
}

private struct SettingsPage: View {
    @ObservedObject var manager: SessionManager

    var body: some View {
        Section {
            Toggle(isOn: $manager.restoreOnLaunch) {
                Text("Reopen the last workspace at launch")
                Text("Otherwise Ghostty starts with one new window in a new workspace.")
            }
            Toggle(isOn: $manager.saveOutput) {
                Text("Save terminal output")
                Text("Restored panes show their earlier output above the new shell.")
            }
        }

        Section {
            LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: Int64(manager.storageBytes), countStyle: .file))
            HStack {
                Button("Show in Finder") { manager.revealStorage() }
                Spacer()
                Button("Delete Earlier Versions", role: .destructive) { manager.deleteOlderCheckpoints() }
                    .disabled(manager.sessions.filter(\.isAutomatic).count < 2)
                    .help("Keeps every workspace and the newest version, which the next launch opens")
            }
        } footer: {
            Text("Windows, tabs, splits, directories, titles, tmux sessions and recent output are restored; programs in normal panes start as new shells. Stored privately for your macOS account.")
        }
    }
}

struct SessionRecoveryBar: View {
    @ObservedObject private var manager = SessionManager.shared

    var body: some View {
        HStack {
            Spacer()
            Text(manager.message)
                .foregroundColor(manager.failed ? .orange : .secondary)
                .lineLimit(1)
            Button(manager.activeName ?? "Sessions") { manager.showSessions() }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Open the Session Manager (⇧⌘S)")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}
