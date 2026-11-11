import Foundation

/// The plugin choices made in the Plugin Manager. Pure value code without AppKit, so the
/// manifest generation and tmux command construction can be unit tested.
///
/// Every field decodes with a default, so settings written by older versions keep working.
struct StatusLabPluginSettings: Codable, Equatable {
    enum Position: String, Codable, CaseIterable {
        /// Left, after the working directory.
        case leading
        /// Right, before Sessions and Plugins.
        case trailing
        /// Far right, after Sessions and Plugins.
        case end
    }

    struct Stats: Codable, Equatable {
        enum GraphStyle: String, Codable, CaseIterable {
            /// Raw value kept from 0.5.0, when only the CPU graph was configurable.
            case lines = "sparkline"
            case blocks
        }

        var enabled = true
        var position = Position.leading
        /// A network interface name, or "auto" for the default route's interface.
        var interface = "auto"
        /// Graph style for every measurement: compact blocks or line graphs.
        var graphStyle = GraphStyle.blocks
        var disk = true
    }

    struct Weather: Codable, Equatable {
        struct Location: Codable, Equatable {
            var name: String
            var latitude: Double
            var longitude: Double
        }

        var enabled = true
        var position = Position.trailing
        var location: Location?
        var fahrenheit = false
    }

    struct Clock: Codable, Equatable {
        var enabled = true
        var position = Position.end
        /// A DateFormatter template; the locale decides order and punctuation.
        var template = "EEE d MMM yyyy HH:mm"
        var seconds = false

        var effectiveTemplate: String { seconds ? template + "ss" : template }
    }

    struct Tmux: Codable, Equatable {
        var enabled = true
        /// Turns tmux's own status line off for sessions opened by Ghostty; the Ghostty
        /// status bar already shows this information. Other tmux sessions are untouched.
        var hideStatusBar = true
        var profiles: [TmuxProfile] = [.claude]
    }

    /// Added plugins: an installed plugin package, or any executable that speaks the
    /// status protocol. The descriptive fields come from the package's plugin.json.
    struct Custom: Codable, Equatable, Identifiable {
        var id: String
        var executable: String
        var arguments: [String] = []
        var enabled = true
        var position = Position.leading
        var name: String?
        var summary: String?
        var version: String?
        var author: String?
        var homepage: String?
        /// The folder of an installed package (inside the app's plugin folder); nil for a
        /// plain executable added by path.
        var package: String?
        /// Stable row identity for the editor (the id itself is editable); not saved.
        var key = UUID()

        private enum CodingKeys: String, CodingKey {
            case id, executable, arguments, enabled, position, name, version, author, homepage, package
            case summary = "description"
        }

        var displayName: String {
            let name = (name ?? "").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? (id.isEmpty ? "Plugin" : id) : name
        }
    }

    var stats = Stats()
    var weather = Weather()
    var clock = Clock()
    var tmux = Tmux()
    var custom: [Custom] = []

    static let builtInIDs: Set<String> = ["system-stats", "weather", "clock"]

    // MARK: Manifest

    struct Manifest: Encodable {
        struct Plugin: Encodable, Equatable {
            let id: String
            let executable: String
            let arguments: [String]
            let position: String
        }

        let version = 1
        let plugins: [Plugin]
    }

    /// Builds the protocol v1 manifest. `helpers` contains the bundled plugin executables.
    func manifest(helpers: URL, interface resolvedInterface: String, locale: String) -> Manifest {
        var plugins: [Manifest.Plugin] = []
        func helper(_ name: String) -> String { helpers.appendingPathComponent(name).path }

        if stats.enabled {
            var arguments = [resolvedInterface, "--graph", stats.graphStyle == .blocks ? "blocks" : "lines"]
            if !stats.disk { arguments.append("--no-disk") }
            plugins.append(.init(id: "system-stats", executable: helper("system-stats"),
                                 arguments: arguments, position: stats.position.rawValue))
        }
        if weather.enabled {
            var arguments = ["--locale", locale]
            if let location = weather.location {
                arguments += ["--name", location.name,
                              "--latitude", String(location.latitude),
                              "--longitude", String(location.longitude)]
            }
            if weather.fahrenheit { arguments.append("--fahrenheit") }
            plugins.append(.init(id: "weather", executable: helper("weather"),
                                 arguments: arguments, position: weather.position.rawValue))
        }
        if clock.enabled {
            plugins.append(.init(id: "clock", executable: helper("clock"),
                                 arguments: ["--template", clock.effectiveTemplate, "--locale", locale],
                                 position: clock.position.rawValue))
        }
        // Duplicate ids would make the host reject the whole manifest; keep the first.
        var seen = Set(plugins.map(\.id))
        for plugin in custom where plugin.enabled && Self.isValid(plugin) && seen.insert(plugin.id).inserted {
            plugins.append(.init(id: plugin.id, executable: plugin.executable,
                                 arguments: plugin.arguments.filter { !$0.isEmpty },
                                 position: plugin.position.rawValue))
        }
        // The host accepts at most eight plugins.
        return Manifest(plugins: Array(plugins.prefix(8)))
    }

    /// Whether the plugin `id` falls outside the eight plugins the manifest keeps.
    static func limitReached(draft settings: StatusLabPluginSettings, id: String) -> Bool {
        let manifest = settings.manifest(helpers: URL(fileURLWithPath: "/"), interface: "en0", locale: "en")
        let wanted = settings.custom.contains { $0.id == id && $0.enabled && isValid($0) } ||
            (id == "system-stats" && settings.stats.enabled) || (id == "weather" && settings.weather.enabled) ||
            (id == "clock" && settings.clock.enabled)
        return wanted && !manifest.plugins.contains { $0.id == id }
    }

    static func isValid(_ plugin: Custom) -> Bool {
        !plugin.id.isEmpty && plugin.id.count <= 64 && !builtInIDs.contains(plugin.id) &&
            plugin.executable.hasPrefix("/") && !plugin.executable.contains("\0") &&
            plugin.arguments.count <= 32 && plugin.arguments.allSatisfy { !$0.contains("\0") }
    }
}

// MARK: Plugin packages

/// A plugin as it is shared: a folder with a `plugin.json` and the executable it names.
///
///     {
///       "id": "battery",
///       "name": "Battery",
///       "version": "1.0.0",
///       "description": "Charge and charging state.",
///       "author": "Your Name",
///       "homepage": "https://github.com/you/ghostty-battery",
///       "executable": "battery.sh",
///       "arguments": [],
///       "position": "trailing",
///       "protocol": 1
///     }
///
/// Installing copies the folder into the app's plugin folder, so the plugin keeps working
/// when the download is moved or deleted.
struct PluginPackage: Decodable, Equatable {
    static let manifestName = "plugin.json"

    var id: String
    var name: String
    var version: String
    var description: String?
    var author: String?
    var homepage: String?
    var executable: String
    var arguments: [String]?
    var position: StatusLabPluginSettings.Position?
    var `protocol`: Int?

    enum Failure: LocalizedError, Equatable {
        case missingManifest
        case unreadable(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missingManifest: "The folder has no plugin.json. A plugin package is a folder with a plugin.json and an executable."
            case .unreadable(let reason): "plugin.json could not be read: \(reason)"
            case .invalid(let reason): reason
            }
        }
    }

    /// Reads and validates the package in `folder`.
    static func load(_ folder: URL) throws -> PluginPackage {
        let file = folder.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.missingManifest }
        let data: Data
        let package: PluginPackage
        do {
            data = try Data(contentsOf: file)
            guard data.count <= 64 * 1024 else { throw Failure.invalid("plugin.json is larger than 64 KiB.") }
            package = try JSONDecoder().decode(Self.self, from: data)
        } catch let failure as Failure {
            throw failure
        } catch DecodingError.keyNotFound(let key, _) {
            throw Failure.unreadable("“\(key.stringValue)” is missing.")
        } catch DecodingError.typeMismatch(_, let context) {
            throw Failure.unreadable("“\(context.codingPath.map(\.stringValue).joined(separator: "."))” has the wrong type.")
        } catch DecodingError.dataCorrupted(let context) where !context.codingPath.isEmpty {
            throw Failure.unreadable("“\(context.codingPath.map(\.stringValue).joined(separator: "."))” has an invalid value.")
        } catch {
            throw Failure.unreadable("it is not valid JSON.")
        }
        try package.validate(in: folder)
        return package
    }

    func validate(in folder: URL) throws {
        func invalid(_ reason: String) -> Failure { .invalid(reason) }
        guard id.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            throw invalid("“id” must be 1–64 lowercase letters, digits, dots, dashes or underscores.")
        }
        guard !StatusLabPluginSettings.builtInIDs.contains(id) else {
            throw invalid("“\(id)” is the id of a built-in plugin.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, name.count <= 64 else { throw invalid("“name” must be 1–64 characters.") }
        guard !version.isEmpty, version.count <= 32 else { throw invalid("“version” must be 1–32 characters.") }
        guard (description?.count ?? 0) <= 300 else { throw invalid("“description” is longer than 300 characters.") }
        guard (author?.count ?? 0) <= 64 else { throw invalid("“author” is longer than 64 characters.") }
        if let homepage {
            guard let url = URL(string: homepage), url.scheme == "https", url.host != nil else {
                throw invalid("“homepage” must be an https link.")
            }
        }
        if let version = `protocol`, version != 1 {
            throw invalid("The plugin needs status protocol \(version); this version of Ghostty supports protocol 1.")
        }
        let arguments = arguments ?? []
        guard arguments.count <= 32, arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw invalid("“arguments” may have at most 32 entries.")
        }
        guard !executable.isEmpty, !executable.hasPrefix("/"), !executable.contains("\0"),
              !executable.split(separator: "/").contains("..") else {
            throw invalid("“executable” must be a path inside the package folder.")
        }
        // A symbolic link must not lead out of the package.
        let root = folder.resolvingSymlinksInPath().path + "/"
        let path = folder.appendingPathComponent(executable).resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { throw invalid("“executable” must be a path inside the package folder.") }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw invalid("“\(executable)” is missing or not executable (chmod +x).")
        }
    }

    /// The plugin entry for a package installed in `folder`.
    func plugin(installedAt folder: URL) -> StatusLabPluginSettings.Custom {
        .init(id: id, executable: folder.appendingPathComponent(executable).path, arguments: arguments ?? [],
              enabled: true, position: position ?? .leading, name: name, summary: description,
              version: version, author: author, homepage: homepage, package: folder.path)
    }
}

// MARK: tmux

/// A preset that opens a tmux session in a Ghostty pane, for example a Claude Code session.
struct TmuxProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Absolute path, or "~" relative to the home directory.
    var directory = "~"
    /// Runs when the profile is opened.
    var command: String
    /// Runs when a saved pane is restored but its tmux session no longer exists
    /// (for example after a restart). Empty means: use `command`.
    var resumeCommand = ""
    /// Ask for the start directory each time the profile is opened; `directory` is then
    /// only the fallback when there is no pane to start from.
    var askForDirectory = true

    static let claude = TmuxProfile(id: "claude", name: "Claude", directory: "~",
                                    command: "claude", resumeCommand: "claude --continue")

    var effectiveResumeCommand: String { resumeCommand.isEmpty ? command : resumeCommand }
}

/// The tmux part of a saved pane. Stored in session snapshots so the Session Manager can
/// reattach to the session after an app crash, or recreate it after a restart.
struct TmuxPane: Codable, Equatable {
    var session: String
    var profile: String
    var directory: String
    var resumeCommand: String

    var isValid: Bool {
        TmuxCommand.isValidSessionName(session) && directory.hasPrefix("/") &&
            resumeCommand.utf8.count <= 4096 && !resumeCommand.contains("\0") && profile.count <= 64
    }
}

enum TmuxCommand {
    /// Status Lab sessions use this prefix so they can be listed and cleaned up.
    static let sessionPrefix = "ghostty-"

    static func isValidSessionName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    static func newSessionName(profile: String) -> String {
        let slug = String(profile.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
            .prefix(24))
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return sessionPrefix + (slug.isEmpty ? "pane" : slug) + "-" + suffix
    }

    /// The command for a Ghostty surface that attaches to `session` when it is still alive
    /// and otherwise creates it in `directory`, running `command`. The user's login shell
    /// only provides the environment (so tools such as `claude` are on its PATH); the
    /// attach-or-create logic itself always runs in /bin/sh, so it also works when the
    /// login shell is fish. When the command exits, the pane keeps a login shell.
    ///
    /// With `hideStatus`, the session's own tmux status line is turned off (session option,
    /// so the user's other sessions and configuration are not affected).
    static func surfaceCommand(tmux: String, shell: String, session: String,
                               directory: String, command: String, hideStatus: Bool = false) -> String {
        let target = quote("=" + session)
        let inner = command + "; exec " + quote(shell) + " -l"
        // Option commands parse targets as panes: an exact session needs the "=name:" form.
        let hideExisting = hideStatus ? "\(quote(tmux)) set-option -t \(quote("=" + session + ":")) status off 2>/dev/null; " : ""
        let hideNew = hideStatus ? " ';' set-option status off" : ""
        let script = "if \(quote(tmux)) has-session -t \(target) 2>/dev/null; " +
            "then \(hideExisting)exec \(quote(tmux)) attach-session -t \(target); " +
            "else exec \(quote(tmux)) new-session -s \(quote(session)) -c \(quote(directory)) \(quote(inner))\(hideNew); fi"
        // The script travels in an environment variable: `exec /bin/sh -c "$VAR"` is valid
        // in sh, bash, zsh and fish alike.
        return "/bin/sh -c " + quote("\(scriptVariable)=" + quote(script) + " exec " + quote(shell) +
                                     " -lic " + quote("exec /bin/sh -c \"$\(scriptVariable)\""))
    }

    static let scriptVariable = "GHOSTTY_TMUX_SCRIPT"

    static func expand(directory: String, home: String) -> String {
        if directory == "~" { return home }
        if directory.hasPrefix("~/") { return home + directory.dropFirst() }
        return directory
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

// MARK: Lenient decoding

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension StatusLabPluginSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        stats = c.value(.stats, defaults.stats)
        weather = c.value(.weather, defaults.weather)
        clock = c.value(.clock, defaults.clock)
        tmux = c.value(.tmux, defaults.tmux)
        custom = c.value(.custom, defaults.custom)
    }
}

extension StatusLabPluginSettings.Stats {
    private enum LegacyKeys: String, CodingKey { case cpuGraph }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        enabled = c.value(.enabled, defaults.enabled)
        position = c.value(.position, defaults.position)
        interface = c.value(.interface, defaults.interface)
        // 0.5.0 stored this as "cpuGraph".
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(GraphStyle.self, forKey: .cpuGraph)
        graphStyle = c.value(.graphStyle, legacy ?? defaults.graphStyle)
        disk = c.value(.disk, defaults.disk)
    }
}

extension StatusLabPluginSettings.Weather {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        enabled = c.value(.enabled, defaults.enabled)
        position = c.value(.position, defaults.position)
        location = c.value(.location, defaults.location)
        fahrenheit = c.value(.fahrenheit, defaults.fahrenheit)
    }
}

extension StatusLabPluginSettings.Clock {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        enabled = c.value(.enabled, defaults.enabled)
        position = c.value(.position, defaults.position)
        template = c.value(.template, defaults.template)
        seconds = c.value(.seconds, defaults.seconds)
    }
}

extension TmuxProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, id)
        directory = c.value(.directory, "~")
        command = c.value(.command, "$SHELL -l")
        resumeCommand = c.value(.resumeCommand, "")
        askForDirectory = c.value(.askForDirectory, true)
    }
}

extension StatusLabPluginSettings.Tmux {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        enabled = c.value(.enabled, defaults.enabled)
        hideStatusBar = c.value(.hideStatusBar, defaults.hideStatusBar)
        profiles = c.value(.profiles, defaults.profiles)
    }
}
