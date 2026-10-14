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
}
