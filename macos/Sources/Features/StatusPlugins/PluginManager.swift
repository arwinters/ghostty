import AppKit
import SwiftUI

/// Owns the Status Lab plugin choices: stores them, writes the generated manifest the status
/// bars load, and offers the Plugin Manager window and Plugins menu.
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    /// The saved settings. Edit a copy in the UI and `apply` it.
    @Published private(set) var settings: StatusLabPluginSettings
    @Published private(set) var message: String?

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
    }

    private func rebuildMenu() {
        guard let menu = menuItem?.submenu else { return }
        menu.removeAllItems()
        let manager = NSMenuItem(title: "Plugin Manager…", action: #selector(showManagerFromMenu), keyEquivalent: "p")
        manager.keyEquivalentModifierMask = [.command, .option]
        manager.target = self
        menu.addItem(manager)

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

    func showManager() {
        if panel == nil {
            panel = ManagerWindow.make(title: "Plugin Manager", autosave: "StatusLabPluginManager",
                                       rootView: PluginManagerView(manager: self))
        }
        message = nil
        TmuxPlugin.shared.refreshSessions()
        panel?.makeKeyAndOrderFront(nil)
    }
}

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

private struct PluginManagerView: View {
    @ObservedObject var manager: PluginManager
    @State private var draft: StatusLabPluginSettings
    @State private var selection: Section = .stats

    enum Section: String, CaseIterable, Identifiable {
        case stats, weather, clock, tmux, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .stats: "System Stats"
            case .weather: "Weather"
            case .clock: "Clock"
            case .tmux: "tmux"
            case .custom: "Community Plugins"
            }
        }

        var symbol: String {
            switch self {
            case .stats: "cpu"
            case .weather: "cloud.sun"
            case .clock: "clock"
            case .tmux: "rectangle.split.3x1"
            case .custom: "puzzlepiece.extension"
            }
        }
    }

    init(manager: PluginManager) {
        self.manager = manager
        _draft = State(initialValue: manager.settings)
    }

    var body: some View {
        ManagerLayout(pages: Section.allCases, selection: $selection, row: row) { section in
            switch section {
            case .stats: StatsSection(settings: $draft.stats)
            case .weather: WeatherSection(settings: $draft.weather)
            case .clock: ClockSection(settings: $draft.clock)
            case .tmux: TmuxSection(settings: $draft.tmux)
            case .custom: CustomSection(plugins: $draft.custom)
            }
        } footer: {
            Text(manager.message ?? "Changes apply to every window when you press Apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { draft = manager.settings }
                .disabled(draft == manager.settings)
            Button("Apply") { manager.apply(draft) }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == manager.settings)
        }
    }

    private func row(_ section: Section) -> ManagerLayoutRow {
        .init(title: section.title, symbol: section.symbol, badge: isEnabled(section) ? nil : "Off")
    }

    private func isEnabled(_ section: Section) -> Bool {
        switch section {
        case .stats: draft.stats.enabled
        case .weather: draft.weather.enabled
        case .clock: draft.clock.enabled
        case .tmux: draft.tmux.enabled
        case .custom: draft.custom.contains { $0.enabled }
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
            Toggle("Show system stats", isOn: $settings.enabled)
            PositionPicker(position: $settings.position)
        } footer: {
            Text("CPU, memory, network and disk measured on this Mac. Nothing leaves the computer.")
        }
        Section {
            Picker("Graph style", selection: $settings.graphStyle) {
                Text("Blocks (compact)").tag(StatusLabPluginSettings.Stats.GraphStyle.blocks)
                Text("Lines").tag(StatusLabPluginSettings.Stats.GraphStyle.lines)
            }
            Toggle("Show disk space and disk activity", isOn: $settings.disk)
        } footer: {
            Text(settings.graphStyle == .blocks
                 ? "CPU: one block per core, performance cores blue and efficiency cores teal. Memory, network and disk: the last 12 seconds. Disk space: a filled meter."
                 : "Line graphs of the last 60 seconds.")
        }
        Section {
            TextField("Network interface", text: $settings.interface, prompt: Text("auto"))
        } footer: {
            Text("Use “auto” for the interface of the default route, or a name such as en0.")
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
            Toggle("Show weather", isOn: $settings.enabled)
            PositionPicker(position: $settings.position)
            Picker("Units", selection: $settings.fahrenheit) {
                Text("Celsius").tag(false)
                Text("Fahrenheit").tag(true)
            }
        } footer: {
            Text("Weather data by Open-Meteo.com. Only the chosen coordinates are sent; refreshed every 15 minutes.")
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
            Toggle("Show clock", isOn: $settings.enabled)
            PositionPicker(position: $settings.position)
        }
        Section {
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
            Toggle("Enable tmux panes", isOn: $settings.enabled)
            Toggle("Hide tmux status bar", isOn: $settings.hideStatusBar)
            LabeledContent("tmux", value: tmux.tmuxPath ?? "Not installed (brew install tmux)")
        } footer: {
            Text("Open a profile by right-clicking a pane or from the Plugins menu (first profile: ⌥⌘T). Detach with Ctrl-b d or Detach Session in the pane menu; the session keeps running. Sessions survive a Ghostty crash and are reattached on restore; after a restart the resume command recreates them. Hiding the status bar applies only to sessions opened here.")
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
                Text(profile.name.isEmpty ? "Profile" : profile.name)
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

private struct CustomSection: View {
    @Binding var plugins: [StatusLabPluginSettings.Custom]

    var body: some View {
        Section {
            Text("Any executable that writes status protocol v1 to stdout can be added. Plugins run as normal processes with your permissions; only add programs you trust.")
                .foregroundStyle(.secondary)
        }
        // Indexed: the identifier itself is editable, so it cannot be the row identity.
        ForEach(plugins.indices, id: \.self) { index in
            let plugin = $plugins[index]
            Section {
                Toggle("Enabled", isOn: plugin.enabled)
                TextField("Identifier", text: plugin.id)
                HStack {
                    TextField("Executable", text: plugin.executable, prompt: Text("/absolute/path/to/plugin"))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { plugin.wrappedValue.executable = url.path }
                    }
                }
                TextField("Arguments", text: Binding(
                    get: { plugin.wrappedValue.arguments.joined(separator: " ") },
                    set: { plugin.wrappedValue.arguments = $0.split(separator: " ").map(String.init) }))
                PositionPicker(position: plugin.position)
                if !StatusLabPluginSettings.isValid(plugin.wrappedValue) {
                    Text("Needs a unique identifier and an absolute executable path.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Remove", role: .destructive) { plugins.remove(at: index) }
                }
            } header: {
                Text(plugin.wrappedValue.id.isEmpty ? "Plugin" : plugin.wrappedValue.id)
            }
        }
        Section {
            Button("Add Plugin") {
                plugins.append(.init(id: "plugin-\(plugins.count + 1)", executable: ""))
            }
        } footer: {
            Text("At most eight plugins run at the same time, built-in ones included. Arguments are split on spaces; no shell expansion.")
        }
    }
}
