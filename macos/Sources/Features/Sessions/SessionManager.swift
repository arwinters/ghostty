import AppKit
import SwiftUI
import GhosttyKit

/// App-owned persistence is independent of external status-plugin processes.
///
/// Checkpoints are cheap by design. Every few seconds only the layout is compared
/// (windows, tabs, splits, directories, tmux state): no terminal text is read. A layout
/// change is saved at once, together with the *visible* screen of each pane. Without a
/// layout change, the visible screens are saved at most once a minute. The expensive read
/// of scrollback happens only when quitting, before sleep and when saving a workspace.
///
/// Earlier builds read the complete scrollback of every pane every five seconds (up to
/// `scrollback-limit` bytes each, 50 MB in the Status Lab defaults) and then decoded every
/// stored snapshot again after each save.
final class SessionManager: NSObject, ObservableObject {
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

    @Published var restoreOnLaunch: Bool {
        didSet { UserDefaults.standard.set(restoreOnLaunch, forKey: Self.restoreOnLaunchKey) }
    }
    @Published var saveOutput: Bool {
        didSet { UserDefaults.standard.set(saveOutput, forKey: Self.saveOutputKey) }
    }
    private static let restoreOnLaunchKey = "StatusLabSessionsRestoreOnLaunch"
    private static let saveOutputKey = "StatusLabSessionsSaveOutput"

    /// Seconds between layout comparisons, and between saves of only the visible output.
    static let tickInterval: TimeInterval = 5
    static let outputInterval: TimeInterval = 60

    private enum Depth {
        /// Structure only; for change detection and the live summary.
        case layout
        /// Plus the visible screen of each pane: cheap, for periodic checkpoints.
        case visible
        /// Plus recent scrollback: for quit, sleep and named workspaces.
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
    private var fontSizes: [UUID: (NSSize, Float)] = [:]
    private var launchSnapshot: SessionSnapshot.Summary?
    private var launchRestorationHandled = false
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

    private override init() {
        store = SessionStore(directory: PluginManager.supportDirectory.appendingPathComponent("sessions"))
        let defaults = UserDefaults.standard
        restoreOnLaunch = defaults.object(forKey: Self.restoreOnLaunchKey) as? Bool ?? true
        saveOutput = defaults.object(forKey: Self.saveOutputKey) as? Bool ?? true
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
        let item = NSMenuItem(title: "Session Manager…", action: #selector(showSessions), keyEquivalent: "S")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        menu.addItem(item)
        let save = NSMenuItem(title: "Save Workspace…", action: #selector(promptSaveWorkspace(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
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
        guard restoreOnLaunch, let summary = launchSnapshot else { return false }
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
            guard restore(snapshot, atLaunch: true) else { return false }
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

    /// Saves a complete checkpoint now, including recent scrollback. With a name, it is
    /// kept as a workspace until deleted.
    func checkpoint(name: String? = nil) {
        guard enabled, !restoring, started, !terminating else { return }
        // Before quit or sleep the status bar polling may be paused; ask tmux once.
        TmuxPlugin.shared.refreshPaths(synchronously: true)
        save(depth: .full, name: name)
    }

    private func tick() {
        guard enabled, !restoring, started, !terminating else { return }
        let windows = capture(.layout)
        let summary = windows.isEmpty ? nil : SessionSnapshot(windows: windows).summary
        // Each capture is a new snapshot: compare content, or the status bar redraws every tick.
        let unchanged = summary.map { $0.hasSameContent(as: current) } ?? (current == nil)
        if !unchanged { current = summary }
        guard !windows.isEmpty, let layout = try? Self.encode(windows) else { return }
        if layout != lastLayout {
            save(depth: .visible, name: nil, layout: layout)
        } else if saveOutput, Date().timeIntervalSince(lastWrite) >= Self.outputInterval {
            save(depth: .visible, name: nil, layout: layout)
        }
    }

    private func save(depth: Depth, name: String?, layout: Data? = nil) {
        do {
            let windows = capture(depth)
            // Closing windows, failed startup, or a transient empty UI must never erase the last session.
            guard !windows.isEmpty else { return }
            let content = try Self.encode(windows)
            lastLayout = try layout ?? Self.encode(capture(.layout))
            guard content != lastContent || name != nil else { return }
            let snapshot = SessionSnapshot(name: name, windows: windows)
            try store.save(snapshot)
            lastContent = content
            lastWrite = Date()
            lastSaved = snapshot.date
            failed = false
            reload()
            message = name.map { "Saved workspace “\($0)”" }
                ?? "Saved \(snapshot.date.formatted(date: .omitted, time: .standard))"
        } catch { report(error) }
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
        }.filter { seen.insert(ObjectIdentifier($0)).inserted }
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

    // MARK: Restoring

    /// Opens a stored snapshot next to the open windows.
    func restore(_ summary: SessionSnapshot.Summary) {
        do {
            let snapshot = try store.load(summary.id)
            restore(snapshot, atLaunch: false)
        } catch {
            reload()
            report(error)
        }
    }

    /// At launch everything is restored. Later, tmux sessions that are already shown in a
    /// pane are skipped: a second client would mirror the same session in two places.
    @discardableResult private func restore(_ snapshot: SessionSnapshot, atLaunch: Bool) -> Bool {
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
            let skip: Set<String> = atLaunch ? [] : TmuxPlugin.shared.shownSessions
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
        for view in controller.surfaceTree {
            fontSizes.removeValue(forKey: view.id)
            TmuxPlugin.shared.forget(view.id)
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

    /// Asks for a name and saves the open windows as a workspace.
    @objc func promptSaveWorkspace(_ sender: Any?) {
        let suggestion = current?.places.prefix(3).joined(separator: ", ") ?? ""
        guard let name = Self.askName(title: "Save Workspace",
                                      message: "Saves every open window, tab and pane. Workspaces are kept until you delete them.",
                                      value: suggestion, button: "Save") else { return }
        saveWorkspace(name)
    }

    func saveWorkspace(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        checkpoint(name: trimmed.isEmpty ? "Workspace" : String(trimmed.prefix(80)))
    }

    /// Removes a stored snapshot.
    func delete(_ summary: SessionSnapshot.Summary) {
        do {
            try store.delete(summary.id)
            reload()
            message = "Deleted “\(summary.name ?? "checkpoint")”"
        } catch { report(error) }
    }

    /// Deletes every automatic checkpoint except the newest, which the next launch restores.
    func deleteOlderCheckpoints() {
        do {
            for old in sessions.filter(\.isAutomatic).dropFirst() { try store.delete(old.id) }
            reload()
            message = "Deleted older automatic checkpoints"
        } catch { report(error) }
    }

    /// Renames a workspace, or keeps a checkpoint or recovery point as a named workspace.
    func rename(_ summary: SessionSnapshot.Summary) {
        let keep = !summary.isWorkspace
        guard let name = Self.askName(title: keep ? "Keep as Workspace" : "Rename Workspace",
                                      message: keep ? "Named workspaces are kept until you delete them." : "",
                                      value: keep ? summary.places.prefix(3).joined(separator: ", ") : summary.name ?? "",
                                      button: keep ? "Keep" : "Rename") else { return }
        do {
            var snapshot = try store.load(summary.id)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.name = trimmed.isEmpty ? "Workspace" : String(trimmed.prefix(80))
            // A kept checkpoint becomes a copy; the rotation keeps working on the original.
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
    @State private var page: Page = .overview
    @State private var query = ""

    enum Page: String, CaseIterable, Identifiable {
        case overview, workspaces, recent, recovery, settings
        var id: String { rawValue }
    }

    private var workspaces: [SessionSnapshot.Summary] { manager.sessions.filter(\.isWorkspace) }
    private var checkpoints: [SessionSnapshot.Summary] { manager.sessions.filter(\.isAutomatic) }
    private var recovery: [SessionSnapshot.Summary] { manager.sessions.filter(\.isRecoveryPoint) }

    var body: some View {
        ManagerLayout(pages: Page.allCases, selection: $page, row: row) { page in
            switch page {
            case .overview:
                OverviewPage(manager: manager, open: { self.page = $0 })
            case .workspaces:
                SnapshotList(manager: manager, snapshots: workspaces, query: $query,
                             empty: "No saved workspaces yet. Save the open windows from the overview, the Sessions menu or a pane's right-click menu.",
                             footer: "Named workspaces are kept until you delete them.")
            case .recent:
                SnapshotList(manager: manager, snapshots: checkpoints, query: $query,
                             empty: "No automatic checkpoints yet.",
                             footer: "Saved when the layout changes and at most once a minute for screen output; complete scrollback when quitting and before sleep. The latest 20 are kept; the newest one opens at the next launch.")
            case .recovery:
                SnapshotList(manager: manager, snapshots: recovery, query: $query,
                             empty: "No recovery points yet.",
                             footer: "Each launch keeps a copy of the session it restored, so it is never lost when the windows change. The latest 10 are kept.")
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
            Button("Save Checkpoint Now") { manager.checkpoint() }
                .help("Save the open windows, including recent scrollback, as an automatic checkpoint")
        }
        .onChange(of: page) { _ in query = "" }
    }

    private func row(_ page: Page) -> ManagerLayoutRow {
        switch page {
        case .overview: .init(title: "Overview", symbol: "rectangle.3.group")
        case .workspaces: .init(title: "Workspaces", symbol: "square.stack.3d.up", badge: "\(workspaces.count)")
        case .recent: .init(title: "Recent", symbol: "clock.arrow.circlepath", badge: "\(checkpoints.count)")
        case .recovery: .init(title: "Before Launch", symbol: "lifepreserver", badge: "\(recovery.count)")
        case .settings: .init(title: "Settings", symbol: "gearshape")
        }
    }
}

/// What is open now, what was restored, and the quickest actions.
private struct OverviewPage: View {
    @ObservedObject var manager: SessionManager
    let open: (SessionManagerView.Page) -> Void
    @State private var name = ""

    var body: some View {
        Section {
            if let current = manager.current {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        Stat(value: current.windows, label: "window", symbol: "macwindow")
                        Stat(value: current.tabs.count, label: "tab", symbol: "rectangle.topthird.inset.filled")
                        Stat(value: current.panes, label: "pane", symbol: "rectangle.split.2x1")
                        if current.tmuxPanes > 0 {
                            Stat(value: current.tmuxPanes, label: "tmux pane", symbol: "rectangle.split.3x1")
                        }
                    }
                    Chips(summary: current)
                    LayoutPreview(summary: current)
                }
                .padding(.vertical, 4)
            } else {
                Text("No terminal windows are open.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Open now")
                Spacer()
                if let saved = manager.lastSaved {
                    Text("Last saved \(Text(saved, style: .relative)) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            HStack {
                TextField("Workspace name", text: $name, prompt: Text(manager.current?.places.prefix(3).joined(separator: ", ") ?? "Client project"))
                    .onSubmit(save)
                Button("Save Workspace", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(manager.current == nil)
            }
        } header: {
            Text("Save as workspace")
        } footer: {
            Text("A workspace keeps windows, tabs, splits, directories, tmux sessions and recent output until you delete it.")
        }

        if let restored = manager.restoredAtLaunch {
            Section {
                SnapshotRow(manager: manager, summary: restored, compact: true)
            } header: {
                Text("Restored at this launch")
            } footer: {
                Text("Not the session you expected? Earlier checkpoints are under Recent; the windows that were open before this launch are under Before Launch.")
            }
        }

        Section("Recent") {
            let recent = Array(manager.sessions.filter(\.isAutomatic).prefix(3))
            if recent.isEmpty { Text("No automatic checkpoints yet.").foregroundStyle(.secondary) }
            ForEach(recent) { SnapshotRow(manager: manager, summary: $0, compact: true) }
            if manager.sessions.filter(\.isAutomatic).count > 3 {
                Button("Show all checkpoints") { open(.recent) }
                    .buttonStyle(.link)
            }
        }
    }

    private func save() {
        let fallback = manager.current?.places.prefix(3).joined(separator: ", ") ?? ""
        manager.saveWorkspace(name.isEmpty ? fallback : name)
        name = ""
        open(.workspaces)
    }

    private struct Stat: View {
        let value: Int
        let label: String
        let symbol: String

        var body: some View {
            Label {
                Text("\(value) \(label)\(value == 1 ? "" : "s")").monospacedDigit()
            } icon: {
                Image(systemName: symbol).foregroundStyle(.tint)
            }
        }
    }
}

/// A searchable list of stored snapshots, grouped by day.
private struct SnapshotList: View {
    @ObservedObject var manager: SessionManager
    let snapshots: [SessionSnapshot.Summary]
    @Binding var query: String
    let empty: String
    let footer: String

    private var filtered: [SessionSnapshot.Summary] { snapshots.filter { $0.matches(query) } }

    private var days: [(Date, [SessionSnapshot.Summary])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }

    var body: some View {
        if !snapshots.isEmpty {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query, prompt: Text("Search by folder, title, tmux session or name"))
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if snapshots.isEmpty {
            Section {
                Text(empty).foregroundStyle(.secondary)
            } footer: {
                Text(footer)
            }
        } else if filtered.isEmpty {
            Section {
                Text("Nothing matches “\(query)”.").foregroundStyle(.secondary)
            }
        }
        ForEach(Array(days.enumerated()), id: \.element.0) { index, day in
            Section {
                ForEach(day.1) { SnapshotRow(manager: manager, summary: $0, compact: false) }
            } header: {
                Text(Self.dayTitle(day.0))
            } footer: {
                if index == days.count - 1 { Text(footer) }
            }
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

private struct SnapshotRow: View {
    @ObservedObject var manager: SessionManager
    let summary: SessionSnapshot.Summary
    let compact: Bool
    @State private var expanded = false

    private var symbol: String {
        summary.isWorkspace ? "square.stack.3d.up.fill" : summary.isRecoveryPoint ? "lifepreserver" : "clock"
    }

    private var title: String {
        if summary.isWorkspace, let name = summary.name { return name }
        let places = summary.places.prefix(3).joined(separator: ", ")
        return places.isEmpty ? "Session" : places
    }

    private var detail: String {
        var parts = [Self.time(summary.date)]
        parts.append("\(summary.windows) window\(summary.windows == 1 ? "" : "s")")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide layout" : "Show layout")

                Image(systemName: symbol)
                    .foregroundStyle(summary.isWorkspace ? Color.accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !compact { Chips(summary: summary) }
                }

                Spacer(minLength: 8)

                Button("Restore") { manager.restore(summary) }
                    .help("Open these windows next to the current ones. tmux sessions that are already open are not opened twice.")
                Menu {
                    Button(summary.isWorkspace ? "Rename…" : "Keep as Workspace…") { manager.rename(summary) }
                    Divider()
                    Button("Delete", role: .destructive) { manager.delete(summary) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { manager.restore(summary) }

            if expanded {
                LayoutPreview(summary: summary)
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Folder names and tmux profiles, as small capsules.
private struct Chips: View {
    let summary: SessionSnapshot.Summary

    var body: some View {
        let places = Array(summary.places.prefix(4))
        let more = summary.places.count - places.count
        HStack(spacing: 5) {
            ForEach(places, id: \.self) { chip($0, symbol: "folder", tint: .blue) }
            if more > 0 { chip("+\(more)", symbol: nil, tint: .gray) }
            ForEach(summary.profiles, id: \.self) { chip($0, symbol: "rectangle.split.3x1", tint: .green) }
        }
    }

    private func chip(_ text: String, symbol: String?, tint: Color) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
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
                Text("Restore the last session at launch")
                Text("Otherwise Ghostty starts with one new window. Checkpoints are still saved.")
            }
            Toggle(isOn: $manager.saveOutput) {
                Text("Save terminal output")
                Text("Restored panes show their earlier output above the new shell. Off saves only the layout and directories.")
            }
        } header: {
            Text("Behavior")
        }

        Section {
            LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: Int64(manager.storageBytes), countStyle: .file))
            HStack {
                Button("Show in Finder") { manager.revealStorage() }
                Spacer()
                Button("Delete Older Checkpoints", role: .destructive) { manager.deleteOlderCheckpoints() }
                    .disabled(manager.sessions.filter(\.isAutomatic).count < 2)
                    .help("Keeps the newest checkpoint, which the next launch restores, and every workspace")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Stored privately for your macOS account (folder 0700, files 0600). Saved output is plain text and is shown, never executed.")
        }

        Section("What is restored") {
            Label("Windows, tabs and their order, sizes and fullscreen", systemImage: "macwindow.on.rectangle")
            Label("Splits, ratios, focused and zoomed pane", systemImage: "rectangle.split.2x1")
            Label("Working directory, titles, tab colors and font size", systemImage: "folder")
            Label("Recent output per pane, as plain text", systemImage: "text.alignleft")
            Label("tmux panes: reattached after a crash; after a restart recreated in their last directory, with the profile's resume command only while that program was still running", systemImage: "rectangle.split.3x1")
        }
        Section("What is not restored") {
            Label("Running programs in normal panes; they start as new shells", systemImage: "xmark.circle")
            Label("Colors and full-screen program state in saved output", systemImage: "xmark.circle")
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
            Button("Sessions") { manager.showSessions() }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Open the Session Manager (⇧⌘S)")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}
