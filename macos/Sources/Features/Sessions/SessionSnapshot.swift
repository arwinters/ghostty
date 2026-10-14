import Foundation

/// Value-only snapshots can be validated without creating shells or windows.
struct SessionSnapshot: Codable, Identifiable {
    var version = 1
    var id = UUID()
    var date = Date()
    var name: String?
    var windows: [Window]

    struct Window: Codable {
        var group: Int
        var selected: Bool
        var key: Bool
        var frame: [Double]
        var fullscreen: Bool
        var title: String?
        var tabColor: String?
        var focused: UUID?
        var zoomed: UUID?
        var tree: Node
    }

    indirect enum Node: Codable {
        case pane(Pane)
        case split(horizontal: Bool, ratio: Double, left: Node, right: Node)

        var panes: [Pane] {
            switch self {
            case .pane(let pane): return [pane]
            case .split(_, _, let left, let right): return left.panes + right.panes
            }
        }

        func validate(depth: Int = 0) throws {
            guard depth < 32 else { throw SessionStore.Failure.invalidSnapshot }
            switch self {
            case .pane(let pane):
                guard pane.transcript.utf8.count <= 524_288,
                      pane.fontSize.isFinite, pane.fontSize >= 0, pane.fontSize <= 512,
                      pane.directory?.hasPrefix("/") != false,
                      pane.tmux?.isValid != false else { throw SessionStore.Failure.invalidSnapshot }
            case .split(_, let ratio, let left, let right):
                guard ratio.isFinite, ratio > 0, ratio < 1 else { throw SessionStore.Failure.invalidSnapshot }
                try left.validate(depth: depth + 1)
                try right.validate(depth: depth + 1)
            }
        }
    }

    struct Pane: Codable {
        var id: UUID
        var directory: String?
        var title: String
        var customTitle: Bool
        var fontSize: Float
        var transcript: String
        /// Set for panes opened by the tmux plugin; absent in older snapshots.
        var tmux: TmuxPane?
    }

    var paneCount: Int { windows.reduce(0) { $0 + $1.tree.panes.count } }

    /// Saved automatically at launch, before the previous session replaces the windows.
    static let recoveryPrefix = "Before launch "
    var isRecoveryPoint: Bool { name?.hasPrefix(Self.recoveryPrefix) == true }

    func validate() throws {
        guard version == 1, !windows.isEmpty, windows.count <= 64,
              paneCount <= 128 else { throw SessionStore.Failure.invalidSnapshot }
        var ids = Set<UUID>()
        for window in windows {
            guard window.frame.count == 4, window.frame.allSatisfy({ $0.isFinite }),
                  window.frame[2] > 0, window.frame[3] > 0 else { throw SessionStore.Failure.invalidSnapshot }
            try window.tree.validate()
            for pane in window.tree.panes {
                guard ids.insert(pane.id).inserted else { throw SessionStore.Failure.invalidSnapshot }
            }
        }
    }

    /// Plain terminal text only: never replay escape/control sequences from a saved session.
    static func safeTranscript(_ text: String) -> String {
        let tail = String(text.suffix(131_072))
        return String(tail.unicodeScalars.filter { $0.value == 10 || $0.value == 9 || $0.value >= 32 && !((127...159).contains($0.value)) })
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// Immutable files plus atomic publication retain the previous valid checkpoint after a failed write.
struct SessionStore {
    enum Failure: Error { case invalidSnapshot, tooLarge }
    let directory: URL

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func save(_ snapshot: SessionSnapshot) throws {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 32 * 1024 * 1024 else { throw Failure.tooLarge }
        try prepare()
        let file = directory.appendingPathComponent(snapshot.id.uuidString + ".json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Named sessions are never pruned automatically.
        for old in try list().filter({ $0.name == nil }).dropFirst(20) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(old.id.uuidString + ".json"))
        }
    }

    func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }

    func list() throws -> [SessionSnapshot] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .compactMap { file -> SessionSnapshot? in
                // A damaged/latest checkpoint must not hide earlier valid checkpoints.
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 32 * 1024 * 1024,
                      let data = try? Data(contentsOf: file),
                      let value = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
                      (try? value.validate()) != nil else { return nil }
                return value
            }.sorted { $0.date > $1.date }
    }
}
