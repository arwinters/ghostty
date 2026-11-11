import AppKit

/// An AI coding tool from the configuration (`macos-ai-session`), opened in a tmux session.
///
///     macos-ai-session = name:Claude Code,command:claude,resume:claude --continue
struct AISession: Equatable, Identifiable {
    var name: String
    var command: String
    /// What runs when a saved session is restored after its tmux session ended.
    var resume: String

    /// Also the profile id, so tmux session names read `ghostty-claude-code-ab12`.
    var id: String {
        let slug = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "ai" : String(slug.prefix(24))
    }

    /// The program the command starts, to check that it is installed.
    var executable: String { String(command.split(whereSeparator: \.isWhitespace).first ?? "") }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unknownKey(String)
        case malformed

        var description: String {
            switch self {
            case .missing(let key): "“\(key)” is missing"
            case .unknownKey(let key): "unknown key “\(key)” (use name, command and resume)"
            case .malformed: "expected key:value pairs separated by commas"
            }
        }
    }

    /// Parses one configuration value: comma-separated `key:value` pairs. Values may be
    /// double-quoted to contain commas; `\"` and `\\` escape inside quotes.
    static func parse(_ value: String) -> Result<AISession, ParseError> {
        var fields: [String: String] = [:]
        for part in split(value) {
            guard let colon = part.firstIndex(of: ":") else { return .failure(.malformed) }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard ["name", "command", "resume"].contains(key) else { return .failure(.unknownKey(key)) }
            fields[key] = unquote(raw)
        }
        guard let name = fields["name"], !name.isEmpty else { return .failure(.missing("name")) }
        guard let command = fields["command"], !command.isEmpty else { return .failure(.missing("command")) }
        let resume = fields["resume"].flatMap { $0.isEmpty ? nil : $0 } ?? command
        return .success(.init(name: name, command: command, resume: resume))
    }

    /// Every valid entry, and a message per invalid one. Later entries with the same name
    /// replace earlier ones, as later configuration lines do.
    static func parseAll(_ values: [String]) -> (sessions: [AISession], errors: [String]) {
        var sessions: [AISession] = []
        var errors: [String] = []
        for value in values {
            switch parse(value) {
            case .success(let session):
                sessions.removeAll { $0.id == session.id }
                sessions.append(session)
            case .failure(let error):
                errors.append("macos-ai-session = \(value): \(error)")
            }
        }
        return (sessions, errors)
    }

    private static func split(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if quoted && character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == "," && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// The AI tools of the current configuration, and the menus that open them.
final class AISessions: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = AISessions()

    @Published private(set) var sessions: [AISession] = []
    @Published private(set) var errors: [String] = []
    /// By executable; nil while not checked yet.
    @Published private(set) var installed: [String: Bool] = [:]
    private var checking = Set<String>()
    private var observer: NSObjectProtocol?

    private override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
    }

    /// Reads the configuration again and checks tools that were not checked yet.
    func reload() {
        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config else { return }
        let parsed = AISession.parseAll(config.aiSessions)
        if parsed.sessions != sessions { sessions = parsed.sessions }
        if parsed.errors != errors { errors = parsed.errors }
        for executable in Set(sessions.map(\.executable)) where installed[executable] == nil {
            check(executable)
        }
    }

    /// Checks again whether every tool is installed, for example after installing one.
    func recheck() {
        installed = [:]
        reload()
    }

    /// Looks the program up in the user's interactive login shell, where tools installed
    /// with npm, Homebrew or an installer script are on PATH.
    private func check(_ executable: String) {
        guard !executable.isEmpty, checking.insert(executable).inserted else { return }
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lic", "command -v " + TmuxCommand.quote(executable)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var found = false
            if (try? process.run()) != nil {
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                if done.wait(timeout: .now() + 10) == .success {
                    found = process.terminationStatus == 0
                } else {
                    process.terminate()
                }
            }
            DispatchQueue.main.async {
                self.checking.remove(executable)
                self.installed[executable] = found
            }
        }
    }

    func open(_ session: AISession, placement: TmuxPlugin.Placement, from view: Ghostty.SurfaceView?, directory: String?) {
        let profile = TmuxProfile(id: session.id, name: session.name, directory: directory ?? "~",
                                  command: session.command, resumeCommand: session.resume, askForDirectory: false)
        TmuxPlugin.shared.open(profile, placement: placement, from: view)
    }

    // MARK: Menus

    /// "New AI Session" for a pane's context menu, starting in `directory`; nil when no
    /// tool is configured.
    func contextMenuItem(for view: Ghostty.SurfaceView, directory: String?) -> NSMenuItem? {
        reload()
        guard !sessions.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for session in sessions {
            menu.addItem(item(for: session, source: view, directory: directory))
        }
        menu.addItem(.separator())
        let configure = menu.addItem(withTitle: "Configure AI Sessions…", action: #selector(showSettings), keyEquivalent: "")
        configure.target = self
        let item = NSMenuItem(title: "New AI Session", action: nil, keyEquivalent: "")
        item.submenu = menu
        item.setImageIfDesired(systemSymbolName: "sparkles")
        return item
    }

    /// One tool with a submenu of placements; disabled when it is not installed.
    func item(for session: AISession, source: Ghostty.SurfaceView?, directory: String?) -> NSMenuItem {
        let available = installed[session.executable] != false
        let item = NSMenuItem(title: available ? session.name : "\(session.name) — not installed", action: nil, keyEquivalent: "")
        item.isEnabled = available
        item.toolTip = available ? session.command : "“\(session.executable)” was not found in your login shell."
        guard available else { return item }
        let submenu = NSMenu()
        for placement in [TmuxPlugin.Placement.splitRight, .splitDown, .tab] {
            let action = submenu.addItem(withTitle: placement.shortTitle, action: #selector(choose(_:)), keyEquivalent: "")
            action.target = self
            action.representedObject = Choice(session: session, placement: placement, source: source, directory: directory)
            action.setImageIfDesired(systemSymbolName: placement.symbol)
        }
        item.submenu = submenu
        return item
    }

    private final class Choice: NSObject {
        let session: AISession
        let placement: TmuxPlugin.Placement
        weak var source: Ghostty.SurfaceView?
        let directory: String?

        init(session: AISession, placement: TmuxPlugin.Placement, source: Ghostty.SurfaceView?, directory: String?) {
            self.session = session
            self.placement = placement
            self.source = source
            self.directory = directory
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        // From the app menu: start where the focused pane is working.
        let focused = (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface
        open(choice.session, placement: choice.placement, from: choice.source,
             directory: choice.directory ?? focused?.contextDirectory)
    }

    /// The "New AI Session" submenu of the Plugins menu, built when it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        reload()
        menu.removeAllItems()
        menu.autoenablesItems = false
        if sessions.isEmpty {
            let none = menu.addItem(withTitle: "No AI tools configured", action: nil, keyEquivalent: "")
            none.isEnabled = false
        }
        for session in sessions { menu.addItem(item(for: session, source: nil, directory: nil)) }
        menu.addItem(.separator())
        let configure = menu.addItem(withTitle: "Configure AI Sessions…", action: #selector(showSettings), keyEquivalent: "")
        configure.target = self
    }

    @objc private func showSettings() { PluginManager.shared.showManager(page: .ai) }
}
