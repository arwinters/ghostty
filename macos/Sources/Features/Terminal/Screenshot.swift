import AppKit
import CoreImage
import IOSurface
import SwiftUI

/// Status Lab: screenshots of a pane, a tab or a window, drawn by Ghostty itself.
///
/// No screen recording permission is needed. The window's own views (tab strip, status
/// bar, split dividers, titlebar) are drawn with `cacheDisplay`, and each terminal is
/// copied from the IOSurface its renderer draws into, so the result is pixel exact and
/// never contains other apps or menus.
final class Screenshots: ObservableObject {
    static let shared = Screenshots()

    enum Target: String, CaseIterable, Identifiable {
        case pane, tab, window
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pane: "This Pane"
            case .tab: "This Tab"
            case .window: "This Window"
            }
        }
        var symbol: String {
            switch self {
            case .pane: "rectangle.inset.filled"
            case .tab: "rectangle.split.2x1"
            case .window: "macwindow"
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable {
        case plain, framed
        var id: String { rawValue }
    }

    enum Backdrop: String, CaseIterable, Identifiable {
        case ghostty, dusk, graphite, transparent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ghostty: "Ghostty Blue"
            case .dusk: "Dusk"
            case .graphite: "Graphite"
            case .transparent: "Transparent"
            }
        }
        var colors: [NSColor] {
            switch self {
            case .ghostty: [NSColor(srgbRed: 0.20, green: 0.35, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.45, green: 0.80, blue: 1.0, alpha: 1)]
            case .dusk: [NSColor(srgbRed: 0.35, green: 0.15, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.45, alpha: 1)]
            case .graphite: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.32, alpha: 1)]
            case .transparent: []
            }
        }
    }

    @Published var style: Style { didSet { save() } }
    @Published var backdrop: Backdrop { didSet { save() } }
    @Published var padding: Double { didSet { save() } }
    @Published var copyToClipboard: Bool { didSet { save() } }
    @Published var saveToFolder: Bool { didSet { save() } }
    @Published var folder: URL { didSet { save() } }
    @Published var showPreview: Bool { didSet { save() } }
    @Published private(set) var last: (image: NSImage, file: URL?, target: Target)?
    @Published private(set) var message: String?

    private let defaults = UserDefaults.standard
    private var window: NSWindow?

    private init() {
        style = Style(rawValue: defaults.string(forKey: "StatusLabScreenshotStyle") ?? "") ?? .framed
        backdrop = Backdrop(rawValue: defaults.string(forKey: "StatusLabScreenshotBackdrop") ?? "") ?? .ghostty
        padding = defaults.object(forKey: "StatusLabScreenshotPadding") as? Double ?? 56
        copyToClipboard = defaults.object(forKey: "StatusLabScreenshotCopy") as? Bool ?? true
        saveToFolder = defaults.object(forKey: "StatusLabScreenshotSave") as? Bool ?? true
        showPreview = defaults.object(forKey: "StatusLabScreenshotPreview") as? Bool ?? true
        folder = defaults.url(forKey: "StatusLabScreenshotFolder") ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Ghostty")
    }

    private func save() {
        defaults.set(style.rawValue, forKey: "StatusLabScreenshotStyle")
        defaults.set(backdrop.rawValue, forKey: "StatusLabScreenshotBackdrop")
        defaults.set(padding, forKey: "StatusLabScreenshotPadding")
        defaults.set(copyToClipboard, forKey: "StatusLabScreenshotCopy")
        defaults.set(saveToFolder, forKey: "StatusLabScreenshotSave")
        defaults.set(showPreview, forKey: "StatusLabScreenshotPreview")
        defaults.set(folder, forKey: "StatusLabScreenshotFolder")
    }

    // MARK: Taking screenshots

    /// Captures after the context menu has closed, then copies, saves and previews.
    func take(_ target: Target, of view: Ghostty.SurfaceView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak view] in
            guard let self, let view else { return }
            guard let raw = Self.capture(target, of: view) else {
                self.message = "Could not capture the \(target == .pane ? "pane" : "window")."
                self.showWindow()
                return
            }
            let image = self.style == .framed ? self.frame(raw, scale: view.window?.backingScaleFactor ?? 2) : raw
            self.deliver(image, target: target)
        }
    }

    private func deliver(_ cgImage: CGImage, target: Target) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale,
                                                         height: CGFloat(cgImage.height) / scale))
        var file: URL?
        var notes: [String] = []
        if copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            notes.append("copied")
        }
        if saveToFolder {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(Self.fileName())
                try Self.png(cgImage).write(to: url, options: .atomic)
                file = url
                notes.append("saved to \((folder.path as NSString).abbreviatingWithTildeInPath)")
            } catch {
                notes.append("not saved: \(error.localizedDescription)")
            }
        }
        last = (image, file, target)
        message = "\(target.title.replacingOccurrences(of: "This ", with: "")) · \(cgImage.width)×\(cgImage.height)" +
            (notes.isEmpty ? "" : " · " + notes.joined(separator: ", "))
        if showPreview { showWindow() }
    }

    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Ghostty \(formatter.string(from: Date())).png"
    }

    // MARK: Capturing

    /// The pane alone, its tab's content (tab strip, splits, status bar), or the whole
    /// window including the titlebar.
    static func capture(_ target: Target, of view: Ghostty.SurfaceView) -> CGImage? {
        guard let window = view.window else { return nil }
        switch target {
        case .pane:
            return terminal(view)
        case .tab:
            guard let root = window.contentView else { return nil }
            return compose(root, window: window)
        case .window:
            guard let root = window.contentView?.superview ?? window.contentView else { return nil }
            return compose(root, window: window)
        }
    }

    /// The terminal's pixels, from the IOSurface the renderer draws into.
    static func terminal(_ view: Ghostty.SurfaceView) -> CGImage? {
        guard let surface = ioSurface(in: view.layer) else { return nil }
        let image = CIImage(ioSurface: surface)
        return CIContext(options: [.workingColorSpace: NSNull()]).createCGImage(
            image, from: image.extent, format: .RGBA8,
            colorSpace: view.window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func ioSurface(in layer: CALayer?) -> IOSurfaceRef? {
        guard let layer else { return nil }
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            return (contents as! IOSurfaceRef)
        }
        for sublayer in layer.sublayers ?? [] {
            if let surface = ioSurface(in: sublayer) { return surface }
        }
        return nil
    }

    /// Draws `root` and its subviews, then each terminal of the window on top at its place,
    /// with the dimming Ghostty gives unfocused splits.
    private static func compose(_ root: NSView, window: NSWindow) -> CGImage? {
        let bounds = root.bounds
        guard let base = root.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        root.cacheDisplay(in: bounds, to: base)
        let width = base.pixelsWide
        let height = base.pixelsHigh
        let scale = CGFloat(width) / bounds.width
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: window.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let baseImage = base.cgImage else { return nil }
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let controller = window.windowController as? BaseTerminalController
        let views = controller.map { Array($0.surfaceTree) } ?? []
        let split = views.count > 1
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        for view in views where !view.isHidden && view.window === window {
            guard let image = terminal(view) else { continue }
            // View coordinates in the root, flipped to the bitmap's bottom-left origin.
            var rect = view.convert(view.bounds, to: root)
            if root.isFlipped { rect.origin.y = bounds.height - rect.maxY }
            let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                width: rect.width * scale, height: rect.height * scale)
            // Replace what the window drew there: a see-through terminal must stay see-through.
            context.clear(pixels)
            context.draw(image, in: pixels)
            if split, view !== controller?.focusedSurface, let config, config.unfocusedSplitOpacity > 0 {
                context.setFillColor(NSColor(config.unfocusedSplitFill).withAlphaComponent(config.unfocusedSplitOpacity).cgColor)
                context.fill(pixels)
            }
        }
        return context.makeImage()
    }

    /// Rounded corners, a soft shadow and a backdrop: ready for a README.
    fileprivate func frame(_ image: CGImage, scale: CGFloat) -> CGImage {
        let pad = CGFloat(padding) * scale
        let width = CGFloat(image.width) + pad * 2
        let height = CGFloat(image.height) + pad * 2
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let colors = backdrop.colors
        if colors.count >= 2, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                         colors: colors.map(\.cgColor) as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        }
        let rect = CGRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height))
        let radius = 12 * scale
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if pad > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 30 * scale,
                              color: NSColor.black.withAlphaComponent(0.45).cgColor)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
        // A hairline edge, as macOS draws around windows.
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(scale)
        context.strokePath()
        return context.makeImage() ?? image
    }

    // MARK: Window

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Screenshot"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ScreenshotView(shots: self))
            window.setContentSize(NSSize(width: 760, height: 560))
            window.center()
            window.setFrameAutosaveName("StatusLabScreenshot")
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func saveLastAs() {
        guard let last, let image = last.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = last.file?.lastPathComponent ?? Self.fileName()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.png(image).write(to: url, options: .atomic)
            message = "Saved to \((url.path as NSString).abbreviatingWithTildeInPath)"
        } catch {
            message = "Not saved: \(error.localizedDescription)"
        }
    }

    func copyLast() {
        guard let last else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([last.image])
        message = "Copied to the clipboard"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}

// MARK: - Development check

extension Screenshots {
    /// For checking captures without the UI: launched with `-StatusLabScreenshotTest <dir>`,
    /// the app writes pane.png, tab.png and window.png of the key window a few seconds later
    /// (`-StatusLabScreenshotDelay <seconds>`, 6 by default).
    static func captureForTestIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "StatusLabScreenshotTest") else { return }
        let delay = UserDefaults.standard.double(forKey: "StatusLabScreenshotDelay")
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 6)) {
            let controller = (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.windowController is BaseTerminalController })?
                .windowController as? BaseTerminalController
            guard let view = controller?.focusedSurface ?? controller?.surfaceTree.first else { return }
            let directory = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for target in Target.allCases {
                guard let image = capture(target, of: view), let data = try? png(image) else { continue }
                try? data.write(to: directory.appendingPathComponent(target.rawValue + ".png"))
                if target == .window, let framed = try? png(shared.frame(image, scale: view.window?.backingScaleFactor ?? 2)) {
                    try? framed.write(to: directory.appendingPathComponent("window-framed.png"))
                }
            }
        }
    }
}

// MARK: - Context menu

extension Ghostty.SurfaceView {
    /// "Screenshot ▸ This Pane / This Tab / This Window / Options…"
    func screenshotMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        for target in Screenshots.Target.allCases {
            let item = menu.addItem(withTitle: target.title, action: #selector(takeScreenshot(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.rawValue
            item.setImageIfDesired(systemSymbolName: target.symbol)
        }
        menu.addItem(.separator())
        let options = menu.addItem(withTitle: "Screenshot Options…", action: #selector(showScreenshotOptions(_:)), keyEquivalent: "")
        options.target = self
        let item = NSMenuItem(title: "Screenshot", action: nil, keyEquivalent: "")
        item.submenu = menu
        item.setImageIfDesired(systemSymbolName: "camera.viewfinder")
        return item
    }

    @objc fileprivate func takeScreenshot(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let target = Screenshots.Target(rawValue: raw) else { return }
        Screenshots.shared.take(target, of: self)
    }

    @objc fileprivate func showScreenshotOptions(_ sender: Any?) { Screenshots.shared.showWindow() }
}

// MARK: - View

private struct ScreenshotView: View {
    @ObservedObject var shots: Screenshots

    var body: some View {
        HStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Form {
                Section("Look") {
                    Picker("Style", selection: $shots.style) {
                        Text("Framed").tag(Screenshots.Style.framed)
                        Text("Plain").tag(Screenshots.Style.plain)
                    }
                    .pickerStyle(.segmented)
                    if shots.style == .framed {
                        Picker("Background", selection: $shots.backdrop) {
                            ForEach(Screenshots.Backdrop.allCases) { Text($0.title).tag($0) }
                        }
                        LabeledContent("Margin") {
                            Slider(value: $shots.padding, in: 0...120, step: 4)
                        }
                    }
                }
                Section("After taking it") {
                    Toggle("Copy to the clipboard", isOn: $shots.copyToClipboard)
                    Toggle("Save as PNG", isOn: $shots.saveToFolder)
                    if shots.saveToFolder {
                        LabeledContent("Folder") {
                            Button((shots.folder.path as NSString).abbreviatingWithTildeInPath) { shots.chooseFolder() }
                                .buttonStyle(.link)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Toggle("Show this window", isOn: $shots.showPreview)
                }
                Section {
                    Text("Right-click a pane › Screenshot › This Pane, This Tab or This Window. Ghostty draws the screenshot itself: no screen recording permission, no other windows or menus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 300)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    private var preview: some View {
        VStack(spacing: 12) {
            if let last = shots.last {
                Image(nsImage: last.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .onDrag { NSItemProvider(object: last.image) }
                    .help("Drag the screenshot into another app")
            } else {
                Spacer()
                Image(systemName: "camera.viewfinder").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("No screenshot yet").foregroundStyle(.secondary)
                Spacer()
            }
            if let message = shots.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button("Copy") { shots.copyLast() }
                Button("Save As…") { shots.saveLastAs() }
                if let file = shots.last?.file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }
            .disabled(shots.last == nil)
            .padding(.bottom, 14)
        }
        .background(Color.black.opacity(0.25))
    }
}
