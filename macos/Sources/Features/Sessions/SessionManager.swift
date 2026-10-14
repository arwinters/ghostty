import AppKit
import SwiftUI
import GhosttyKit

/// App-owned persistence is independent of external status-plugin processes.
final class SessionManager: NSObject, ObservableObject {
    static let shared = SessionManager()
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var message = "Waiting for first checkpoint"
    private var timer: Timer?
    private var panel: NSWindow?
    private var restoring = false
    private var started = false
    private var lastContent: Data?
    private var retainedControllers: [TerminalController] = []
    private var fontSizes: [UUID: (NSSize, Float)] = [:]
    private var launchSnapshot: SessionSnapshot?
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

    var ownsLaunchRestoration: Bool { enabled && (launchSnapshot != nil || launchRestorationHandled) }

    private override init() {
        store = SessionStore(directory: PluginManager.supportDirectory.appendingPathComponent("sessions"))
        super.init()
        do {
            sessions = try store.list()
            launchSnapshot = sessions.first(where: { $0.name == nil })
        } catch { message = "Session storage could not be read: \(error.localizedDescription)" }
    }

    func start() {
        guard enabled, !started else { return }
        started = true
        let menu = NSMenu(title: "Sessions")
        let item = NSMenuItem(title: "Session Manager…", action: #selector(showSessions), keyEquivalent: "S")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        menu.addItem(item)
        let root = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        root.submenu = menu
        NSApp.mainMenu?.insertBeforeHelp(root)
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkpoint() }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkpointBeforeSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
    }

    @objc private func checkpointBeforeSleep() { checkpoint() }

    @discardableResult func restoreAtLaunch() -> Bool {
        guard ownsLaunchRestoration, let snapshot = launchSnapshot else { return false }
        launchRestorationHandled = true
        launchSnapshot = nil
        // Preserve the previous launch independently of the rolling autosave queue.
        var recovery = snapshot
        recovery.id = UUID()
        recovery.name = SessionSnapshot.recoveryPrefix + Date().formatted(date: .numeric, time: .shortened)
        do { try store.save(recovery) } catch { report(error); return false }
        return restore(snapshot)
    }

    /// Freeze persistence; the checkpoint from applicationShouldTerminate is final.
    func prepareForTermination() {
        terminating = true
        timer?.invalidate()
    }

    func checkpoint(name: String? = nil) {
        guard enabled, !restoring, started, !terminating else { return }
        do {
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
                    tree: capture(root)))
            }
            // Closing windows, failed startup, or a transient empty UI must never erase the last session.
            guard !windows.isEmpty else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let content = try encoder.encode(windows)
            guard content != lastContent || name != nil else { return }
            let snapshot = SessionSnapshot(name: name, windows: windows)
            try store.save(snapshot)
            lastContent = content
            sessions = try store.list()
            message = "Saved \(snapshot.date.formatted(date: .omitted, time: .standard))"
        } catch { report(error) }
    }

    private func capture(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> SessionSnapshot.Node {
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
            let tmux = TmuxPlugin.shared.pane(for: view.id)
            return .pane(.init(id: view.id, directory: view.pwd, title: view.title,
                               customTitle: view.sessionHasCustomTitle, fontSize: size,
                               transcript: tmux == nil ? SessionSnapshot.safeTranscript(view.cachedScreenContents.get()) : "",
                               tmux: tmux))
        case .split(let split):
            return .split(horizontal: split.direction == .horizontal, ratio: split.ratio,
                          left: capture(split.left), right: capture(split.right))
        }
    }

    @discardableResult func restore(_ snapshot: SessionSnapshot) -> Bool {
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
                let text = SessionSnapshot.safeTranscript(pane.transcript) + "\n— Restored session · new shell —\n"
                try text.write(to: replay.appendingPathComponent(pane.id.uuidString), atomically: true, encoding: .utf8)
            }
            var groups: [Int: NSWindow] = [:]
            var selected: [NSWindow] = []
            var key: NSWindow?
            for saved in snapshot.windows {
                var views: [UUID: Ghostty.SurfaceView] = [:]
                let root = makeTree(saved.tree, app: handle, replay: replay, views: &views)
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
            sessions = try store.list()
            message = "Restored \(snapshot.paneCount) panes; new shells with saved output"
            // Replay files are read by newly starting shells. Keep them until the next launch.
            return true
        } catch { report(error); return false }
    }

    private func makeTree(_ node: SessionSnapshot.Node, app: ghostty_app_t, replay: URL,
                          views: inout [UUID: Ghostty.SurfaceView]) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch node {
        case .pane(let pane):
            if let tmux = pane.tmux {
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
            return .split(.init(direction: horizontal ? .horizontal : .vertical, ratio: ratio,
                                left: makeTree(left, app: app, replay: replay, views: &views),
                                right: makeTree(right, app: app, replay: replay, views: &views)))
        }
    }

    func closed(_ controller: TerminalController) {
        retainedControllers.removeAll { $0 === controller }
        for view in controller.surfaceTree {
            fontSizes.removeValue(forKey: view.id)
            TmuxPlugin.shared.forget(view.id)
        }
    }

    @objc func showSessions() {
        if panel == nil {
            panel = ManagerWindow.make(title: "Session Manager", autosave: "StatusLabSessionManager",
                                       rootView: SessionManagerView(manager: self))
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Removes a saved workspace or recovery point. Automatic checkpoints rotate by themselves.
    func delete(_ snapshot: SessionSnapshot) {
        do {
            try store.delete(snapshot.id)
            sessions = try store.list()
            message = "Deleted “\(snapshot.name ?? "checkpoint")”"
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        message = "Session recovery error: \(error.localizedDescription)"
        AppDelegate.logger.error("\(self.message, privacy: .public)")
    }
}

private struct SessionManagerView: View {
    @ObservedObject var manager: SessionManager
    @State private var page: Page = .workspaces
    @State private var name = ""

    enum Page: String, CaseIterable, Identifiable {
        case workspaces, checkpoints, recovery, about
        var id: String { rawValue }
    }

    private var workspaces: [SessionSnapshot] { manager.sessions.filter { $0.name != nil && !$0.isRecoveryPoint } }
    private var checkpoints: [SessionSnapshot] { manager.sessions.filter { $0.name == nil } }
    private var recovery: [SessionSnapshot] { manager.sessions.filter(\.isRecoveryPoint) }

    var body: some View {
        ManagerLayout(pages: Page.allCases, selection: $page, row: row) { page in
            switch page {
            case .workspaces:
                Section {
                    HStack {
                        TextField("Workspace name", text: $name, prompt: Text("For example: Client project"))
                            .onSubmit(save)
                        Button("Save Current Windows", action: save)
                    }
                } header: {
                    Text("Save workspace")
                } footer: {
                    Text("Named workspaces are kept until you delete them.")
                }
                list(workspaces, empty: "No saved workspaces yet.", deletable: true)
            case .checkpoints:
                list(checkpoints, empty: "No automatic checkpoints yet.", deletable: false,
                     footer: "Saved every 5 seconds while something changed, before sleep and when quitting. The latest 20 are kept.")
            case .recovery:
                list(recovery, empty: "No recovery points yet.", deletable: true,
                     footer: "When Ghostty starts and restores your last session, the session it replaced is kept here first.")
            case .about:
                AboutSessions()
            }
        } footer: {
            Circle()
                .fill(manager.message.hasPrefix("Session recovery error") ? Color.orange : Color.green.opacity(0.8))
                .frame(width: 7, height: 7)
            Text(manager.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Save Now") { manager.checkpoint(name: nil) }
                .help("Write an automatic checkpoint immediately")
        }
    }

    private func row(_ page: Page) -> ManagerLayoutRow {
        switch page {
        case .workspaces: .init(title: "Workspaces", symbol: "square.stack.3d.up", badge: "\(workspaces.count)")
        case .checkpoints: .init(title: "Automatic", symbol: "clock.arrow.circlepath", badge: "\(checkpoints.count)")
        case .recovery: .init(title: "Before Launch", symbol: "lifepreserver", badge: "\(recovery.count)")
        case .about: .init(title: "How It Works", symbol: "info.circle")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        manager.checkpoint(name: trimmed.isEmpty ? "Saved workspace" : trimmed)
        name = ""
    }

    @ViewBuilder
    private func list(_ snapshots: [SessionSnapshot], empty: String, deletable: Bool, footer: String? = nil) -> some View {
        Section {
            if snapshots.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            }
            ForEach(snapshots) { snapshot in
                SnapshotRow(snapshot: snapshot, deletable: deletable,
                            restore: { manager.restore(snapshot) },
                            delete: { manager.delete(snapshot) })
            }
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private struct SnapshotRow: View {
        let snapshot: SessionSnapshot
        let deletable: Bool
        let restore: () -> Void
        let delete: () -> Void

        private var detail: String {
            let windows = Set(snapshot.windows.map(\.group)).count
            let tmux = snapshot.windows.flatMap { $0.tree.panes }.filter { $0.tmux != nil }.count
            var parts = ["\(windows) window\(windows == 1 ? "" : "s")",
                         "\(snapshot.windows.count) tab\(snapshot.windows.count == 1 ? "" : "s")",
                         "\(snapshot.paneCount) pane\(snapshot.paneCount == 1 ? "" : "s")"]
            if tmux > 0 { parts.append("\(tmux) tmux") }
            return parts.joined(separator: " · ")
        }

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name ?? snapshot.date.formatted(date: .abbreviated, time: .standard))
                        .fontWeight(.medium)
                    Text((snapshot.name == nil ? "" : snapshot.date.formatted(date: .abbreviated, time: .shortened) + " · ") + detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if deletable {
                    Button("Delete", role: .destructive, action: delete)
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                }
                Button("Restore", action: restore)
            }
            .padding(.vertical, 2)
        }
    }

    private struct AboutSessions: View {
        var body: some View {
            Section("What is restored") {
                Label("Windows, tabs and their order, sizes and fullscreen", systemImage: "macwindow.on.rectangle")
                Label("Splits, ratios, focused and zoomed pane", systemImage: "rectangle.split.2x1")
                Label("Working directory, titles, tab colors and font size", systemImage: "folder")
                Label("The last 128K characters of output per pane, as plain text", systemImage: "text.alignleft")
                Label("tmux panes: reattached after a crash, recreated after a restart", systemImage: "terminal")
            }
            Section("What is not restored") {
                Label("Running programs in normal panes; they start as new shells", systemImage: "xmark.circle")
                Label("Colors and full-screen program state in saved output", systemImage: "xmark.circle")
            }
        }
    }
}

struct SessionRecoveryBar: View {
    @ObservedObject private var manager = SessionManager.shared

    var body: some View {
        HStack {
            Spacer()
            Text(manager.message)
                .foregroundColor(manager.message.hasPrefix("Session recovery error") ? .orange : .secondary)
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
