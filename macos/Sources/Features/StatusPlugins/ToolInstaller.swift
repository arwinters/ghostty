import AppKit
import SwiftUI

/// A `brew install` command for one package, so the installer can show what Homebrew
/// knows about it and measure the download.
struct BrewRequest: Equatable {
    let name: String
    let cask: Bool

    /// `brew install [--cask|--formula] <name>`; nil for anything else.
    static func parse(_ command: String) -> BrewRequest? {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 3, (words[0] as NSString).lastPathComponent == "brew", words[1] == "install" else { return nil }
        var cask = false
        var names: [String] = []
        for word in words.dropFirst(2) {
            switch word {
            case "--cask": cask = true
            case "--formula": cask = false
            case let flag where flag.hasPrefix("-"): return nil
            default: names.append(word)
            }
        }
        guard names.count == 1, let name = names.first,
              name.range(of: "^[A-Za-z0-9@+._/-]+$", options: .regularExpression) != nil else { return nil }
        return .init(name: name, cask: cask)
    }
}

/// Runs a tool's install command and follows Homebrew's progress.
final class ToolInstaller: ObservableObject {
    enum Step: Int, CaseIterable, Comparable {
        case prepare, download, install, link, finish

        var title: String {
            switch self {
            case .prepare: "Prepare"
            case .download: "Download"
            case .install: "Install"
            case .link: "Link"
            case .finish: "Ready"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum State: Equatable {
        case ready, running, succeeded, failed(String), cancelled
    }

    /// What Homebrew says about the package before anything is installed.
    struct Package: Equatable {
        var name: String
        var title: String
        var version: String
        var summary: String?
        var homepage: URL?
        var kind: String
        var license: String?
        var installs: [String]
        var download: URL?
        var cachePath: String?
        var size: Int64?
    }

    struct Line: Identifiable, Equatable {
        enum Kind { case step, success, warning, error, plain }
        let id: Int
        let text: String
        let kind: Kind
    }

    @Published private(set) var state: State = .ready
    @Published private(set) var step: Step = .prepare
    @Published private(set) var detail = "Homebrew checks the package"
    @Published private(set) var package: Package?
    @Published private(set) var loadingInfo = false
    @Published private(set) var infoError: String?
    @Published private(set) var downloaded: Int64 = 0
    @Published private(set) var speed: Double = 0
    @Published private(set) var cached = false
    @Published private(set) var linkedTo: [String] = []
    @Published private(set) var lines: [Line] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?

    let session: AISession
    let command: String
    let brew: BrewRequest?
    private var process: Process?
    private var poll: Timer?
    private var pending = ""
    private var lastSample: (date: Date, bytes: Int64)?

    init(session: AISession) {
        self.session = session
        command = session.installCommand ?? ""
        brew = BrewRequest.parse(command)
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var shell: String {
        getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
    }

    // MARK: Package information

    func loadInfo() {
        guard let brew, package == nil, !loadingInfo else { return }
        guard let brewPath = Self.brewPath else {
            infoError = "Homebrew is not installed. Get it from brew.sh, then try again."
            return
        }
        loadingInfo = true
        let kind = brew.cask ? "--cask" : "--formula"
        DispatchQueue.global(qos: .userInitiated).async {
            var package: Package?
            var failure: String?
            let info = Self.capture(brewPath, ["info", "--json=v2", kind, brew.name])
            if let data = info?.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                package = brew.cask ? Self.cask(json) : Self.formula(json)
            }
            if package == nil { failure = "Homebrew does not know “\(brew.name)”." }
            if var found = package {
                let cache = Self.capture(brewPath, ["--cache", kind, brew.name])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                found.cachePath = cache.flatMap { $0.hasPrefix("/") ? $0 : nil }
                package = found
            }
            DispatchQueue.main.async {
                self.loadingInfo = false
                self.package = package
                self.infoError = failure
                if let url = package?.download { self.fetchSize(url) }
            }
        }
    }

    private static func cask(_ json: [String: Any]) -> Package? {
        guard let cask = (json["casks"] as? [[String: Any]])?.first else { return nil }
        var installs: [String] = []
        for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
            if let target = artifact["target"] as? String {
                installs.append(target)
            } else if let binary = artifact["binary"] as? [Any], let source = binary.first as? String {
                installs.append((source as NSString).lastPathComponent)
            } else if let app = artifact["app"] as? [Any], let source = app.first as? String {
                installs.append("/Applications/" + source)
            }
        }
        return Package(
            name: cask["token"] as? String ?? "",
            title: (cask["name"] as? [String])?.first ?? cask["token"] as? String ?? "",
            version: cask["version"] as? String ?? "",
            summary: cask["desc"] as? String,
            homepage: (cask["homepage"] as? String).flatMap(URL.init(string:)),
            kind: "Cask", license: nil, installs: installs,
            download: (cask["url"] as? String).flatMap(URL.init(string:)))
    }

    private static func formula(_ json: [String: Any]) -> Package? {
        guard let formula = (json["formulae"] as? [[String: Any]])?.first else { return nil }
        let version = (formula["versions"] as? [String: Any])?["stable"] as? String ?? ""
        let bottle = (((formula["bottle"] as? [String: Any])?["stable"] as? [String: Any])?["files"] as? [String: Any])?
            .values.compactMap { ($0 as? [String: Any])?["url"] as? String }.first
        let dependencies = formula["dependencies"] as? [String] ?? []
        return Package(
            name: formula["name"] as? String ?? "",
            title: formula["name"] as? String ?? "",
            version: version,
            summary: formula["desc"] as? String,
            homepage: (formula["homepage"] as? String).flatMap(URL.init(string:)),
            kind: dependencies.isEmpty ? "Formula" : "Formula · needs \(dependencies.joined(separator: ", "))",
            license: formula["license"] as? String,
            installs: [(Self.brewPath.map { ($0 as NSString).deletingLastPathComponent } ?? "") + "/" + (formula["name"] as? String ?? "")],
            download: bottle.flatMap(URL.init(string:)))
    }

    /// The download's size from the server, for a real progress bar.
    private func fetchSize(_ url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let length = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
            guard length > 0 else { return }
            DispatchQueue.main.async { self.package?.size = length }
        }.resume()
    }

    // MARK: Running

    func start() {
        guard state != .running, !command.isEmpty else { return }
        if brew != nil && Self.brewPath == nil {
            state = .failed("Homebrew is not installed. Get it from brew.sh, then try again.")
            return
        }
        state = .running
        step = .prepare
        detail = "Homebrew checks the package"
        lines = []
        pending = ""
        downloaded = 0
        speed = 0
        lastSample = nil
        cached = false
        linkedTo = []
        startedAt = Date()
        finishedAt = nil
        if let path = package?.cachePath, let size = package?.size, Self.fileSize(path) == size { cached = true }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        // The login shell finds Homebrew and the user's PATH, as in a terminal.
        process.arguments = ["-lc", command]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.receive(text) }
        }
        process.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                if !rest.isEmpty { self?.receive(String(decoding: rest, as: UTF8.self)) }
                self?.finish(process.terminationStatus)
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed("Could not start: \(error.localizedDescription)")
            return
        }
        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.measureDownload() }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
    }

    func cancel() {
        guard state == .running, let process else { return }
        state = .cancelled
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
    }

    private func receive(_ text: String) {
        pending += text
        let parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        pending = parts.last ?? ""
        for part in parts.dropLast() { handle(part) }
    }

    private func handle(_ raw: String) {
        let text = Self.clean(raw)
        guard !text.isEmpty else { return }
        let parsed = Self.classify(text)
        lines.append(.init(id: lines.count, text: text, kind: parsed.kind))
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
        if let next = parsed.step, next >= step {
            step = next
            detail = parsed.detail ?? detail
        }
        if let link = parsed.linked, !linkedTo.contains(link) { linkedTo.append(link) }
    }

    private func finish(_ status: Int32) {
        poll?.invalidate()
        poll = nil
        process = nil
        finishedAt = Date()
        if !pending.isEmpty { handle(pending) }
        pending = ""
        guard state == .running else { return }
        if status == 0 {
            step = .finish
            detail = "\(session.name) is ready"
            state = .succeeded
            AISessions.shared.installed(session)
        } else {
            let error = lines.last(where: { $0.kind == .error })?.text
            state = .failed(error ?? "The install command ended with status \(status).")
        }
    }

    private func measureDownload() {
        guard step == .download, let path = package?.cachePath else { return }
        let size = max(Self.fileSize(path + ".incomplete") ?? 0, Self.fileSize(path) ?? 0)
        guard size > 0 else { return }
        let now = Date()
        if let last = lastSample, now.timeIntervalSince(last.date) >= 0.5 {
            let rate = Double(size - last.bytes) / now.timeIntervalSince(last.date)
            speed = speed == 0 ? rate : speed * 0.6 + rate * 0.4
            lastSample = (now, size)
        } else if lastSample == nil {
            lastSample = (now, size)
        }
        downloaded = size
    }

    private static func fileSize(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    // MARK: Parsing Homebrew output

    /// Removes terminal escapes and control characters that Homebrew may still write.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .unicodeScalars.filter { $0.value >= 32 || $0.value == 9 }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
    }

    /// What a line of Homebrew output says: its kind, the step it starts, and a linked path.
    static func classify(_ line: String) -> (kind: Line.Kind, step: Step?, detail: String?, linked: String?) {
        let body = line.hasPrefix("==> ") ? String(line.dropFirst(4)) : line
        if line.hasPrefix("Error:") { return (.error, nil, nil, nil) }
        if line.hasPrefix("Warning:") { return (.warning, nil, nil, nil) }
        if line.hasPrefix("🍺") || line.localizedCaseInsensitiveContains("successfully installed") {
            return (.success, .finish, "Installed", nil)
        }
        if line.localizedCaseInsensitiveContains("is already installed") {
            return (.success, .finish, "Already installed", nil)
        }
        if body.hasPrefix("Auto-updating Homebrew") || body.hasPrefix("Updating Homebrew") {
            return (.step, .prepare, "Updating Homebrew", nil)
        }
        if body.hasPrefix("Fetching") || body.hasPrefix("Downloading") {
            return (.step, .download, body, nil)
        }
        // Homebrew writes "✔︎" (with a variation selector): compare the first scalar.
        if line.unicodeScalars.first == "✔" { return (.success, .install, "Unpacking", nil) }
        if body.hasPrefix("Installing") || body.hasPrefix("Pouring") || body.hasPrefix("Moving") ||
            body.hasPrefix("Extracting") || body.hasPrefix("Purging") {
            return (.step, .install, body, nil)
        }
        if body.hasPrefix("Linking") || body.hasPrefix("Generating completions") {
            var linked: String?
            if let range = body.range(of: "to '([^']+)'", options: .regularExpression) {
                linked = String(body[range].dropFirst(4).dropLast())
            }
            return (.step, .link, body, linked)
        }
        return (line.hasPrefix("==>") ? .step : .plain, nil, nil, nil)
    }

    /// Runs Homebrew directly and returns its output; nil on failure.
    private static func capture(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

// MARK: - Window

/// One window per tool; closing it does not stop a running install.
enum ToolInstallWindow {
    private static var windows: [String: NSWindow] = [:]
    private static var installers: [String: ToolInstaller] = [:]

    static func show(_ session: AISession) {
        if let window = windows[session.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let installer = installers[session.id] ?? ToolInstaller(session: session)
        installers[session.id] = installer
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Install \(session.name)"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ToolInstallView(installer: installer) {
            window.close()
        })
        window.setContentSize(NSSize(width: 600, height: 640))
        window.center()
        windows[session.id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            windows[session.id] = nil
            // A finished installer is not needed again; a running one keeps going.
            if installer.state != .running { installers[session.id] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installer.loadInfo()
    }
}

// MARK: - View

private struct ToolInstallView: View {
    @ObservedObject var installer: ToolInstaller
    let close: () -> Void
    @State private var showOutput = true

    private var name: String { installer.session.name }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PackageCard(installer: installer)
                    Steps(installer: installer)
                    output
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 11).fill(iconColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(installer.command)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(20)
    }

    private var title: String {
        switch installer.state {
        case .ready: "Install \(name)"
        case .running: "Installing \(name)…"
        case .succeeded: "\(name) is installed"
        case .failed: "Installation failed"
        case .cancelled: "Installation cancelled"
        }
    }

    private var icon: String {
        switch installer.state {
        case .ready, .running: "arrow.down.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch installer.state {
        case .succeeded: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showOutput.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showOutput ? 90 : 0))
                    Text("Homebrew output").font(.headline)
                    if !installer.lines.isEmpty {
                        Text("\(installer.lines.count) lines").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showOutput {
                OutputLog(lines: installer.lines, waiting: installer.state == .ready)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Elapsed(installer: installer)
            Spacer()
            switch installer.state {
            case .ready:
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Install") { installer.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installer.infoError != nil && installer.brew != nil)
            case .running:
                Button("Stop") { installer.cancel() }
            case .succeeded:
                Button("Close", action: close)
                Button("Open \(name)") {
                    AISessions.shared.open(installer.session, placement: .tab, from: nil,
                                           directory: (NSApp.mainWindow?.windowController as? BaseTerminalController)?
                                               .focusedSurface?.contextDirectory)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            case .failed, .cancelled:
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installer.lines.map(\.text).joined(separator: "\n"), forType: .string)
                }
                Button("Close", action: close)
                Button("Try Again") { installer.start() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// What will be installed, from `brew info`.
private struct PackageCard: View {
    @ObservedObject var installer: ToolInstaller

    var body: some View {
        Group {
            if let package = installer.package {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(package.title).font(.headline)
                        Text(package.version)
                            .font(.caption.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundStyle(.tint)
                        Text(package.kind).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let homepage = package.homepage {
                            Link(destination: homepage) {
                                Label(homepage.host ?? "Website", systemImage: "arrow.up.right.square")
                            }
                            .font(.caption)
                        }
                    }
                    if let summary = package.summary {
                        Text(summary).foregroundStyle(.secondary)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                        if let download = package.download {
                            GridRow {
                                Text("Download").foregroundStyle(.secondary)
                                Text([download.host, package.size.map(Self.bytes)].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                        if !package.installs.isEmpty {
                            GridRow {
                                Text("Installs").foregroundStyle(.secondary)
                                Text(package.installs.joined(separator: ", "))
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        if let license = package.license {
                            GridRow {
                                Text("License").foregroundStyle(.secondary)
                                Text(license)
                            }
                        }
                    }
                    .font(.callout)
                }
            } else if installer.loadingInfo {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking Homebrew about the package…").foregroundStyle(.secondary)
                }
            } else if let error = installer.infoError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Text("This runs the install command from your configuration in your login shell.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// Prepare › Download › Install › Link › Ready, with the download measured on disk.
private struct Steps: View {
    @ObservedObject var installer: ToolInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ToolInstaller.Step.allCases, id: \.self) { step in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        marker(step).frame(width: 22, height: 22)
                        if step != .finish {
                            Rectangle()
                                .fill(step < installer.step || installer.state == .succeeded
                                      ? Color.green.opacity(0.6) : Color.secondary.opacity(0.25))
                                .frame(width: 2)
                                .frame(minHeight: 14, maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title)
                            .fontWeight(isActive(step) ? .semibold : .regular)
                            .foregroundStyle(isPending(step) ? Color.secondary : Color.primary)
                        if let detail = detail(step) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        if step == .download, isActive(step) || (step < installer.step && installer.downloaded > 0) {
                            progress
                        }
                    }
                    .padding(.bottom, 14)
                    Spacer(minLength: 0)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: installer.step)
    }

    private func isActive(_ step: ToolInstaller.Step) -> Bool {
        installer.state == .running && step == installer.step
    }

    private func isPending(_ step: ToolInstaller.Step) -> Bool {
        installer.state == .ready || (step > installer.step && installer.state != .succeeded)
    }

    @ViewBuilder private func marker(_ step: ToolInstaller.Step) -> some View {
        let done = installer.state == .succeeded || (step < installer.step && installer.state != .ready)
        if done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18))
        } else if isActive(step) {
            ProgressView().controlSize(.small)
        } else if case .failed = installer.state, step == installer.step {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.orange).font(.system(size: 18))
        } else {
            Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5).frame(width: 16, height: 16)
        }
    }

    private func detail(_ step: ToolInstaller.Step) -> String? {
        let package = installer.package
        switch step {
        case .prepare:
            return installer.step == .prepare && installer.state == .running ? installer.detail : "Homebrew checks the package and its dependencies"
        case .download:
            if installer.cached { return "Using the download already in Homebrew's cache" }
            return [package?.download?.host, package?.size.map(PackageCard.bytes)].compactMap { $0 }.joined(separator: " · ")
        case .install:
            return installer.step == .install && installer.state == .running ? installer.detail : "Unpacks into Homebrew"
        case .link:
            if !installer.linkedTo.isEmpty { return installer.linkedTo.joined(separator: ", ") }
            return package?.installs.first.map { "Makes it available as \($0)" }
        case .finish:
            if installer.state == .succeeded { return "\(installer.session.name) is ready: right-click a pane › New AI Session" }
            if case .failed(let reason) = installer.state { return reason }
            return nil
        }
    }

    @ViewBuilder private var progress: some View {
        let total = installer.package?.size
        VStack(alignment: .leading, spacing: 3) {
            if let total, total > 0 {
                ProgressView(value: Double(min(installer.downloaded, total)), total: Double(total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(downloadText(total)).monospacedDigit()
                Spacer()
                if installer.speed > 0, installer.state == .running {
                    Text(PackageCard.bytes(Int64(installer.speed)) + "/s").monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360)
    }

    private func downloadText(_ total: Int64?) -> String {
        let done = PackageCard.bytes(installer.downloaded)
        guard let total, total > 0 else { return done }
        let percent = Int(Double(installer.downloaded) / Double(total) * 100)
        return "\(done) of \(PackageCard.bytes(total)) · \(min(percent, 100))%"
    }
}

/// Homebrew's own output, following the newest line.
private struct OutputLog: View {
    let lines: [ToolInstaller.Line]
    let waiting: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text(waiting ? "Output appears here when the installation starts." : "Waiting for Homebrew…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        Text(line.text)
                            .foregroundStyle(color(line.kind))
                            .fontWeight(line.kind == .step ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            .onChange(of: lines.count) { _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(_ kind: ToolInstaller.Line.Kind) -> Color {
        switch kind {
        case .step: .accentColor
        case .success: .green
        case .warning: .yellow
        case .error: .orange
        case .plain: .primary.opacity(0.85)
        }
    }
}

private struct Elapsed: View {
    @ObservedObject var installer: ToolInstaller

    var body: some View {
        if let start = installer.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                let end = installer.finishedAt ?? context.date
                Text(Self.format(end.timeIntervalSince(start)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        return value < 60 ? "\(value)s" : "\(value / 60)m \(value % 60)s"
    }
}
