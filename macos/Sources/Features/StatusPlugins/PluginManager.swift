import AppKit
import SwiftUI

/// Owns the Status Lab plugin choices: stores them, writes the generated manifest the status
/// bars load, and offers the Plugin Manager window and Plugins menu.
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    /// The saved settings. Edit a copy in the UI and `apply` it.
    @Published private(set) var settings: StatusLabPluginSettings
    @Published private(set) var message: String?
    /// A page the window should show, set by `showManager(page:)`.
    @Published var requestedPage: PluginManagerPage?

    private var panel: NSWindow?
    private var menuItem: NSMenuItem?

    /// Only the Status Lab builds generate their plugin manifest.
    static var enabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "StatusLabVersion") != nil
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.arwinters.ghostty.statuslab")
    }

    static var settingsFile: URL { supportDirectory.appendingPathComponent("plugins.settings.json") }
    static var manifestFile: URL { supportDirectory.appendingPathComponent("plugins.generated.json") }
    static var helpers: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") }
    /// Installed plugin packages, one folder each.
    static var packagesDirectory: URL { supportDirectory.appendingPathComponent("plugins") }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "StatusLabVersion") as? String ?? "" }
    static let documentation = URL(string: "https://github.com/arwinters/ghostty/blob/status-lab/macos/StatusLab/PLUGINS.md")!

    private init() {
        settings = Self.loadSettings()
    }

    // MARK: Storage

    static func loadSettings() -> StatusLabPluginSettings {
        if let data = try? Data(contentsOf: settingsFile),
           let value = try? JSONDecoder().decode(StatusLabPluginSettings.self, from: data) {
            return value
        }
        // First run: keep the interface choice of earlier builds.
        var value = StatusLabPluginSettings()
        let legacy = supportDirectory.appendingPathComponent("network-interface")
        if let interface = try? String(contentsOf: legacy, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !interface.isEmpty {
            value.stats.interface = interface
        }
        return value
    }

    /// Writes the manifest for `settings`. Also called by the bootstrap before the
    /// configuration is loaded, so the first status bar already uses it.
    static func writeManifest(_ settings: StatusLabPluginSettings) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let interface = settings.stats.interface == "auto" ? defaultRouteInterface() : settings.stats.interface
        let manifest = settings.manifest(helpers: helpers, interface: interface, locale: Locale.current.identifier)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestFile, options: .atomic)
    }

    func apply(_ new: StatusLabPluginSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try encoder.encode(new).write(to: Self.settingsFile, options: .atomic)
            try Self.writeManifest(new)
            settings = new
            Self.removeUnusedPackages(keeping: new)
            message = "Applied \(Date().formatted(date: .omitted, time: .shortened))"
            rebuildMenu()
            NotificationCenter.default.post(name: .statusPluginsDidChange, object: nil)
        } catch {
            message = "Could not save plugin settings: \(error.localizedDescription)"
        }
    }

    private static func defaultRouteInterface() -> String {
        let route = Process()
        let output = Pipe()
        route.executableURL = URL(fileURLWithPath: "/sbin/route")
        route.arguments = ["-n", "get", "default"]
        route.standardOutput = output
        route.standardError = FileHandle.nullDevice
        guard (try? route.run()) != nil else { return "en0" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        route.waitUntilExit()
        let line = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }
        return line?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "en0"
    }

    // MARK: Menu

    func start() {
        guard Self.enabled, menuItem == nil else { return }
        let item = NSMenuItem(title: "Plugins", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: "Plugins")
        NSApp.mainMenu?.insertBeforeHelp(item)
        menuItem = item
        rebuildMenu()
        Self.removeUnusedPackages(keeping: settings)
    }

    // MARK: Packages

    /// Copies a plugin package into the app's plugin folder and returns its entry. Every
    /// install gets a new folder, so a running copy is never changed underneath the host;
    /// folders no longer used are removed when settings are applied and at launch.
    func install(from folder: URL) throws -> StatusLabPluginSettings.Custom {
        let files = FileManager.default
        try files.createDirectory(at: Self.packagesDirectory, withIntermediateDirectories: true)
        let package = try PluginPackage.load(folder)
        let target = Self.packagesDirectory.appendingPathComponent(
            package.id + "-" + String(UUID().uuidString.prefix(8)).lowercased())
        try files.copyItem(at: folder, to: target)
        do {
            // Validate the copy: it is what will run.
            return try PluginPackage.load(target).plugin(installedAt: target)
        } catch {
            try? files.removeItem(at: target)
            throw error
        }
    }

    static func removeUnusedPackages(keeping settings: StatusLabPluginSettings) {
        let used = Set(settings.custom.compactMap(\.package).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: packagesDirectory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where !used.contains(entry.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func rebuildMenu() {
        guard let menu = menuItem?.submenu else { return }
        menu.removeAllItems()
        let manager = NSMenuItem(title: "Plugin Manager…", action: #selector(showManagerFromMenu), keyEquivalent: "p")
        manager.keyEquivalentModifierMask = [.command, .option]
        manager.target = self
        menu.addItem(manager)

        let ai = NSMenuItem(title: "New AI Session", action: nil, keyEquivalent: "")
        ai.submenu = NSMenu(title: "New AI Session")
        ai.submenu?.delegate = AISessions.shared
        ai.setImageIfDesired(systemSymbolName: "sparkles")
        menu.addItem(.separator())
        menu.addItem(ai)

        guard settings.tmux.enabled else { return }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "tmux", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, profile) in settings.tmux.profiles.enumerated() {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: profile.name)
            for placement in TmuxPlugin.Placement.allCases {
                let action = NSMenuItem(title: placement.title, action: #selector(openTmux(_:)), keyEquivalent: "")
                action.target = self
                action.representedObject = TmuxMenuChoice(profile: profile, placement: placement)
                // The first profile gets a shortcut for a new tab: ⌥⌘T.
                if index == 0 && placement == .tab {
                    action.keyEquivalent = "t"
                    action.keyEquivalentModifierMask = [.command, .option]
                }
                submenu.addItem(action)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private final class TmuxMenuChoice: NSObject {
        let profile: TmuxProfile
        let placement: TmuxPlugin.Placement
        init(profile: TmuxProfile, placement: TmuxPlugin.Placement) {
            self.profile = profile
            self.placement = placement
        }
    }

    @objc private func openTmux(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TmuxMenuChoice else { return }
        TmuxPlugin.shared.open(choice.profile, placement: choice.placement)
    }

    @objc private func showManagerFromMenu() { showManager() }

    // MARK: Window

    func showManager(page: PluginManagerPage? = nil) {
        requestedPage = page
        if panel == nil {
            panel = ManagerWindow.make(title: "Plugin Manager", autosave: "StatusLabPluginManager",
                                       rootView: PluginManagerView(manager: self))
        }
        message = nil
        TmuxPlugin.shared.refreshSessions()
        panel?.makeKeyAndOrderFront(nil)
    }
}

enum PluginManagerPage { case installed, ai }

extension NSMenu {
    /// Adds a top-level menu while keeping Help the last menu, as macOS expects.
    func insertBeforeHelp(_ item: NSMenuItem) {
        let help = items.firstIndex { $0.submenu === NSApp.helpMenu || $0.title == "Help" }
        insertItem(item, at: help ?? items.count)
    }
}

extension Notification.Name {
    /// The generated manifest changed; status bars restart their plugins.
    static let statusPluginsDidChange = Notification.Name("com.arwinters.ghostty.statusPluginsDidChange")
}

// MARK: - Weather location search

enum WeatherGeocoder {
    struct Result: Decodable, Identifiable, Hashable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let admin1: String?

        var title: String { [name, admin1, country].compactMap { $0 }.joined(separator: ", ") }
    }

    private struct Response: Decodable { let results: [Result]? }

    /// Open-Meteo geocoding; no API key, only the typed place name is sent.
    static func search(_ query: String) async throws -> [Result] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: "8"),
            .init(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(Response.self, from: data).results ?? []
    }
}


// MARK: - Views

/// What the Plugin Manager shows about a plugin, built-in or added.
private struct PluginInfo {
    enum Kind { case builtIn, package, executable }

    let name: String
    let symbol: String
    let kind: Kind
    var version: String?
    var author: String?
    var summary: String
    var homepage: URL?

    static let stats = builtIn("System Stats", "cpu", "CPU, memory, network and disk activity of this Mac. Measured locally; nothing leaves the computer.")
    static let weather = builtIn("Weather", "cloud.sun", "Current conditions for a place you choose, from Open-Meteo.")
    static let clock = builtIn("Clock", "clock", "Date and time in the format of your region.")
    static let battery = builtIn("Battery", "battery.75", "Charge of this Mac's battery and the time left, read from macOS. Shows nothing on a Mac without a battery.")
    static let tmux = builtIn("tmux", "rectangle.split.3x1", "Panes that run in tmux, such as Claude Code sessions. They keep running when a pane closes or Ghostty crashes.")
    static let ai = builtIn("AI Sessions", "sparkles", "Start Claude Code, Codex or another AI tool from a pane's right-click menu, in that pane's directory. Configured in your Ghostty configuration.")

    private static func builtIn(_ name: String, _ symbol: String, _ summary: String) -> PluginInfo {
        .init(name: name, symbol: symbol, kind: .builtIn, version: PluginManager.version, summary: summary)
    }

    init(name: String, symbol: String, kind: Kind, version: String? = nil, author: String? = nil,
         summary: String, homepage: URL? = nil) {
        self.name = name
        self.symbol = symbol
        self.kind = kind
        self.version = version
        self.author = author
        self.summary = summary
        self.homepage = homepage
    }

    init(_ plugin: StatusLabPluginSettings.Custom) {
        name = plugin.displayName
        symbol = plugin.package == nil ? "terminal" : "puzzlepiece.extension"
        kind = plugin.package == nil ? .executable : .package
        version = plugin.version
        author = plugin.author
        summary = plugin.summary ?? (plugin.package == nil
            ? "A status protocol v1 executable added by path."
            : "Installed plugin package.")
        homepage = plugin.homepage.flatMap(URL.init(string:))
    }

    var kindTitle: String {
        switch kind {
        case .builtIn: "Built-in"
        case .package: "Installed"
        case .executable: "Executable"
        }
    }

    var meta: String {
        var parts: [String] = []
        if let version, !version.isEmpty { parts.append("Version \(version)") }
        if let author, !author.isEmpty { parts.append("by \(author)") }
        if kind == .builtIn { parts.append("Ships with Ghostty Status Lab") }
        return parts.joined(separator: " · ")
    }
}

/// What a plugin is doing now, from the draft and the running host.
private enum PluginState: Equatable {
    case running, starting, off, ready
    case willStart, willStop, willRestart
    case failed(String)
    case unavailable(String)

    var title: String {
        switch self {
        case .running: "Running"
        case .starting: "Starting"
        case .off: "Off"
        case .ready: "Ready"
        case .willStart: "Starts when you press Apply"
        case .willStop: "Stops when you press Apply"
        case .willRestart: "Restarts with the changes when you press Apply"
        case .failed(let reason): reason
        case .unavailable(let reason): reason
        }
    }

    var color: Color {
        switch self {
        case .running, .ready: .green
        case .starting, .willStart, .willStop, .willRestart: .yellow
        case .off: .secondary
        case .failed, .unavailable: .orange
        }
    }
}

private struct PluginManagerView: View {
    @ObservedObject var manager: PluginManager
    @ObservedObject private var host = StatusPluginHost.shared
    @ObservedObject private var tmux = TmuxPlugin.shared
    @ObservedObject private var ai = AISessions.shared
    @State private var draft: StatusLabPluginSettings
    @State private var page: Page = .installed

    enum Page: Hashable, Identifiable {
        case installed, stats, weather, battery, clock, tmux, ai
        case custom(UUID)
        var id: Self { self }
    }

    init(manager: PluginManager) {
        self.manager = manager
        _draft = State(initialValue: manager.settings)
    }

    private var pages: [Page] {
        [.installed, .stats, .weather, .battery, .clock, .tmux, .ai] + draft.custom.map { .custom($0.key) }
    }

    var body: some View {
        ManagerLayout(pages: pages, selection: $page, row: row) { page in
            switch page {
            case .installed:
                InstalledPage(manager: manager, draft: $draft, open: { self.page = $0 }, state: state)
            case .stats:
                PluginHeader(info: .stats, enabled: $draft.stats.enabled, state: state(.stats))
                StatsSection(settings: $draft.stats)
            case .weather:
                PluginHeader(info: .weather, enabled: $draft.weather.enabled, state: state(.weather))
                WeatherSection(settings: $draft.weather)
            case .battery:
                PluginHeader(info: .battery, enabled: $draft.battery.enabled, state: state(.battery))
                BatterySection(settings: $draft.battery)
            case .clock:
                PluginHeader(info: .clock, enabled: $draft.clock.enabled, state: state(.clock))
                ClockSection(settings: $draft.clock)
            case .tmux:
                PluginHeader(info: .tmux, enabled: $draft.tmux.enabled, state: state(.tmux))
                TmuxSection(settings: $draft.tmux)
            case .ai:
                PluginHeader(info: .ai, enabled: nil, state: state(.ai))
                AISection()
            case .custom(let key):
                if let plugin = draft.custom.first(where: { $0.key == key }) {
                    let binding = custom(key, fallback: plugin)
                    PluginHeader(info: PluginInfo(plugin), enabled: binding.enabled, state: state(.custom(key)))
                    CustomSection(plugin: binding, others: draft.custom.filter { $0.key != key }) {
                        draft.custom.removeAll { $0.key == key }
                        self.page = .installed
                    }
                }
            }
        } footer: {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(draft == manager.settings ? Color.secondary : Color.orange)
            Spacer()
            Button("Revert") { draft = manager.settings }
                .disabled(draft == manager.settings)
            Button("Apply") { manager.apply(draft) }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == manager.settings)
        }
        .onReceive(manager.$requestedPage) { requested in
            guard let requested else { return }
            page = requested == .ai ? .ai : .installed
            manager.requestedPage = nil
        }
        .onChange(of: draft.custom.map(\.key)) { keys in
            if case .custom(let key) = page, !keys.contains(key) { page = .installed }
        }
    }

    private var footerText: String {
        if draft != manager.settings { return "Unapplied changes. Apply updates every window." }
        return manager.message ?? "Changes apply to every window when you press Apply."
    }

    private func custom(_ key: UUID, fallback: StatusLabPluginSettings.Custom) -> Binding<StatusLabPluginSettings.Custom> {
        Binding(
            get: { draft.custom.first { $0.key == key } ?? fallback },
            set: { value in
                if let index = draft.custom.firstIndex(where: { $0.key == key }) { draft.custom[index] = value }
            })
    }

    private func row(_ page: Page) -> ManagerLayoutRow {
        let state = state(page)
        let badge: String? = switch state {
        case .off, .willStop: "Off"
        case .failed, .unavailable: "!"
        default: nil
        }
        let color: Color? = if case .failed = state { .orange } else if case .unavailable = state { .orange } else { nil }
        switch page {
        case .installed:
            return .init(title: "Installed", symbol: "square.grid.2x2")
        case .stats:
            return .init(title: "System Stats", symbol: PluginInfo.stats.symbol, badge: badge, group: "Plugins", badgeColor: color)
        case .weather:
            return .init(title: "Weather", symbol: PluginInfo.weather.symbol, badge: badge, group: "Plugins", badgeColor: color)
        case .battery:
            return .init(title: "Battery", symbol: PluginInfo.battery.symbol, badge: badge, group: "Plugins", badgeColor: color)
        case .clock:
            return .init(title: "Clock", symbol: PluginInfo.clock.symbol, badge: badge, group: "Plugins", badgeColor: color)
        case .tmux:
            return .init(title: "tmux", symbol: PluginInfo.tmux.symbol, badge: badge, group: "Plugins", badgeColor: color)
        case .ai:
            return .init(title: "AI Sessions", symbol: PluginInfo.ai.symbol, badge: badge, group: "Plugins", badgeColor: color)
        case .custom(let key):
            let plugin = draft.custom.first { $0.key == key }
            return .init(title: plugin?.displayName ?? "Plugin", symbol: plugin.map { PluginInfo($0).symbol } ?? "puzzlepiece.extension",
                         badge: badge, group: "Plugins", badgeColor: color)
        }
    }

    /// Combines the draft (what Apply will do) with the host (what runs now).
    func state(_ page: Page) -> PluginState {
        let wanted: Bool
        let applied: Bool
        let id: String
        switch page {
        case .installed:
            return .ready
        case .stats:
            (wanted, applied, id) = (draft.stats.enabled, manager.settings.stats.enabled, "system-stats")
        case .weather:
            (wanted, applied, id) = (draft.weather.enabled, manager.settings.weather.enabled, "weather")
        case .battery:
            (wanted, applied, id) = (draft.battery.enabled, manager.settings.battery.enabled, "battery")
        case .clock:
            (wanted, applied, id) = (draft.clock.enabled, manager.settings.clock.enabled, "clock")
        case .tmux:
            if !draft.tmux.enabled { return manager.settings.tmux.enabled ? .willStop : .off }
            if tmux.tmuxPath == nil { return .unavailable("tmux is not installed (brew install tmux)") }
            return manager.settings.tmux.enabled ? .ready : .willStart
        case .ai:
            if !ai.errors.isEmpty { return .failed("Configuration error") }
            if ai.sessions.isEmpty { return .off }
            if tmux.tmuxPath == nil { return .unavailable("tmux is not installed (brew install tmux)") }
            let count = ai.sessions.filter { ai.installed[$0.executable] != false }.count
            return count == 0 ? .unavailable("None of the configured tools is installed") : .ready
        case .custom(let key):
            guard let plugin = draft.custom.first(where: { $0.key == key }) else { return .off }
            let saved = manager.settings.custom.first { $0.key == key }
            if plugin.enabled && !StatusLabPluginSettings.isValid(plugin) {
                return .unavailable("Needs a unique identifier and an absolute executable path")
            }
            (wanted, applied, id) = (plugin.enabled, saved?.enabled == true, saved?.id ?? plugin.id)
            // Changed settings take effect when applied.
            if wanted, applied, saved != plugin { return .willRestart }
        }
        if !wanted { return applied ? .willStop : .off }
        if !applied { return .willStart }
        switch host.statuses[id] {
        case .running: return .running
        case .starting: return .starting
        case .failed(let reason): return .failed(reason)
        case nil:
            // The host runs at most eight plugins, and only while a status bar is shown.
            return .unavailable(StatusLabPluginSettings.limitReached(draft: manager.settings, id: id)
                ? "Not running: at most eight plugins run at once" : "Not running")
        }
    }
}

/// Every plugin at a glance, with the ways to add one.
private struct InstalledPage: View {
    @ObservedObject var manager: PluginManager
    @Binding var draft: StatusLabPluginSettings
    let open: (PluginManagerView.Page) -> Void
    let state: (PluginManagerView.Page) -> PluginState
    @State private var failure: String?

    private var slots: Int {
        [draft.stats.enabled, draft.weather.enabled, draft.battery.enabled, draft.clock.enabled].filter { $0 }.count +
            draft.custom.filter { $0.enabled && StatusLabPluginSettings.isValid($0) }.count
    }

    var body: some View {
        Section {
            PluginRow(info: .stats, enabled: $draft.stats.enabled, state: state(.stats)) { open(.stats) }
            PluginRow(info: .weather, enabled: $draft.weather.enabled, state: state(.weather)) { open(.weather) }
            PluginRow(info: .battery, enabled: $draft.battery.enabled, state: state(.battery)) { open(.battery) }
            PluginRow(info: .clock, enabled: $draft.clock.enabled, state: state(.clock)) { open(.clock) }
            PluginRow(info: .tmux, enabled: $draft.tmux.enabled, state: state(.tmux)) { open(.tmux) }
            PluginRow(info: .ai, enabled: nil, state: state(.ai)) { open(.ai) }
            ForEach($draft.custom, id: \.key) { $plugin in
                PluginRow(info: PluginInfo(plugin), enabled: $plugin.enabled, state: state(.custom(plugin.key))) {
                    open(.custom(plugin.key))
                }
            }
        } header: {
            HStack {
                Text("Installed plugins")
                Spacer()
                Text("\(slots) of 8 status bar slots in use")
                    .foregroundStyle(slots > 8 ? Color.orange : Color.secondary)
                    .monospacedDigit()
            }
        } footer: {
            Text("Turn a plugin off to stop it; its settings are kept. tmux adds panes and menus, so it does not use a status bar slot.")
        }

        Section {
            HStack {
                Button("Install Plugin…", action: install)
                Button("Add Executable…", action: addExecutable)
                Spacer()
                Link("How to write a plugin", destination: PluginManager.documentation)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Add a plugin")
        } footer: {
            Text("A plugin package is a folder with a plugin.json and an executable; installing copies it into Ghostty. Plugins run with your permissions and are not sandboxed: only install plugins you trust.")
        }
    }

    private func install() {
        let panel = NSOpenPanel()
        panel.message = "Choose a plugin folder (it contains a plugin.json)."
        panel.prompt = "Install"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            var plugin = try manager.install(from: folder)
            // Installing the same plugin again updates it and keeps its choices.
            if let index = draft.custom.firstIndex(where: { $0.id == plugin.id }) {
                let old = draft.custom[index]
                plugin.key = old.key
                plugin.enabled = old.enabled
                plugin.position = old.position
                draft.custom[index] = plugin
            } else {
                draft.custom.append(plugin)
            }
            failure = nil
            open(.custom(plugin.key))
        } catch {
            failure = error.localizedDescription
        }
    }

    private func addExecutable() {
        let panel = NSOpenPanel()
        panel.message = "Choose an executable that writes status protocol v1 to stdout."
        panel.prompt = "Add"
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let base = url.deletingPathExtension().lastPathComponent
        let slug = String(base.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
            .prefix(48))
        var id = slug.isEmpty ? "plugin" : slug
        let taken = Set(draft.custom.map(\.id)).union(StatusLabPluginSettings.builtInIDs)
        if taken.contains(id) {
            var number = 2
            while taken.contains("\(id)-\(number)") { number += 1 }
            id = "\(id)-\(number)"
        }
        let plugin = StatusLabPluginSettings.Custom(id: id, executable: url.path, name: base)
        draft.custom.append(plugin)
        failure = nil
        open(.custom(plugin.key))
    }
}

private struct PluginIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24).fill(Color.accentColor.opacity(0.14)))
    }
}

private struct StateLabel: View {
    let state: PluginState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(state.title).lineLimit(1).truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(state.title)
    }
}

private struct KindBadge: View {
    let info: PluginInfo

    var body: some View {
        Text(info.kindTitle)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}

private struct PluginRow: View {
    let info: PluginInfo
    /// nil for a plugin configured elsewhere (the AI sessions live in the configuration).
    let enabled: Binding<Bool>?
    let state: PluginState
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PluginIcon(symbol: info.symbol, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.name).fontWeight(.medium)
                    KindBadge(info: info)
                    if let version = info.version, !version.isEmpty {
                        Text(version).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                StateLabel(state: state)
            }
            Spacer(minLength: 8)
            if let enabled {
                Toggle("Enabled", isOn: enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Button(action: open) { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Settings")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

/// The top of a plugin page: what it is, whether it runs, and the switch.
private struct PluginHeader: View {
    let info: PluginInfo
    let enabled: Binding<Bool>?
    let state: PluginState

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                PluginIcon(symbol: info.symbol, size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(info.name).font(.title2.weight(.semibold))
                        KindBadge(info: info)
                    }
                    if !info.meta.isEmpty {
                        Text(info.meta).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(info.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        StateLabel(state: state)
                        if let homepage = info.homepage {
                            Link("Website", destination: homepage).font(.caption)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 8)
                if let enabled {
                    Toggle("Enabled", isOn: enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(enabled.wrappedValue ? "Turn off" : "Turn on")
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct PositionPicker: View {
    @Binding var position: StatusLabPluginSettings.Position

    var body: some View {
        Picker("Position in status bar", selection: $position) {
            Text("Left").tag(StatusLabPluginSettings.Position.leading)
            Text("Right, before Sessions").tag(StatusLabPluginSettings.Position.trailing)
            Text("Far right, after Sessions").tag(StatusLabPluginSettings.Position.end)
        }
    }
}

private struct StatsSection: View {
    @Binding var settings: StatusLabPluginSettings.Stats

    var body: some View {
        Section {
            PositionPicker(position: $settings.position)
            Picker("Graph style", selection: $settings.graphStyle) {
                Text("Blocks (compact)").tag(StatusLabPluginSettings.Stats.GraphStyle.blocks)
                Text("Lines").tag(StatusLabPluginSettings.Stats.GraphStyle.lines)
            }
            Picker("Network and disk activity", selection: $settings.activity) {
                Text("Combined").tag(StatusLabPluginSettings.Stats.ActivityStyle.combined)
                Text("Separate").tag(StatusLabPluginSettings.Stats.ActivityStyle.separate)
            }
            Toggle("Show disk space and disk activity", isOn: $settings.disk)
        } header: {
            Text("Display")
        } footer: {
            Text((settings.graphStyle == .blocks
                 ? "CPU: one block per core, performance cores cyan and efficiency cores amber. Memory and disk space: a meter each, red when nearly full. Activity: the last 12 seconds."
                 : "Line graphs of the last 60 seconds.") +
                 (settings.activity == .combined
                  ? " Combined: download (blue) and disk reads (green) grow up, upload (red) and disk writes (magenta) grow down, on one scale per graph." : ""))
        }
        Section {
            TextField("Interface", text: $settings.interface, prompt: Text("auto"))
        } header: {
            Text("Network")
        } footer: {
            Text("“auto” follows the interface of the default route; or enter a name such as en0.")
        }
    }
}

private struct WeatherSection: View {
    @Binding var settings: StatusLabPluginSettings.Weather
    @State private var query = ""
    @State private var results: [WeatherGeocoder.Result] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        Section {
            PositionPicker(position: $settings.position)
            Picker("Units", selection: $settings.fahrenheit) {
                Text("Celsius").tag(false)
                Text("Fahrenheit").tag(true)
            }
        } header: {
            Text("Display")
        } footer: {
            Text("Only the chosen coordinates are sent to Open-Meteo.com; refreshed every 15 minutes.")
        }
        Section("Location") {
            LabeledContent("Current", value: settings.location?.name ?? "Not set")
            HStack {
                TextField("Search for a place", text: $query)
                    .onSubmit(search)
                Button(searching ? "Searching…" : "Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            if let error {
                Text(error).foregroundStyle(.orange)
            }
            ForEach(results) { result in
                Button {
                    settings.location = .init(name: result.name, latitude: result.latitude, longitude: result.longitude)
                    results = []
                    query = ""
                } label: {
                    HStack {
                        Text(result.title)
                        Spacer()
                        Text(String(format: "%.2f, %.2f", result.latitude, result.longitude))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        error = nil
        Task { @MainActor in
            defer { searching = false }
            do {
                results = try await WeatherGeocoder.search(text)
                if results.isEmpty { error = "No places found for “\(text)”." }
            } catch {
                self.error = "Search failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct BatterySection: View {
    @Binding var settings: StatusLabPluginSettings.Battery

    var body: some View {
        Section {
            PositionPicker(position: $settings.position)
            Toggle("Show time remaining", isOn: $settings.time)
        } header: {
            Text("Display")
        } footer: {
            Text("Time left on battery, or until full while charging, as estimated by macOS. Green while connected to power; orange at 20% and red at 10% on battery.")
        }
    }
}

private struct ClockSection: View {
    @Binding var settings: StatusLabPluginSettings.Clock

    private static let presets: [(String, String)] = [
        ("Time", "HH:mm"),
        ("Day and time", "EEE HH:mm"),
        ("Date and time", "EEE d MMM yyyy HH:mm"),
        ("Full date and time", "EEEE d MMMM yyyy HH:mm"),
    ]

    private var preview: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(settings.effectiveTemplate)
        return formatter.string(from: Date())
    }

    var body: some View {
        Section {
            PositionPicker(position: $settings.position)
            Picker("Format", selection: $settings.template) {
                ForEach(Self.presets, id: \.1) { preset in
                    Text(preset.0).tag(preset.1)
                }
                if !Self.presets.contains(where: { $0.1 == settings.template }) {
                    Text("Custom").tag(settings.template)
                }
            }
            TextField("Template", text: $settings.template)
                .font(.system(.body, design: .monospaced))
            Toggle("Show seconds", isOn: $settings.seconds)
            LabeledContent("Preview", value: preview)
        } header: {
            Text("Display")
        } footer: {
            Text("Templates use Unicode date symbols (EEE = day, d = day of month, MMM = month, yyyy = year). Order follows your region settings.")
        }
    }
}

private struct TmuxSection: View {
    @Binding var settings: StatusLabPluginSettings.Tmux
    @ObservedObject private var tmux = TmuxPlugin.shared

    var body: some View {
        Section {
            LabeledContent("tmux", value: tmux.tmuxPath ?? "Not installed (brew install tmux)")
            Toggle("Hide tmux's own status line", isOn: $settings.hideStatusBar)
        } header: {
            Text("General")
        } footer: {
            Text("Open a profile by right-clicking a pane or from the Plugins menu (first profile: ⌥⌘T). The tmux server runs on its own, outside Ghostty: quitting Ghostty only detaches, and every session can be attached from any terminal. Their history is saved, so a session that ended with a restart comes back with its last output. Hiding the status line applies only to sessions opened here.")
        }

        ForEach($settings.profiles) { $profile in
            Section {
                TextField("Name", text: $profile.name)
                Toggle("Ask for the start directory", isOn: $profile.askForDirectory)
                TextField(profile.askForDirectory ? "Fallback directory" : "Directory",
                          text: $profile.directory, prompt: Text("~"))
                TextField("Command", text: $profile.command, prompt: Text("claude"))
                    .font(.system(.body, design: .monospaced))
                TextField("Resume command", text: $profile.resumeCommand, prompt: Text("Same as command"))
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Spacer()
                    Button("Open in New Tab") { TmuxPlugin.shared.open(profile, placement: .tab) }
                    Button("Remove", role: .destructive) {
                        settings.profiles.removeAll { $0.id == profile.id }
                    }
                }
            } header: {
                Text("Profile: " + (profile.name.isEmpty ? "Untitled" : profile.name))
            }
        }

        Section {
            Button("Add Profile") {
                let id = "profile-" + String(UUID().uuidString.prefix(4)).lowercased()
                settings.profiles.append(.init(id: id, name: "New profile", command: "$SHELL -l"))
            }
        }

        Section {
            if tmux.running.isEmpty {
                Text("No Status Lab tmux sessions are running.").foregroundStyle(.secondary)
            }
            ForEach(tmux.running) { session in
                HStack {
                    VStack(alignment: .leading) {
                        Text(session.name).font(.system(.body, design: .monospaced))
                        Text("\(session.attached ? "Attached" : "Detached") · \(session.windows) window(s) · started \(session.created.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        TmuxPlugin.shared.copyAttachCommand(session.name)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy “\(TmuxCommand.attachCommand(session: session.name))” to continue it in any terminal")
                    Button("Attach") { TmuxPlugin.shared.attach(session.name) }
                    Button("End", role: .destructive) { TmuxPlugin.shared.kill(session.name) }
                }
            }
        } header: {
            HStack {
                Text("Running sessions")
                Spacer()
                Button("Refresh") { tmux.refreshSessions() }
                    .buttonStyle(.link)
            }
        }
    }
}

/// Settings of an added plugin. Installed packages describe themselves; a plain
/// executable is configured here.
private struct CustomSection: View {
    @Binding var plugin: StatusLabPluginSettings.Custom
    let others: [StatusLabPluginSettings.Custom]
    let remove: () -> Void

    private var duplicate: Bool { others.contains { $0.id == plugin.id } }

    var body: some View {
        if let package = plugin.package {
            Section("Package") {
                LabeledContent("Identifier") {
                    Text(plugin.id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent("Installed in") {
                    HStack {
                        Text((package as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: package)])
                        }
                    }
                }
            }
        } else {
            Section("Executable") {
                TextField("Name", text: Binding(get: { plugin.name ?? "" }, set: { plugin.name = $0 }),
                          prompt: Text(plugin.id))
                TextField("Identifier", text: $plugin.id)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    TextField("Executable", text: $plugin.executable, prompt: Text("/absolute/path/to/plugin"))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { plugin.executable = url.path }
                    }
                }
                if !StatusLabPluginSettings.isValid(plugin) || duplicate {
                    Label("Needs a unique identifier and an absolute executable path.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }

        Section {
            PositionPicker(position: $plugin.position)
            TextField("Arguments", text: Binding(
                get: { plugin.arguments.joined(separator: " ") },
                // Keep empty parts while typing so a space can be entered; the manifest drops them.
                set: { plugin.arguments = $0.split(separator: " ", omittingEmptySubsequences: false).map(String.init) }))
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("Display")
        } footer: {
            Text("Arguments are split on spaces; there is no shell expansion.")
        }

        Section {
            HStack {
                Spacer()
                Button(plugin.package == nil ? "Remove Plugin" : "Uninstall Plugin", role: .destructive, action: remove)
            }
        } footer: {
            Text(plugin.package == nil
                 ? "Removes the plugin from Ghostty when you press Apply. The executable itself is not deleted."
                 : "Removes the plugin and its installed copy when you press Apply.")
        }
    }
}

/// The AI tools of the configuration. Settings stay in the configuration file, as every
/// other Ghostty setting; this page shows what it contains and whether each tool is found.
private struct AISection: View {
    @ObservedObject private var ai = AISessions.shared

    static let example = """
    macos-ai-session = name:Claude Code,command:claude,resume:claude --continue
    macos-ai-session = name:Codex,command:codex,resume:codex resume --last
    """

    var body: some View {
        Section {
            if ai.sessions.isEmpty {
                Text("No AI tools are configured. Add a macos-ai-session line to your configuration.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ai.sessions) { session in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.name).fontWeight(.medium)
                        Text(session.command == session.resume ? session.command
                             : "\(session.command)   ·   after a restart: \(session.resume)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    StateLabel(state: state(session))
                    if ai.installed[session.executable] == false, let install = session.installCommand {
                        Button("Install…") { ToolInstallWindow.show(session) }
                            .help("Runs “\(install)” and shows its progress")
                    }
                }
            }
            ForEach(ai.errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Tools")
                Spacer()
                Button("Check Again") { ai.recheck() }
                    .buttonStyle(.link)
            }
        } footer: {
            Text("Each tool opens in a tmux session in the directory of the pane you right-click, as a split or a new tab. It keeps running when Ghostty quits; after a restart the resume command runs.")
        }

        Section {
            Text(Self.example)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Open Configuration") { (NSApp.delegate as? AppDelegate)?.openConfig(nil) }
                Button("Reload Configuration") { (NSApp.delegate as? AppDelegate)?.reloadConfig(nil) }
                Spacer()
            }
        } header: {
            Text("Configuration")
        } footer: {
            Text("One macos-ai-session line per tool: name is the menu title, command what runs, resume what runs when a saved session comes back after a restart, install how to install it when it is missing (both optional; Claude Code, Codex, Gemini CLI and Aider install with Homebrew by default). Quote a value that contains a comma. Reload the configuration after editing.")
        }
        .onAppear { ai.reload() }
    }

    private func state(_ session: AISession) -> PluginState {
        switch ai.installed[session.executable] {
        case true?: .ready
        case false?: .unavailable("“\(session.executable)” not found")
        case nil: .starting
        }
    }
}
