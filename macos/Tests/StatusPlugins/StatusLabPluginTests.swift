import Foundation
import Testing
@testable import Ghostty

struct StatusLabPluginTests {
    let helpers = URL(fileURLWithPath: "/Apps/Lab.app/Contents/Helpers")

    @Test func defaultManifestShipsStatsWeatherAndClock() throws {
        let manifest = StatusLabPluginSettings().manifest(helpers: helpers, interface: "en7", locale: "nl_NL")
        #expect(manifest.plugins.map(\.id) == ["system-stats", "weather", "clock"])
        #expect(manifest.plugins[0].arguments == ["en7", "--graph", "blocks"])
        #expect(manifest.plugins[0].position == "leading")
        #expect(manifest.plugins[1].position == "trailing")
        #expect(manifest.plugins[2].position == "end")
        #expect(manifest.plugins[2].arguments == ["--template", "EEE d MMM yyyy HH:mm", "--locale", "nl_NL"])
        #expect(manifest.plugins.allSatisfy { $0.executable.hasPrefix(helpers.path + "/") })
    }

    @Test func generatedManifestIsAcceptedByTheHost() throws {
        var settings = StatusLabPluginSettings()
        settings.weather.location = .init(name: "Utrecht", latitude: 52.09, longitude: 5.12)
        settings.stats.graphStyle = .lines
        settings.stats.disk = false
        settings.custom = [.init(id: "community", executable: "/usr/local/bin/plugin", arguments: ["--x"])]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(settings.manifest(helpers: helpers, interface: "en0", locale: "en_US")).write(to: file)
        let loaded = try StatusPluginManifest.load(file.path)
        #expect(loaded.plugins.map(\.id) == ["system-stats", "weather", "clock", "community"])
        #expect(loaded.plugins[0].arguments == ["en0", "--graph", "lines", "--no-disk"])
        #expect(loaded.plugins[1].arguments.contains("Utrecht"))
        #expect(loaded.plugins[1].placement == .trailing)
        #expect(loaded.plugins[2].placement == .end)
        #expect(loaded.plugins[3].placement == .leading)
    }

    @Test func duplicateCustomIdsDoNotBreakTheManifest() throws {
        var settings = StatusLabPluginSettings()
        settings.custom = [.init(id: "dup", executable: "/bin/echo", arguments: ["a", "", "b"]),
                           .init(id: "dup", executable: "/bin/cat")]
        let manifest = settings.manifest(helpers: helpers, interface: "en0", locale: "en")
        #expect(manifest.plugins.filter { $0.id == "dup" }.count == 1)
        #expect(manifest.plugins.last?.arguments == ["a", "b"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(manifest).write(to: file)
        #expect(try StatusPluginManifest.load(file.path).plugins.count == 4)
    }

    @Test func invalidCustomPluginsAreSkippedAndTotalIsCapped() {
        var settings = StatusLabPluginSettings()
        settings.custom = [
            .init(id: "clock", executable: "/bin/echo"),       // reserved id
            .init(id: "relative", executable: "bin/echo"),     // not absolute
            .init(id: "off", executable: "/bin/echo", enabled: false),
        ] + (1...10).map { .init(id: "p\($0)", executable: "/bin/echo") }
        let ids = settings.manifest(helpers: helpers, interface: "en0", locale: "en").plugins.map(\.id)
        #expect(ids.count == 8)
        #expect(!ids.contains("relative") && !ids.contains("off") && ids.filter { $0 == "clock" }.count == 1)
    }

    @Test func legacyCPUGraphSettingIsKept() throws {
        let json = #"{"stats":{"cpuGraph":"sparkline"}}"#
        let settings = try JSONDecoder().decode(StatusLabPluginSettings.self, from: Data(json.utf8))
        #expect(settings.stats.graphStyle == .lines)
        let fresh = try JSONDecoder().decode(StatusLabPluginSettings.self, from: Data("{}".utf8))
        #expect(fresh.stats.graphStyle == .blocks)
    }

    @Test func symbolsAreNamesOnly() throws {
        func frame(_ symbol: String) -> Data {
            Data(#"{"version":1,"widgets":[{"id":"w","label":"","value":"11°C","color":"C0C5CE","symbol":"\#(symbol)"}]}"#.utf8)
        }
        #expect(try StatusPluginFrame.decode(frame("cloud.sun.fill")).widgets[0].symbol == "cloud.sun.fill")
        #expect(throws: StatusPluginError.self) { try StatusPluginFrame.decode(frame("../etc/passwd")) }
        #expect(throws: StatusPluginError.self) { try StatusPluginFrame.decode(frame("Cloud Sun")) }
    }

    @Test func barColorsMustMatchBars() throws {
        func frame(_ colors: String) -> Data {
            Data(#"{"version":1,"widgets":[{"id":"cpu","label":"CPU","value":"1%","color":"5CC8FF","bars":[0.1,0.2],"barColors":\#(colors)}]}"#.utf8)
        }
        #expect(try StatusPluginFrame.decode(frame(#"["5CC8FF","2DD4BF"]"#)).widgets[0].barColors?.count == 2)
        #expect(throws: StatusPluginError.self) { try StatusPluginFrame.decode(frame(#"["5CC8FF"]"#)) }
        #expect(throws: StatusPluginError.self) { try StatusPluginFrame.decode(frame(#"["5CC8FF","red"]"#)) }
    }

    @Test func savedProfilesWithoutNewFieldsStillLoad() throws {
        let json = #"{"tmux":{"profiles":[{"id":"claude","name":"Claude","directory":"~","command":"claude","resumeCommand":"claude --continue"}]}}"#
        let settings = try JSONDecoder().decode(StatusLabPluginSettings.self, from: Data(json.utf8))
        #expect(settings.tmux.profiles.count == 1)
        #expect(settings.tmux.profiles[0].askForDirectory)
        #expect(settings.tmux.profiles[0].effectiveResumeCommand == "claude --continue")
    }

    @Test func olderSettingsDecodeWithDefaults() throws {
        let json = #"{"stats":{"enabled":false},"tmux":{"profiles":[]}}"#
        let settings = try JSONDecoder().decode(StatusLabPluginSettings.self, from: Data(json.utf8))
        #expect(!settings.stats.enabled)
        #expect(settings.stats.interface == "auto")
        #expect(settings.clock.enabled)
        #expect(settings.tmux.enabled && settings.tmux.profiles.isEmpty)
    }

    @Test func barsAndPositionAreValidated() throws {
        let valid = #"{"version":1,"widgets":[{"id":"cpu","label":"CPU","value":"1%","color":"5CC8FF","bars":[0,0.5,1]}]}"#
        #expect(try StatusPluginFrame.decode(Data(valid.utf8)).widgets[0].bars == [0, 0.5, 1])
        let outOfRange = #"{"version":1,"widgets":[{"id":"cpu","label":"CPU","value":"1%","color":"5CC8FF","bars":[1.5]}]}"#
        #expect(throws: StatusPluginError.self) { try StatusPluginFrame.decode(Data(outOfRange.utf8)) }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"version":1,"plugins":[{"id":"a","executable":"/bin/echo","arguments":[],"position":"middle"}]}"#.utf8)
            .write(to: file)
        #expect(throws: StatusPluginError.self) { try StatusPluginManifest.load(file.path) }
    }

    // MARK: tmux

    /// A package folder with a plugin.json and an executable script.
    func package(_ json: [String: Any], script: String? = "#!/bin/sh\n") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("plugin.json"))
        if let script {
            let file = folder.appendingPathComponent("run.sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return folder
    }

    let validPackage: [String: Any] = ["id": "battery", "name": "Battery", "version": "1.0.0",
                                       "description": "Charge", "author": "Me", "executable": "run.sh",
                                       "position": "trailing", "protocol": 1,
                                       "homepage": "https://example.com/battery"]

    @Test func pluginPackagesLoadIntoPluginEntries() throws {
        let folder = try package(validPackage)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plugin = try PluginPackage.load(folder).plugin(installedAt: folder)
        #expect(plugin.id == "battery")
        #expect(plugin.displayName == "Battery")
        #expect(plugin.executable == folder.appendingPathComponent("run.sh").path)
        #expect(plugin.position == .trailing)
        #expect(plugin.package == folder.path)
        #expect(StatusLabPluginSettings.isValid(plugin))
        // The descriptive fields survive saving and loading the settings.
        var settings = StatusLabPluginSettings()
        settings.custom = [plugin]
        let decoded = try JSONDecoder().decode(StatusLabPluginSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.custom.first?.summary == "Charge")
        #expect(decoded.custom.first?.package == folder.path)
    }

    @Test func pluginPackagesAreValidated() throws {
        func failure(_ change: [String: Any], script: String? = "#!/bin/sh\n") throws -> PluginPackage.Failure? {
            let folder = try package(validPackage.merging(change) { $1 }, script: script)
            defer { try? FileManager.default.removeItem(at: folder) }
            do { _ = try PluginPackage.load(folder); return nil } catch let error as PluginPackage.Failure { return error }
        }
        #expect(try failure([:]) == nil)
        #expect(try failure(["id": "Bad Id"]) != nil)
        #expect(try failure(["id": "clock"]) != nil)
        #expect(try failure(["executable": "../run.sh"]) != nil)
        #expect(try failure(["executable": "/bin/sh"]) != nil)
        #expect(try failure(["executable": "missing.sh"]) != nil)
        #expect(try failure(["protocol": 2]) != nil)
        #expect(try failure(["homepage": "http://example.com"]) != nil)
        #expect(try failure(["position": "middle"]) != nil)
        #expect(try failure([:], script: nil) != nil)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: PluginPackage.Failure.missingManifest) { try PluginPackage.load(empty) }
    }

    @Test func executablesOutsideThePackageAreRejectedThroughLinks() throws {
        let folder = try package(validPackage.merging(["executable": "link"]) { $1 }, script: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"),
                                                   withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        #expect(throws: PluginPackage.Failure.self) { try PluginPackage.load(folder) }
    }

    @Test func bundledExamplePackageIsValid() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../examples/status-plugins/packages/battery").standardizedFileURL
        let package = try PluginPackage.load(folder)
        #expect(package.id == "battery")
    }

    @Test func pluginLimitIsReported() {
        var settings = StatusLabPluginSettings()
        settings.custom = (1...7).map { .init(id: "p\($0)", executable: "/bin/p\($0)") }
        #expect(!StatusLabPluginSettings.limitReached(draft: settings, id: "p5"))
        #expect(StatusLabPluginSettings.limitReached(draft: settings, id: "p6"))
        #expect(!StatusLabPluginSettings.limitReached(draft: settings, id: "unknown"))
    }

    @Test func tmuxSessionNamesAreSafe() {
        let name = TmuxCommand.newSessionName(profile: "My Claude!")
        #expect(name.hasPrefix("ghostty-my-claude--"))
        #expect(TmuxCommand.isValidSessionName(name))
        #expect(!TmuxCommand.isValidSessionName("bad;name"))
        #expect(!TmuxCommand.isValidSessionName("a b"))
        #expect(!TmuxCommand.isValidSessionName(""))
    }

    @Test func tmuxCommandAttachesOrCreatesAndSurvivesQuotes() throws {
        let command = TmuxCommand.surfaceCommand(tmux: "/opt/homebrew/bin/tmux", shell: "/bin/zsh",
                                                 session: "ghostty-claude-ab12", directory: "/Users/me/it's here",
                                                 command: "claude --continue")
        #expect(command.hasPrefix("/bin/sh -c "))
        // Unwrap the quoting layers like the shells would and check the final script.
        let outer = try #require(Self.unquote(String(command.dropFirst("/bin/sh -c ".count))))
        // The login shell only runs a fish-compatible exec of /bin/sh with the script.
        #expect(outer.hasSuffix(" exec '/bin/zsh' -lic 'exec /bin/sh -c \"$GHOSTTY_TMUX_SCRIPT\"'"))
        let script = try #require(Self.script(of: command))
        #expect(script.contains("has-session -t '=ghostty-claude-ab12'"))
        #expect(script.contains("attach-session -t '=ghostty-claude-ab12'"))
        #expect(script.contains("-c '/Users/me/it'\"'\"'s here'"))
        #expect(script.contains("'claude --continue; exec '\"'\"'/bin/zsh'\"'\"' -l'"))
    }

    @Test func tmuxStatusBarIsHiddenOnlyForThisSession() throws {
        let command = TmuxCommand.surfaceCommand(tmux: "tmux", shell: "/bin/zsh", session: "ghostty-a-1",
                                                 directory: "/tmp", command: "claude", hideStatus: true)
        let script = try #require(Self.script(of: command))
        #expect(script.contains("'tmux' set-option -t '=ghostty-a-1:' status off 2>/dev/null; exec 'tmux' attach-session"))
        #expect(script.contains("' ';' set-option status off; fi"))
        #expect(!script.contains("-g"))
        let plain = TmuxCommand.surfaceCommand(tmux: "tmux", shell: "/bin/zsh", session: "ghostty-a-1",
                                               directory: "/tmp", command: "claude")
        #expect(!plain.contains("status off"))
    }

    @Test func tmuxPanesRoundTripInSnapshotsAndOldSnapshotsStillLoad() throws {
        let tmux = TmuxPane(session: "ghostty-claude-ab12", profile: "claude", directory: "/tmp",
                            resumeCommand: "claude --continue")
        var pane = SessionSnapshot.Pane(id: UUID(), directory: "/tmp", title: "claude", customTitle: false,
                                        fontSize: 14, transcript: "")
        pane.tmux = tmux
        let snapshot = SessionSnapshot(windows: [.init(group: 0, selected: true, key: true, frame: [0, 0, 800, 600],
                                                       fullscreen: false, tree: .pane(pane))])
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        try decoded.validate()
        #expect(decoded.windows[0].tree.panes[0].tmux == tmux)

        pane.tmux = nil
        let old = SessionSnapshot(windows: [.init(group: 0, selected: true, key: true, frame: [0, 0, 800, 600],
                                                  fullscreen: false, tree: .pane(pane))])
        var json = try #require(String(data: JSONEncoder().encode(old), encoding: .utf8))
        json = json.replacingOccurrences(of: ",\"tmux\":null", with: "")
        #expect(try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)).windows[0].tree.panes[0].tmux == nil)

        pane.tmux = TmuxPane(session: "x;rm -rf ~", profile: "claude", directory: "/tmp", resumeCommand: "claude")
        let unsafe = SessionSnapshot(windows: [.init(group: 0, selected: true, key: true, frame: [0, 0, 800, 600],
                                                     fullscreen: false, tree: .pane(pane))])
        #expect(throws: SessionStore.Failure.self) { try unsafe.validate() }
    }

    @Test func tmuxDirectoriesExpandHome() {
        #expect(TmuxCommand.expand(directory: "~", home: "/Users/me") == "/Users/me")
        #expect(TmuxCommand.expand(directory: "~/code", home: "/Users/me") == "/Users/me/code")
        #expect(TmuxCommand.expand(directory: "/srv", home: "/Users/me") == "/srv")
    }

    /// The /bin/sh script a surface command hands to the login shell, as /bin/sh sees it.
    static func script(of command: String) -> String? {
        guard let outer = unquote(String(command.dropFirst("/bin/sh -c ".count))),
              let exec = outer.range(of: " exec '/bin/zsh' -lic ", options: .backwards) else { return nil }
        return run("/bin/sh", ["-c", outer[..<exec.lowerBound] + "; printf %s \"$GHOSTTY_TMUX_SCRIPT\""])
    }

    /// Lets a real shell remove one level of quoting from a single quoted word.
    static func unquote(_ word: String) -> String? {
        run("/bin/sh", ["-c", "printf %s " + word])
    }

    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
