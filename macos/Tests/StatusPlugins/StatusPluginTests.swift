import Foundation
import Testing
@testable import Ghostty

@Suite
struct StatusPluginTests {
    private let frame = "{\"version\":1,\"widgets\":[{\"id\":\"cpu\",\"label\":\"CPU\",\"value\":\"25%\",\"color\":\"5CC8FF\",\"history\":[0,0.25,1]}]}"

    @Test func partialFramesAndNewestUpdate() throws {
        var decoder = StatusPluginDecoder()
        let bytes = Array(frame.utf8)
        #expect(try decoder.append(Data(bytes.prefix(20))) == nil)
        let remainder = Data(bytes.dropFirst(20)) + Data("\n".utf8)
        #expect(try decoder.append(remainder)?.widgets.first?.value == "25%")
        let combined = frame + "\n" + frame.replacingOccurrences(of: "25%", with: "50%") + "\n"
        #expect(try decoder.append(Data(combined.utf8))?.widgets.first?.value == "50%")
    }

    @Test func oversizedIncompleteRecordIsRejected() {
        var decoder = StatusPluginDecoder()
        #expect(throws: StatusPluginError.self) {
            try decoder.append(Data(repeating: 65, count: StatusPluginDecoder.maximumRecordBytes + 1))
        }
    }

    @Test func rejectsInvalidFrames() {
        for invalid in [
            frame.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            frame.replacingOccurrences(of: "[0,0.25,1]", with: "[-0.1,1.1]"),
            frame.replacingOccurrences(of: "5CC8FF", with: "nothex"),
            frame.replacingOccurrences(of: "CPU", with: "\\u001b[31m"),
            "not json"
        ] {
            #expect(throws: (any Error).self) { try StatusPluginFrame.decode(Data(invalid.utf8)) }
        }
    }

    @Test func rejectsDuplicateWidgets() {
        let widget = "{\"id\":\"cpu\",\"label\":\"CPU\",\"value\":\"25%\",\"color\":\"5CC8FF\"}"
        let json = "{\"version\":1,\"widgets\":[\(widget),\(widget)]}"
        #expect(throws: StatusPluginError.self) { try StatusPluginFrame.decode(Data(json.utf8)) }
    }

    @Test func manifestValidation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let valid = "{\"version\":1,\"plugins\":[{\"id\":\"stats\",\"executable\":\"/usr/bin/true\",\"arguments\":[]}]}"
        try Data(valid.utf8).write(to: path)
        #expect(try StatusPluginManifest.load(path.path).plugins.count == 1)
        for invalid in [valid.replacingOccurrences(of: "/usr/bin/true", with: "true"),
                        valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                        String(repeating: " ", count: 65_537)] {
            try Data(invalid.utf8).write(to: path)
            #expect(throws: (any Error).self) { try StatusPluginManifest.load(path.path) }
        }
    }

    @Test @MainActor func disabledHostDoesNotStartAnything() {
        let host = StatusPluginHost()
        host.start(manifest: nil)
        #expect(host.items.isEmpty)
        #expect(host.errors.isEmpty)
        host.stop()
    }

    @Test @MainActor func failingPluginIsReported() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let manifest = "{\"version\":1,\"plugins\":[{\"id\":\"broken\",\"executable\":\"/usr/bin/false\",\"arguments\":[]}]}"
        try Data(manifest.utf8).write(to: path)
        let host = StatusPluginHost()
        defer { host.stop() }
        host.start(manifest: path.path)
        try await Task.sleep(for: .seconds(2))
        #expect(host.items.isEmpty)
        #expect(host.errors.contains { $0.contains("broken") })
    }

    private func manifest(executable: String, arguments: [String]) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let object: [String: Any] = ["version": 1, "plugins": [
            ["id": "fixture", "executable": executable, "arguments": arguments]
        ]]
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        return path
    }

    @Test @MainActor func validUpdateAndDisable() async throws {
        let path = try manifest(executable: "/bin/sh", arguments: [
            "-c", "printf '%s\\n' \"$1\"; exec /bin/sleep 30", "fixture", frame
        ])
        defer { try? FileManager.default.removeItem(at: path) }
        let host = StatusPluginHost()
        defer { host.stop() }
        host.start(manifest: path.path)
        try await Task.sleep(for: .seconds(2))
        #expect(host.items.first?.widget.value == "25%")
        #expect(host.errors.isEmpty)
        host.start(manifest: nil)
        #expect(host.items.isEmpty)
        #expect(host.errors.isEmpty)
    }

    @Test @MainActor func floodingPluginIsStopped() async throws {
        let path = try manifest(executable: "/usr/bin/yes", arguments: [frame])
        defer { try? FileManager.default.removeItem(at: path) }
        let host = StatusPluginHost()
        defer { host.stop() }
        host.start(manifest: path.path)
        try await Task.sleep(for: .seconds(2))
        #expect(host.items.isEmpty)
        #expect(host.errors.contains { $0.contains("excessive") })
    }

    @Test @MainActor func silentPluginTimesOut() async throws {
        let path = try manifest(executable: "/bin/sleep", arguments: ["30"])
        defer { try? FileManager.default.removeItem(at: path) }
        let host = StatusPluginHost()
        defer { host.stop() }
        host.start(manifest: path.path)
        try await Task.sleep(for: .seconds(12))
        #expect(host.errors.contains { $0.contains("timed out") })
    }
}
