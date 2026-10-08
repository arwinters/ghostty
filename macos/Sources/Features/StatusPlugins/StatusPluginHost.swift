import Combine
import Darwin
import Foundation

/// A host per visible terminal container. Plugins are ordinary trusted local processes,
/// not sandboxed code. Nothing is started until an explicit manifest is configured.
final class StatusPluginHost: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let widget: StatusPluginFrame.Widget
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var errors: [String] = []
    private var sessions: [Session] = []
    private var timer: Timer?

    private final class Session {
        let id: String
        let process = Process()
        let pipe = Pipe()
        var decoder = StatusPluginDecoder()
        var widgets: [StatusPluginFrame.Widget] = []
        var failure: String?
        var lastFrame = Date()

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
            var bytes = [UInt8](repeating: 0, count: 4096)
            var received = 0
            do {
                // Bound work per tick and terminate producers that flood their pipe.
                while true {
                    let count = read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
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
                    guard received <= 65_536 else { throw StatusPluginError.outputLimit }
                    if let frame = try decoder.append(Data(bytes.prefix(count))) {
                        widgets = frame.widgets
                        lastFrame = Date()
                    }
                }
                if Date().timeIntervalSince(lastFrame) > 10 { failure = "Plugin timed out" }
            } catch {
                failure = "Invalid or excessive plugin output"
            }
            if failure != nil {
                widgets = []
                stop()
            }
        }
    }

    func start(manifest path: String?) {
        stop()
        guard let path, !path.isEmpty else { return }
        do {
            let manifest = try StatusPluginManifest.load(path)
            for plugin in manifest.plugins {
                do { sessions.append(try Session(plugin)) } catch { errors.append("\(plugin.id): could not start") }
            }
        } catch {
            errors = ["Status plugins: invalid or unreadable manifest"]
        }
        let startupErrors = errors
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessions.forEach { $0.poll() }
            self.items = self.sessions.flatMap { session in
                session.widgets.map { Item(id: "\(session.id)/\($0.id)", widget: $0) }
            }
            self.errors = startupErrors + self.sessions.compactMap { session in
                session.failure.map { "\(session.id): \($0)" }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessions.forEach { $0.stop() }
        sessions = []
        items = []
        errors = []
    }

    deinit {
        timer?.invalidate()
        sessions.forEach { $0.stop() }
    }
}
