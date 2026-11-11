import Foundation
import Testing
@testable import Ghostty

struct SessionTests {
    func fixture() -> SessionSnapshot {
        let pane = SessionSnapshot.Pane(id: UUID(), directory: "/tmp", title: "API", customTitle: true,
                                        fontSize: 14, transcript: "previous output\n")
        return .init(windows: [.init(group: 0, selected: true, key: true, frame: [10, 20, 800, 600],
                                    fullscreen: false, focused: pane.id, tree: .pane(pane))])
    }
    func store() -> SessionStore {
        .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    @Test func corruptLatestFallsBackToValidCheckpoint() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let snapshot = fixture()
        try store.save(snapshot)
        try Data("{truncated".utf8).write(to: store.directory.appendingPathComponent("damaged.json"))
        let loaded = try store.list()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == snapshot.id)
        #expect(loaded.first?.windows.first?.tree.panes.first?.transcript == "previous output\n")
    }
    @Test func rejectEmptyAndFutureSnapshotsWithoutOverwriting() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let valid = fixture()
        try store.save(valid)
        var future = fixture(); future.version = 99
        #expect(throws: SessionStore.Failure.self) { try store.save(future) }
        #expect(throws: SessionStore.Failure.self) { try store.save(SessionSnapshot(windows: [])) }
        #expect(try store.list().map(\.id) == [valid.id])
    }
    @Test func retentionPreservesNamedWorkspacesAndPrivatePermissions() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var named = fixture(); named.name = "Backend"
        try store.save(named)
        for number in 0..<25 {
            var value = fixture(); value.date = Date().addingTimeInterval(Double(number))
            try store.save(value)
        }
        let list = try store.list()
        #expect(list.count == 21)
        #expect(list.contains { $0.id == named.id })
        let permissions = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }
    @Test func roundTripSplitRatioFocusAndWindowMetadata() throws {
        var value = fixture()
        let first = value.windows[0].tree
        var pane = first.panes[0]; pane.id = UUID(); pane.title = "DB"
        value.windows[0].tree = .split(horizontal: true, ratio: 0.37, left: first, right: .pane(pane))
        value.windows[0].fullscreen = true
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(value))
        try decoded.validate()
        #expect(decoded.paneCount == 2)
        #expect(decoded.windows[0].focused == value.windows[0].focused)
        guard case .split(_, let ratio, _, _) = decoded.windows[0].tree else { Issue.record("Lost split"); return }
        #expect(ratio == 0.37)
        #expect(decoded.windows[0].fullscreen)
    }
    @Test func replayIsBoundedAndDoesNotContainControlSequences() {
        let text = SessionSnapshot.safeTranscript(String(repeating: "x", count: 140_000) + "\u{1b}]52;clipboard\u{07}\n")
        #expect(text.count <= 131_072)
        #expect(!text.contains("\u{1b}"))
        #expect(!text.contains("\u{07}"))
        #expect(SessionSnapshot.shellQuote("a'b$(touch /tmp/no)") == "'a'\"'\"'b$(touch /tmp/no)'")
    }
    @Test func rejectDuplicatePaneIDs() throws {
        var value = fixture()
        let pane = value.windows[0].tree
        value.windows[0].tree = .split(horizontal: false, ratio: 0.5, left: pane, right: pane)
        #expect(throws: SessionStore.Failure.self) { try value.validate() }
    }

    @Test func transcriptLimitHoldsForMultiScalarCharacters() throws {
        // One Character made of many scalars: counting Characters let the UTF-8 size exceed
        // the validation limit, so every later checkpoint failed and an older one was restored.
        let family = "👨‍👩‍👧‍👦"
        let text = SessionSnapshot.safeTranscript(String(repeating: family, count: 40_000))
        #expect(text.unicodeScalars.count <= SessionSnapshot.transcriptLimit)
        var value = fixture()
        guard case .pane(var pane) = value.windows[0].tree else { Issue.record("No pane"); return }
        pane.transcript = text
        value.windows[0].tree = .pane(pane)
        try value.validate()
    }
    @Test func oddDirectoriesAreDroppedInsteadOfFailingTheCheckpoint() {
        #expect(SessionSnapshot.safeDirectory("/Users/me/project") == "/Users/me/project")
        #expect(SessionSnapshot.safeDirectory("") == nil)
        #expect(SessionSnapshot.safeDirectory("~/project") == nil)
        #expect(SessionSnapshot.safeDirectory("file://host/tmp") == nil)
        #expect(SessionSnapshot.safeDirectory(nil) == nil)
    }
    @Test func summariesAreIndexedAndDeletesKeepTheIndexCurrent() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var first = fixture(); first.date = Date(timeIntervalSinceNow: -60)
        let second = fixture()
        try store.save(first)
        try store.save(second)
        #expect(store.summaries().map(\.id) == [second.id, first.id])
        try store.delete(second.id)
        #expect(store.summaries().map(\.id) == [first.id])
        // A fresh store reads the same index from disk.
        #expect(SessionStore(directory: store.directory).summaries().map(\.id) == [first.id])
        #expect(try store.load(first.id).windows.first?.tree.panes.first?.transcript == "previous output\n")
        #expect(throws: SessionStore.Failure.self) { try store.load(second.id) }
    }
    @Test func summaryDescribesPlacesAndTmuxProfiles() {
        var value = fixture()
        let shell = value.windows[0].tree
        let tmux = SessionSnapshot.Pane(id: UUID(), directory: nil, title: "👻", customTitle: false, fontSize: 14,
                                        transcript: "", tmux: TmuxPane(session: "ghostty-claude-ab12", profile: "claude",
                                                                       directory: "/Users/me/fitrelay", resumeCommand: "claude --continue"))
        value.windows[0].tree = .split(horizontal: true, ratio: 0.5, left: shell, right: .pane(tmux))
        let summary = value.summary
        #expect(summary.places == ["tmp", "fitrelay"])
        #expect(summary.profiles == ["claude"])
        #expect(summary.tmuxPanes == 1)
        #expect(summary.matches("FITRELAY"))
        #expect(summary.matches("ab12"))
        #expect(!summary.matches("nothing-like-this"))
        var other = value; other.id = UUID(); other.date = .distantPast
        #expect(other.summary.hasSameContent(as: summary))
    }
    @Test func tmuxShellDetection() {
        #expect(TmuxPlugin.isShell("zsh"))
        #expect(TmuxPlugin.isShell("-zsh"))
        #expect(TmuxPlugin.isShell("/bin/bash"))
        #expect(!TmuxPlugin.isShell("claude"))
        #expect(!TmuxPlugin.isShell("node"))
        #expect(!TmuxPlugin.isShell("vim"))
    }
}
