import Foundation

/// Value-only snapshots can be validated without creating shells or windows.
struct SessionSnapshot: Codable, Identifiable {
    var version = 1
    var id = UUID()
    var date = Date()
    var name: String?
    var windows: [Window]
    /// The workspace an automatic checkpoint belongs to; nil in workspaces themselves,
    /// in recovery points of older builds and in checkpoints of older builds.
    var workspace: UUID?

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

        /// The same tree without saved output: used to notice layout changes cheaply.
        var withoutTranscripts: Node {
            switch self {
            case .pane(var pane):
                pane.transcript = ""
                return .pane(pane)
            case .split(let horizontal, let ratio, let left, let right):
                return .split(horizontal: horizontal, ratio: ratio,
                              left: left.withoutTranscripts, right: right.withoutTranscripts)
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

        /// Where the pane was working: tmux tracks its own directory.
        var location: String? { tmux?.directory ?? directory }
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

    /// Characters of output kept per pane. Counted in Unicode scalars, so the UTF-8 size
    /// never exceeds the 512 KiB that `validate` allows (at most 4 bytes per scalar).
    static let transcriptLimit = 131_072

    /// Plain terminal text only: never replay escape/control sequences from a saved session.
    static func safeTranscript(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        // Only the tail is kept; skip the part of a long text that cannot be part of it.
        for scalar in text.unicodeScalars.suffix(transcriptLimit * 2)
        where scalar.value == 10 || scalar.value == 9 || scalar.value >= 32 && !((127...159).contains(scalar.value)) {
            scalars.append(scalar)
        }
        return String(scalars.suffix(transcriptLimit))
    }

    /// A directory reported by a shell, or nil when it is not an absolute local path. One
    /// odd report (for example from a remote host) must never invalidate a whole checkpoint.
    static func safeDirectory(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 4096, !value.contains("\0") else { return nil }
        return value
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    var summary: Summary { Summary(self) }

    /// What the Session Manager lists. Holding summaries instead of full snapshots keeps
    /// saved output out of memory until a snapshot is actually restored.
    struct Summary: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let name: String?
        let windows: Int
        let tabs: [Tab]
        let panes: Int
        let tmuxPanes: Int
        let workspace: UUID?

        struct Tab: Equatable {
            let title: String?
            let group: Int
            let panes: [PaneInfo]
        }

        struct PaneInfo: Equatable {
            let location: String?
            let title: String
            let tmuxSession: String?
            let profile: String?
        }

        init(_ snapshot: SessionSnapshot) {
            id = snapshot.id
            date = snapshot.date
            name = snapshot.name
            windows = Set(snapshot.windows.map(\.group)).count
            tabs = snapshot.windows.map { window in
                Tab(title: window.title, group: window.group, panes: window.tree.panes.map {
                    PaneInfo(location: $0.location, title: $0.title,
                             tmuxSession: $0.tmux?.session, profile: $0.tmux?.profile)
                })
            }
            panes = snapshot.paneCount
            tmuxPanes = snapshot.windows.flatMap { $0.tree.panes }.filter { $0.tmux != nil }.count
            workspace = snapshot.workspace
        }

        func hasSameContent(as other: Self?) -> Bool {
            guard let other else { return false }
            return name == other.name && windows == other.windows && tabs == other.tabs &&
                panes == other.panes && tmuxPanes == other.tmuxPanes
        }

        var isRecoveryPoint: Bool { name?.hasPrefix(SessionSnapshot.recoveryPrefix) == true }
        var isAutomatic: Bool { name == nil }
        var isWorkspace: Bool { name != nil && !isRecoveryPoint }

        /// Distinct folder names, most used first: what the user recognises a session by.
        var places: [String] {
            var counts: [String: Int] = [:]
            var order: [String] = []
            for pane in tabs.flatMap(\.panes) {
                guard let location = pane.location else { continue }
                let name = location == NSHomeDirectory() ? "~" : (location as NSString).lastPathComponent
                if counts[name] == nil { order.append(name) }
                counts[name, default: 0] += 1
            }
            return order.sorted { counts[$0]! > counts[$1]! }
        }

        var profiles: [String] {
            Array(Set(tabs.flatMap(\.panes).compactMap(\.profile))).sorted()
        }

        func matches(_ query: String) -> Bool {
            let query = query.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return true }
            let haystack = ([name ?? ""] + tabs.compactMap(\.title) +
                tabs.flatMap(\.panes).flatMap { [$0.location ?? "", $0.title, $0.tmuxSession ?? "", $0.profile ?? ""] })
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// Immutable files plus atomic publication retain the previous valid checkpoint after a failed write.
///
/// The store keeps an in-memory index of summaries, built by reading every file once.
/// Saving a checkpoint therefore never re-reads the directory: earlier versions decoded
/// every stored snapshot (including all saved output) after each save, every five seconds.
final class SessionStore {
    enum Failure: Error { case invalidSnapshot, tooLarge, notFound }
    let directory: URL
    /// Automatic checkpoints kept; named workspaces and recovery points are not counted.
    let automaticLimit: Int
    private var index: [UUID: SessionSnapshot.Summary]?

    init(directory: URL, automaticLimit: Int = 20) {
        self.directory = directory
        self.automaticLimit = automaticLimit
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    func save(_ snapshot: SessionSnapshot) throws {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 32 * 1024 * 1024 else { throw Failure.tooLarge }
        try prepare()
        let file = file(snapshot.id)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var index = loadIndex()
        index[snapshot.id] = snapshot.summary
        self.index = index
        // Named sessions are never pruned automatically.
        let automatic = index.values.filter(\.isAutomatic).sorted { $0.date > $1.date }
        for old in automatic.dropFirst(automaticLimit) { try delete(old.id) }
    }

    func delete(_ id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: file(id))
        } catch CocoaError.fileNoSuchFile {
            // Already gone; only the index still knew it.
        }
        index?.removeValue(forKey: id)
    }

    /// The full snapshot, including saved output.
    func load(_ id: UUID) throws -> SessionSnapshot {
        guard let snapshot = Self.read(file(id)) else {
            index?.removeValue(forKey: id)
            throw Failure.notFound
        }
        return snapshot
    }

    /// Summaries of every valid stored snapshot, newest first.
    func summaries() -> [SessionSnapshot.Summary] {
        loadIndex().values.sorted { $0.date > $1.date }
    }

    /// Every valid stored snapshot, newest first. Reads all files: for tests and tools.
    func list() throws -> [SessionSnapshot] {
        files().compactMap(Self.read).sorted { $0.date > $1.date }
    }

    /// Bytes used by stored snapshots.
    func size() -> Int {
        files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func loadIndex() -> [UUID: SessionSnapshot.Summary] {
        if let index { return index }
        var value: [UUID: SessionSnapshot.Summary] = [:]
        for file in files() {
            // A damaged checkpoint must not hide earlier valid checkpoints.
            guard let snapshot = Self.read(file) else { continue }
            value[snapshot.id] = snapshot.summary
        }
        index = value
        return value
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private static func read(_ file: URL) -> SessionSnapshot? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              (try? value.validate()) != nil,
              file.deletingPathExtension().lastPathComponent == value.id.uuidString else { return nil }
        return value
    }
}
