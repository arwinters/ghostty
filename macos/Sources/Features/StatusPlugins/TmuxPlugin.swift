import AppKit
import GhosttyKit

/// Opens tmux sessions in Ghostty panes from a profile (for example a Claude Code session)
/// and remembers which pane belongs to which session, so the Session Manager can restore it.
///
/// tmux runs its server outside Ghostty. After an app crash the session, including the
/// program inside it, is still running and a restored pane simply reattaches. After a
/// restart or shutdown the session is gone; the pane then recreates it with the profile's
/// resume command (for Claude: `claude --continue`).
final class TmuxPlugin: ObservableObject {
    static let shared = TmuxPlugin()

    enum Placement: CaseIterable {
        case tab, splitRight, splitDown

        var title: String {
            switch self {
            case .tab: "Open in New Tab"
            case .splitRight: "Open in Split Right"
            case .splitDown: "Open in Split Down"
            }
        }

        var shortTitle: String {
            switch self {
            case .splitRight: "Split Right"
            case .splitDown: "Split Down"
            case .tab: "New Tab"
            }
        }

        var symbol: String {
            switch self {
            case .splitRight: "rectangle.righthalf.inset.filled"
            case .splitDown: "rectangle.bottomhalf.inset.filled"
            case .tab: "plus.rectangle.on.rectangle"
            }
        }
    }

    struct RunningSession: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let attached: Bool
        let windows: Int
        let created: Date
    }

    @Published private(set) var running: [RunningSession] = []
    @Published private(set) var lastError: String?
    /// Working directory of each session's active pane, as tracked by tmux. tmux does not
    /// forward the shell's directory reports, so tab titles and the status bar use this.
    @Published private(set) var paths: [String: String] = [:]

    private var panes: [UUID: TmuxPane] = [:] {
        didSet { updatePathPolling() }
    }
    /// The program in each session's active pane (`pane_current_command`), so a checkpoint
    /// knows whether the profile's program (for example Claude) still runs there.
    private var commands: [String: String] = [:]
    private var pathTimer: Timer?

    // MARK: Executables

    /// tmux is usually installed with Homebrew, which is not on the app's PATH.
    var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var shell: String {
        getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
    }

    // MARK: Pane registry

    func pane(for id: UUID) -> TmuxPane? { panes[id] }

    /// tmux sessions shown in a pane of this app.
    var shownSessions: Set<String> { Set(panes.values.map(\.session)) }

    /// The directory to show for a surface that is a tmux pane.
    func path(for id: UUID) -> String? { panes[id].flatMap { paths[$0.session] ?? $0.directory } }

    /// The pane as it should be saved now: in the directory tmux reports, and resuming a
    /// plain shell once the profile's program has exited. Without this, a pane where Claude
    /// was closed hours ago would start `claude --continue` again in its first directory
    /// after a restart.
    func snapshotPane(for id: UUID) -> TmuxPane? {
        guard var pane = panes[id] else { return nil }
        if let path = paths[pane.session] { pane.directory = path }
        if let command = commands[pane.session], Self.isShell(command) {
            pane.resumeCommand = shell + " -l"
        }
        return pane
    }

    /// Whether tmux reports a shell (not a program started from it) as the pane's command.
    static func isShell(_ command: String) -> Bool {
        let name = (command.hasPrefix("-") ? String(command.dropFirst()) : command) as NSString
        return ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "login"]
            .contains(name.lastPathComponent)
    }

    /// tmux is asked every few seconds only while Ghostty is the active app: the status bar
    /// is the only live consumer. Checkpoints taken in the background (sleep, quit) refresh
    /// synchronously first.
    private func updatePathPolling() {
        if panes.isEmpty {
            pathTimer?.invalidate()
            pathTimer = nil
        } else if pathTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                guard NSApp.isActive else { return }
                self?.refreshPaths()
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            pathTimer = timer
            refreshPaths()
        }
    }

    /// Updates directories and running programs. `synchronously` blocks for at most a second.
    func refreshPaths(synchronously: Bool = false) {
        guard let tmux = tmuxPath, !panes.isEmpty else { return }
        let work = {
            // One call for every session: the active pane of each session's active window.
            let output = Self.run(tmux, ["list-panes", "-a", "-F",
                                         "#{session_name}\t#{window_active}\t#{pane_active}\t#{pane_current_command}\t#{pane_current_path}"])
            var paths: [String: String] = [:]
            var commands: [String: String] = [:]
            for line in (output ?? "").split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 5, fields[1] == "1", fields[2] == "1" else { continue }
                commands[fields[0]] = fields[3]
                if fields[4].hasPrefix("/") { paths[fields[0]] = fields[4] }
            }
            return (failed: output == nil, paths: paths, commands: commands)
        }
        let apply: ((failed: Bool, paths: [String: String], commands: [String: String])) -> Void = { result in
            // No answer (no server, or a wedged one): keep what was last known.
            guard !result.failed else { return }
            self.commands = result.commands
            if result.paths != self.paths { self.paths = result.paths }
        }
        if synchronously {
            apply(work())
        } else {
            DispatchQueue.global(qos: .utility).async {
                let result = work()
                DispatchQueue.main.async { apply(result) }
            }
        }
    }

    func forget(_ id: UUID) { panes.removeValue(forKey: id) }

    private func configuration(_ pane: TmuxPane, command: String, fontSize: Float? = nil) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = pane.directory
        config.fontSize = fontSize
        config.command = TmuxCommand.surfaceCommand(
            tmux: tmuxPath ?? "tmux", shell: shell, session: pane.session,
            directory: pane.directory, command: command,
            hideStatus: PluginManager.shared.settings.tmux.hideStatusBar)
        return config
    }

    // MARK: Opening

    func open(_ profile: TmuxProfile, placement: Placement, from source: Ghostty.SurfaceView? = nil) {
        guard tmuxPath != nil else {
            let alert = NSAlert()
            alert.messageText = "tmux is not installed"
            alert.informativeText = "Install tmux, for example with `brew install tmux`, and try again."
            alert.runModal()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directory = TmuxCommand.expand(directory: profile.directory, home: home)
        if profile.askForDirectory {
            // Start where the user is working: the clicked or focused pane's directory.
            let focused = ((NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface)?.pwd
            let start = [source?.pwd, focused, directory].compactMap { $0 }.first { $0.hasPrefix("/") }
            guard let chosen = chooseDirectory(for: profile, startingAt: start ?? home) else { return }
            directory = chosen
        }
        let pane = TmuxPane(
            session: TmuxCommand.newSessionName(profile: profile.id),
            profile: profile.id,
            directory: directory,
            resumeCommand: profile.effectiveResumeCommand)
        place(configuration(pane, command: profile.command), pane: pane, placement: placement, from: source)
        refreshSessions()
    }

    private func chooseDirectory(for profile: TmuxProfile, startingAt start: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true)
        panel.title = "Start \(profile.name)"
        panel.message = "Choose the directory where “\(profile.name)” (\(profile.command)) starts."
        panel.prompt = "Start Here"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// The surface configuration that (re)attaches to a saved tmux pane.
    func surfaceConfiguration(for pane: TmuxPane, fontSize: Float? = nil) -> Ghostty.SurfaceConfiguration {
        configuration(pane, command: pane.resumeCommand, fontSize: fontSize)
    }

    func register(_ view: Ghostty.SurfaceView, as pane: TmuxPane) { panes[view.id] = pane }

    /// Creates the surface next to `source` (the right-clicked pane) or the focused pane.
    private func place(_ config: Ghostty.SurfaceConfiguration, pane: TmuxPane,
                       placement: Placement, from source: Ghostty.SurfaceView?) {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        let sourceController = source?.window?.windowController as? TerminalController
        let controller = sourceController ??
            (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? TerminalController
        var view: Ghostty.SurfaceView?
        switch placement {
        case .tab:
            let created = TerminalController.newTab(app, from: controller?.window, withBaseConfig: config)
            view = created?.surfaceTree.root?.leaves().first
        case .splitRight, .splitDown:
            if let controller, let anchor = source ?? controller.focusedSurface {
                view = controller.newSplit(at: anchor, direction: placement == .splitRight ? .right : .down,
                                           baseConfig: config)
            } else {
                view = TerminalController.newWindow(app, withBaseConfig: config).surfaceTree.root?.leaves().first
            }
        }
        if let view { panes[view.id] = pane }
    }

    /// A surface for a saved tmux pane; registered so the next checkpoint keeps it a tmux pane.
    func restoreView(_ pane: TmuxPane, app: ghostty_app_t, fontSize: Float) -> Ghostty.SurfaceView {
        let view = Ghostty.SurfaceView(app, baseConfig: configuration(pane, command: pane.resumeCommand, fontSize: fontSize))
        panes[view.id] = pane
        return view
    }

    /// Reattach a running session, by default in a new tab.
    func attach(_ name: String, placement: Placement = .tab, from source: Ghostty.SurfaceView? = nil) {
        guard TmuxCommand.isValidSessionName(name) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Session names start with the profile id, so a restart can still resume it.
        let profile = PluginManager.shared.settings.tmux.profiles.first {
            name.hasPrefix(TmuxCommand.sessionPrefix + $0.id.lowercased() + "-")
        }
        let pane = TmuxPane(
            session: name, profile: profile?.id ?? "attached",
            directory: profile.map { TmuxCommand.expand(directory: $0.directory, home: home) } ?? home,
            resumeCommand: profile?.effectiveResumeCommand ?? shell + " -l")
        place(configuration(pane, command: pane.resumeCommand), pane: pane, placement: placement, from: source)
        refreshSessions()
    }

    // MARK: Running sessions

    func refreshSessions() {
        DispatchQueue.global(qos: .userInitiated).async {
            let sessions = self.listSessions(statusLabOnly: true)
            DispatchQueue.main.async { self.running = sessions }
        }
    }

    /// Lists tmux sessions directly; fast enough to call while a menu opens.
    func listSessions(statusLabOnly: Bool) -> [RunningSession] {
        guard let tmux = tmuxPath else { return [] }
        let output = Self.run(tmux, ["list-sessions", "-F",
                                     "#{session_name}\t#{session_attached}\t#{session_windows}\t#{session_created}"])
        return (output ?? "").split(separator: "\n").compactMap { line -> RunningSession? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4,
                  !statusLabOnly || fields[0].hasPrefix(TmuxCommand.sessionPrefix) else { return nil }
            return RunningSession(name: fields[0], attached: (Int(fields[1]) ?? 0) > 0,
                                  windows: Int(fields[2]) ?? 1,
                                  created: Date(timeIntervalSince1970: Double(fields[3]) ?? 0))
        }
        .sorted { $0.created > $1.created }
    }

    // MARK: Pane context menu

    /// The "tmux" submenu for a terminal pane's context menu: the configured profiles and
    /// the detached sessions, each to open next to the clicked pane.
    func contextMenuItem(for view: Ghostty.SurfaceView) -> NSMenuItem? {
        guard PluginManager.enabled, PluginManager.shared.settings.tmux.enabled else { return nil }
        let menu = NSMenu(title: "tmux")
        menu.autoenablesItems = false

        func header(_ title: String) {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }

        func placements(for choice: (Placement) -> ContextChoice) -> NSMenu {
            let submenu = NSMenu()
            for placement in [Placement.splitRight, .splitDown, .tab] {
                let item = submenu.addItem(withTitle: placement.shortTitle, action: #selector(contextChoice(_:)),
                                           keyEquivalent: "")
                item.target = self
                item.representedObject = choice(placement)
                item.setImageIfDesired(systemSymbolName: placement.symbol)
            }
            return submenu
        }

        guard tmuxPath != nil else {
            header("tmux is not installed (brew install tmux)")
            return wrap(menu)
        }

        // Actions for the clicked pane when it shows a tmux session.
        if let current = panes[view.id] {
            header(current.session)
            let detach = menu.addItem(withTitle: "Detach Session", action: #selector(detachSession(_:)), keyEquivalent: "")
            detach.target = self
            detach.representedObject = current.session
            detach.toolTip = "Closes this pane; the session keeps running and appears under Detached Sessions. Inside tmux: Ctrl-b d."
            detach.setImageIfDesired(systemSymbolName: "eject")
            let end = menu.addItem(withTitle: "End Session…", action: #selector(endSession(_:)), keyEquivalent: "")
            end.target = self
            end.representedObject = current.session
            end.setImageIfDesired(systemSymbolName: "xmark.circle")
            menu.addItem(.separator())
        }

        header("New Session")
        let profiles = PluginManager.shared.settings.tmux.profiles
        if profiles.isEmpty { header("No profiles; add one in the Plugin Manager") }
        for profile in profiles {
            let item = menu.addItem(withTitle: profile.name, action: nil, keyEquivalent: "")
            item.toolTip = "\(profile.command) in \(profile.directory)"
            item.submenu = placements { .init(source: view, placement: $0, action: .open(profile)) }
        }

        menu.addItem(.separator())
        header("Detached Sessions")
        let detached = listSessions(statusLabOnly: false).filter { !$0.attached && TmuxCommand.isValidSessionName($0.name) }
        if detached.isEmpty { header("None") }
        for session in detached.prefix(20) {
            let item = menu.addItem(withTitle: session.name, action: nil, keyEquivalent: "")
            item.toolTip = "\(session.windows) window(s), started \(session.created.formatted(date: .abbreviated, time: .shortened))"
            item.submenu = placements { .init(source: view, placement: $0, action: .attach(session.name)) }
        }

        menu.addItem(.separator())
        let manager = menu.addItem(withTitle: "Plugin Manager…", action: #selector(showPluginManager), keyEquivalent: "")
        manager.target = self
        return wrap(menu)
    }

    private func wrap(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: "tmux", action: nil, keyEquivalent: "")
        item.submenu = menu
        item.setImageIfDesired(systemSymbolName: "rectangle.split.3x1")
        return item
    }

    private final class ContextChoice: NSObject {
        enum Action {
            case open(TmuxProfile)
            case attach(String)
        }

        weak var source: Ghostty.SurfaceView?
        let placement: Placement
        let action: Action

        init(source: Ghostty.SurfaceView, placement: Placement, action: Action) {
            self.source = source
            self.placement = placement
            self.action = action
        }
    }

    @objc private func contextChoice(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ContextChoice else { return }
        switch choice.action {
        case .open(let profile): open(profile, placement: choice.placement, from: choice.source)
        case .attach(let name): attach(name, placement: choice.placement, from: choice.source)
        }
    }

    @objc private func showPluginManager() { PluginManager.shared.showManager() }

    /// Detaching ends the tmux client in the pane, so the pane closes; the session lives on.
    @objc private func detachSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let tmux = tmuxPath,
              TmuxCommand.isValidSessionName(name) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.run(tmux, ["detach-client", "-s", "=" + name])
            DispatchQueue.main.async { self.refreshSessions() }
        }
    }

    @objc private func endSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "End tmux session “\(name)”?"
        alert.informativeText = "Programs running in the session, such as Claude, are stopped and the pane closes."
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { kill(name) }
    }

    func kill(_ name: String) {
        guard let tmux = tmuxPath, TmuxCommand.isValidSessionName(name) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.run(tmux, ["kill-session", "-t", "=" + name])
            DispatchQueue.main.async { self.refreshSessions() }
        }
    }

    /// Runs tmux directly (no shell). Returns nil when no server is running, or when tmux
    /// does not answer within `timeout` (a wedged server must not freeze a menu).
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1) -> String? {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        // tmux output here is small; it fits the pipe buffer while we wait.
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
