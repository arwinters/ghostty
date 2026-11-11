import AppKit
import Foundation

/// Status Lab packaging only; copied into the app by build.py and never part of a normal
/// Ghostty build. Gives the app its own configuration, generates the plugin manifest, and
/// seeds the defaults on first launch so it can run beside an installed Ghostty.
enum StatusLabBootstrap {
    static let aiSessions = """

    # AI sessions in the right-click menu (New AI Session). One line per tool:
    #   name:<title in the menu>,command:<what runs>,resume:<what runs after a restart>
    # Each opens in a tmux session in the pane's directory. Remove a line to drop a tool;
    # "macos-ai-session =" on its own removes all of them.
    macos-ai-session = name:Claude Code,command:claude,resume:claude --continue
    macos-ai-session = name:Codex,command:codex,resume:codex resume --last

    """

    static func prepare() -> String {
        do {
            let manager = FileManager.default
            // Application Support/<bundle identifier>: separate from a normal Ghostty install.
            let support = PluginManager.supportDirectory
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
            // The Plugin Manager owns the plugin choices and writes the manifest.
            try PluginManager.writeManifest(PluginManager.loadSettings())
            let manifest = PluginManager.manifestFile
            let runtime = support.appendingPathComponent("runtime.generated.config")
            try "macos-status-plugins = \(manifest.path)\n".write(to: runtime, atomically: true, encoding: .utf8)
            let config = support.appendingPathComponent("config.ghostty")
            if !manager.fileExists(atPath: config.path) {
                let defaults = try String(contentsOf: resources.appendingPathComponent("status-lab-defaults.config"), encoding: .utf8)
                try (defaults + "\n# Generated plugin paths for this copy of the app\nconfig-file = \(runtime.path)\n")
                    .write(to: config, atomically: true, encoding: .utf8)
            }
            // Migrate only what earlier Status Lab builds wrote: fixed titles, and (once)
            // window-save-state = never, which predates the Session Manager. Afterwards
            // "never" is the user's way to turn session restore off and must stay.
            var contents = try String(contentsOf: config, encoding: .utf8)
            let original = contents
            let saveStateKey = "StatusLabMigratedWindowSaveState"
            if !UserDefaults.standard.bool(forKey: saveStateKey) {
                contents = contents.replacingOccurrences(of: "window-save-state = never", with: "window-save-state = always")
                UserDefaults.standard.set(true, forKey: saveStateKey)
            }
            // Once: offer the AI sessions of 0.9.2 to existing configurations as well.
            let aiKey = "StatusLabMigratedAISessions"
            if !UserDefaults.standard.bool(forKey: aiKey) {
                if !contents.contains("macos-ai-session") { contents += Self.aiSessions }
                UserDefaults.standard.set(true, forKey: aiKey)
            }
            let migrated = contents.components(separatedBy: "\n").filter {
                !["title = Ghostty Status Lab", "title = Ghostty Dev Version"].contains(
                    $0.trimmingCharacters(in: .whitespaces))
            }.joined(separator: "\n")
            if migrated != original {
                try migrated.write(to: config, atomically: true, encoding: .utf8)
            }
            return config.path
        } catch {
            let alert = NSAlert()
            alert.messageText = "Ghostty Status Lab could not prepare its configuration"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }
}
