import Combine
import Darwin
import Foundation
import os

/// Runs the status plugins. Plugins are ordinary trusted local processes, not sandboxed
/// code. Nothing is started until an explicit manifest is configured.
///
/// Every status bar shares `shared`: one set of plugin processes for the whole app. Earlier
/// builds started a host per tab, so ten tabs ran ten copies of every plugin (and ten
/// weather downloads), each redrawing its bar twice a second.
final class StatusPluginHost: ObservableObject {
    static let shared = StatusPluginHost(observesChanges: true)

    struct Item: Identifiable, Equatable {
        let id: String
        let widget: StatusPluginFrame.Widget
        var placement = StatusPluginPlacement.leading
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var errors: [String] = []
    private var sessions: [ManagedSession] = []
    private var timer: Timer?
    /// Status bars currently showing this host's items, and the manifest they show.
    private var users = 0
    private var manifest: String?
    private var observers: [NSObjectProtocol] = []

    init() {}

    private init(observesChanges: Bool) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .statusPluginsDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.restart()
            },
            // Retry failed plugins after a configuration reload; healthy ones keep running.
            center.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] _ in
                if self?.errors.isEmpty == false { self?.restart() }
            },
        ]
    }

    /// A status bar appeared. Starts the plugins for the first bar, or when the manifest changed.
    func acquire(manifest path: String) {
        users += 1
        if path != manifest || timer == nil { start(manifest: path) }
    }

    /// The configured manifest changed; every bar reports it, the plugins restart once.
    func use(manifest path: String) {
        if path != manifest { start(manifest: path) }
    }

    /// A status bar disappeared. The plugins stop with the last one.
    func release() {
        users = max(0, users - 1)
        if users == 0 { stop() }
    }

    /// Restarts the plugins with the current manifest, if any bar shows them.
    func restart() {
        guard users > 0, let manifest else { return }
        start(manifest: manifest)
    }

    /// Backoff is capped but retries continue, so a transient failure needs no user action.
    struct RetryPolicy {
        private(set) var failures = 0
        mutating func nextDelay() -> TimeInterval {
            failures = min(failures + 1, 6)
            return min(60, pow(2, Double(failures)))
        }
        mutating func recovered() { failures = 0 }
    }

    private final class ManagedSession {
        private static let logger = Logger(subsystem: "com.arwinters.ghostty.statuslab", category: "StatusPlugins")
        let plugin: StatusPluginManifest.Plugin
        var session: Session?
        var retry = RetryPolicy()
        var retryAt: TimeInterval?
        var failure: String?
        var startedAt = ProcessInfo.processInfo.systemUptime
        var id: String { plugin.id }
        var widgets: [StatusPluginFrame.Widget] { session?.widgets ?? [] }

        init(_ plugin: StatusPluginManifest.Plugin) {
            self.plugin = plugin
            launch()
        }

        func launch() {
            retryAt = nil
            if failure != nil { failure = "Restarting plugin; waiting for data" }
            startedAt = ProcessInfo.processInfo.systemUptime
            do { session = try Session(plugin) } catch {
                scheduleRetry("Could not start plugin")
            }
        }

        func scheduleRetry(_ reason: String) {
            let delay = retry.nextDelay()
            failure = "\(reason); retrying in \(Int(delay))s"
            retryAt = ProcessInfo.processInfo.systemUptime + delay
            Self.logger.error("Plugin \(self.id, privacy: .public): \(reason, privacy: .public); retry in \(delay)s")
        }

        func poll() {
            let now = ProcessInfo.processInfo.systemUptime
            if let retryAt {
                // Never overlap a replacement with a child still being terminated.
                if now >= retryAt, session?.process.isRunning != true {
                    session = nil
                    launch()
                }
                return
            }
            guard let session else { return }
            session.poll()
            if let failure = session.failure {
                scheduleRetry(failure)
            } else if session.hasFrame {
                failure = nil
                if now - startedAt >= 60 { retry.recovered() }
            }
        }

        func stop() { session?.stop() }
    }

    private final class Session {
        let id: String
        let process = Process()
        let pipe = Pipe()
        var decoder = StatusPluginDecoder()
        var widgets: [StatusPluginFrame.Widget] = []
        var failure: String?
        var hasFrame = false
        var stopped = false
        var lastFrame = ProcessInfo.processInfo.systemUptime
        var lastPoll = ProcessInfo.processInfo.systemUptime
        var saturatedPolls = 0

        init(_ plugin: StatusPluginManifest.Plugin) throws {
            id = plugin.id
            process.executableURL = URL(fileURLWithPath: plugin.executable)
            process.arguments = plugin.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            // Deliberately do not inherit terminal credentials, shell environment, or cwd.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                                   "GHOSTTY_PLUGIN_PROTOCOL": "1"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw StatusPluginError.invalidManifest
            }
            try process.run()
            try? pipe.fileHandleForWriting.close()
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            try? pipe.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                let child = process
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }

        func poll() {
            guard failure == nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // A suspended app cannot enforce a producer heartbeat while it is not polling.
            if now - lastPoll > 5 { lastFrame = now }
            lastPoll = now
            var bytes = [UInt8](repeating: 0, count: 4096)
            var received = 0
            do {
                // Drain a bounded batch. A single backlog is not evidence of flooding.
                while received < 65_536 {
                    let count = read(pipe.fileHandleForReading.fileDescriptor, &bytes, min(bytes.count, 65_536 - received))
                    if count < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        if errno == EINTR { continue }
                        throw StatusPluginError.invalidFrame
                    }
                    if count == 0 {
                        failure = "Plugin stopped"
                        break
                    }
                    received += count
                    if let frame = try decoder.append(Data(bytes.prefix(count))) {
                        widgets = frame.widgets
                        hasFrame = true
                        lastFrame = now
                    }
                }
                saturatedPolls = received == 65_536 ? saturatedPolls + 1 : 0
                if saturatedPolls >= 3 { throw StatusPluginError.outputLimit }
                if now - lastFrame > 10 { failure = "Plugin timed out" }
            } catch StatusPluginError.outputLimit {
                failure = "Plugin output limit exceeded (oversized record or sustained backlog)"
            } catch {
                failure = "Invalid plugin output or pipe read failure"
            }
            if failure != nil {
                widgets = []
                stop()
            }
        }
    }

    func start(manifest path: String?) {
        stop()
        manifest = path
        guard let path, !path.isEmpty else { return }
        do {
            let manifest = try StatusPluginManifest.load(path)
            for plugin in manifest.plugins {
                sessions.append(ManagedSession(plugin))
            }
        } catch {
            errors = ["Status plugins: invalid or unreadable manifest"]
        }
        let startupErrors = errors
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessions.forEach { $0.poll() }
            let items = self.sessions.flatMap { session in
                session.widgets.map {
                    Item(id: "\(session.id)/\($0.id)", widget: $0, placement: session.plugin.placement)
                }
            }
            let errors = startupErrors + self.sessions.compactMap { session in
                session.failure.map { "\(session.id): \($0)" }
            }
            // Publishing redraws every status bar: only do so when something changed.
            if items != self.items { self.items = items }
            if errors != self.errors { self.errors = errors }
        }
        timer?.tolerance = 0.1
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessions.forEach { $0.stop() }
        sessions = []
        if !items.isEmpty { items = [] }
        if !errors.isEmpty { errors = [] }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        timer?.invalidate()
        sessions.forEach { $0.stop() }
    }
}
