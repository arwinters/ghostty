import SwiftUI

/// Lives below the entire split tree, outside the terminal's character grid.
struct StatusPluginBar: View {
    let manifest: String
    let background: Color
    /// `background-opacity`: the bar is as see-through as the terminal above it.
    var opacity: Double = 1
    let surface: Ghostty.SurfaceView?
    @ObservedObject private var host = StatusPluginHost.shared

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    if let surface { ActiveDirectory(surface: surface) }
                    ForEach(items(.leading)) { WidgetView(widget: $0.widget) }
                    ForEach(Array(host.errors.enumerated()), id: \.offset) { _, message in
                        Text(message).foregroundColor(.orange)
                    }
                    if !host.errors.isEmpty {
                        TextButton("Restart plugins", help: "Restart status plugins without closing terminals") {
                            host.restart()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
            }

            pinned(items(.trailing))

            if SessionManager.shared.enabled || PluginManager.enabled {
                Separator()
                ControlButtons()
            }

            let end = items(.end)
            if !end.isEmpty {
                Separator()
                pinned(end)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(height: 30)
        .background(TerminalChromeBackground(color: background, opacity: opacity))
        .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1) }
        // One shared host: plugins run once for all windows and stop with the last bar.
        .onAppear { host.acquire(manifest: manifest) }
        .onChange(of: manifest) { host.use(manifest: $0) }
        .onDisappear { host.release() }
    }

    /// tmux session and its active pane's directory, for panes opened by the tmux plugin.
    private struct TmuxLocation: View {
        let pane: TmuxPane
        @ObservedObject private var tmux = TmuxPlugin.shared

        private var name: String {
            pane.session.hasPrefix(TmuxCommand.sessionPrefix)
                ? String(pane.session.dropFirst(TmuxCommand.sessionPrefix.count)) : pane.session
        }

        var body: some View {
            let path = (tmux.paths[pane.session] ?? pane.directory) as NSString
            HStack(spacing: 6) {
                Label("tmux", systemImage: "rectangle.split.3x1")
                    .foregroundColor(Color(red: 0.31, green: 0.98, blue: 0.48))
                Text(name).foregroundColor(.secondary)
                Text(path.abbreviatingWithTildeInPath)
                    .foregroundColor(Color(red: 0.36, green: 0.78, blue: 1))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .frame(maxWidth: 380, alignment: .leading)
            .help("tmux session \(pane.session) · \(path)\nDetach: Ctrl-b d, or right-click › tmux › Detach Session")
            .accessibilityElement(children: .combine)
        }
    }

    private func items(_ placement: StatusPluginPlacement) -> [StatusPluginHost.Item] {
        host.items.filter { $0.placement == placement }
    }

    /// Widgets that never scroll away: the right-hand zones of the bar.
    @ViewBuilder private func pinned(_ items: [StatusPluginHost.Item]) -> some View {
        if !items.isEmpty {
            HStack(spacing: 16) {
                ForEach(items) { WidgetView(widget: $0.widget) }
            }
            .padding(.horizontal, 10)
            .fixedSize()
            .layoutPriority(1)
        }
    }

    private struct Separator: View {
        var body: some View {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1, height: 16)
        }
    }

    private struct WidgetView: View {
        let widget: StatusPluginFrame.Widget

        var body: some View {
            HStack(spacing: 6) {
                if !widget.label.isEmpty {
                    Text(widget.label).foregroundColor(.secondary)
                }
                if let symbol = widget.symbol {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 14))
                        .frame(height: 16)
                        .accessibilityHidden(true)
                }
                if let level = widget.level {
                    VStack(alignment: .leading, spacing: 1) {
                        MeterRow(text: widget.value, level: level, color: widgetColor(widget.color))
                        if let text = widget.mirrorValue {
                            MeterRow(text: text, level: widget.mirrorLevel,
                                     color: widgetColor(widget.mirrorColor ?? widget.color))
                        }
                    }
                } else if let mirror = widget.mirror {
                    let mirrorColor = widgetColor(widget.mirrorColor ?? widget.color)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(widget.value)
                        Text(widget.mirrorValue ?? "").foregroundColor(mirrorColor)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    MirrorGraph(top: widget.bars ?? widget.history ?? [], bottom: mirror,
                                blocks: widget.bars != nil,
                                topColor: widgetColor(widget.color), bottomColor: mirrorColor)
                        .accessibilityHidden(true)
                } else {
                    Text(widget.value).monospacedDigit()
                    if let bars = widget.bars, !bars.isEmpty {
                        BlockGraph(values: bars,
                                   colors: (widget.barColors ?? []).map(widgetColor),
                                   color: widgetColor(widget.color))
                            .accessibilityHidden(true)
                    } else if let history = widget.history, history.count > 1 {
                        Sparkline(values: history)
                            .stroke(widgetColor(widget.color), lineWidth: 1.5)
                            .frame(width: 70, height: 18)
                            .accessibilityHidden(true)
                    }
                }
            }
            .foregroundColor(widgetColor(widget.color))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }

        private var accessibilityText: String {
            let value = [widget.value, widget.mirrorValue].compactMap { $0 }.joined(separator: ", ")
            return widget.label.isEmpty ? value : "\(widget.label): \(value)"
        }
    }

    /// One row of a two-row widget: a value and its fill level.
    private struct MeterRow: View {
        let text: String
        let level: Double?
        let color: Color

        var body: some View {
            HStack(spacing: 5) {
                Text(text)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(color)
                if let level {
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.2))
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, 44 * level))
                    }
                    .frame(width: 44, height: 4)
                }
            }
        }
    }

    /// Two series on one baseline: `top` grows up, `bottom` grows down, for example
    /// download over upload. Blocks for recent samples, or filled areas for a history.
    private struct MirrorGraph: View {
        let top: [Double]
        let bottom: [Double]
        let blocks: Bool
        let topColor: Color
        let bottomColor: Color

        private let half: CGFloat = 10

        var body: some View {
            Group {
                if blocks {
                    HStack(spacing: 1) {
                        ForEach(0..<max(top.count, bottom.count), id: \.self) { index in
                            VStack(spacing: 1) {
                                block(index < top.count ? top[index] : 0, color: topColor, alignment: .bottom)
                                block(index < bottom.count ? bottom[index] : 0, color: bottomColor, alignment: .top)
                            }
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: top)
                } else {
                    ZStack {
                        Area(values: top, upward: true).fill(topColor.opacity(0.6))
                        Area(values: top, upward: true, outline: true).stroke(topColor, lineWidth: 1.5)
                        Area(values: bottom, upward: false).fill(bottomColor.opacity(0.6))
                        Area(values: bottom, upward: false, outline: true).stroke(bottomColor, lineWidth: 1.5)
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 0.5)
                    }
                    .frame(width: 70, height: half * 2 + 1)
                }
            }
        }

        private func block(_ value: Double, color: Color, alignment: Alignment) -> some View {
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.16))
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(colors: [color.opacity(0.75), color],
                                         startPoint: alignment == .bottom ? .bottom : .top,
                                         endPoint: alignment == .bottom ? .top : .bottom))
                    .frame(height: value > 0 ? max(1.5, half * value) : 0)
            }
            .frame(width: 3, height: half)
        }

        /// A history drawn from the middle line: up for `upward`, down otherwise.
        private struct Area: Shape {
            let values: [Double]
            let upward: Bool
            var outline = false

            func path(in rect: CGRect) -> Path {
                Path { path in
                    guard values.count > 1 else { return }
                    let middle = rect.midY
                    let height = rect.height / 2
                    func point(_ index: Int) -> CGPoint {
                        let y = height * values[index]
                        return CGPoint(x: rect.width * Double(index) / Double(values.count - 1),
                                       y: upward ? middle - y : middle + y)
                    }
                    if outline {
                        path.move(to: point(0))
                    } else {
                        path.move(to: CGPoint(x: 0, y: middle))
                        path.addLine(to: point(0))
                    }
                    for index in 1..<values.count { path.addLine(to: point(index)) }
                    if !outline {
                        path.addLine(to: CGPoint(x: rect.width, y: middle))
                        path.closeSubpath()
                    }
                }
            }
        }
    }

    /// One small vertical block per value: per CPU core, or the most recent samples.
    private struct BlockGraph: View {
        let values: [Double]
        /// Optional color per block; falls back to `color`.
        let colors: [Color]
        let color: Color

        private let height: CGFloat = 14

        var body: some View {
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    let tint = index < colors.count ? colors[index] : color
                    // A small gap where the color changes, e.g. between core types.
                    let newGroup = index > 0 && index < colors.count && colors[index] != colors[index - 1]
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.16))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(LinearGradient(colors: [tint.opacity(0.6), tint],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(height: value > 0 ? max(2, height * value) : 0)
                    }
                    .frame(width: 3, height: height)
                    .padding(.leading, newGroup ? 3 : 0)
                }
            }
            .animation(.easeOut(duration: 0.25), value: values)
        }
    }

    private struct TextButton: View {
        let title: String
        let help: String
        let action: () -> Void

        init(_ title: String, help: String, action: @escaping () -> Void) {
            self.title = title
            self.help = help
            self.action = action
        }

        var body: some View {
            Button(title, action: action)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .focusable(false)
                .fixedSize()
                .help(help)
        }
    }

    /// Session state and the Sessions / Plugins entry points on the trailing edge.
    private struct ControlButtons: View {
        @ObservedObject private var sessions = SessionManager.shared

        private var failed: Bool { sessions.message.hasPrefix("Session recovery error") }

        var body: some View {
            HStack(spacing: 12) {
                if SessionManager.shared.enabled {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(failed ? Color.orange : Color.green.opacity(0.8))
                            .frame(width: 6, height: 6)
                        TextButton(sessions.activeName ?? "Sessions", help: "Workspace · \(sessions.message) — open the Session Manager (⇧⌘S)") {
                            sessions.showSessions()
                        }
                    }
                }
                if PluginManager.enabled {
                    TextButton("Plugins", help: "Open the Plugin Manager (⌥⌘P)") {
                        PluginManager.shared.showManager()
                    }
                }
            }
            .padding(.horizontal, 10)
            .fixedSize()
            .layoutPriority(1)
        }
    }

    private struct ActiveDirectory: View {
        @ObservedObject var surface: Ghostty.SurfaceView

        private var directory: String? {
            surface.pwd.flatMap { $0.isEmpty ? nil : $0 }
        }

        var body: some View {
            // tmux does not forward the shell's directory reports, so ask tmux instead.
            if let tmux = TmuxPlugin.shared.pane(for: surface.id) {
                TmuxLocation(pane: tmux)
            } else {
                directoryLabel
            }
        }

        private var directoryLabel: some View {
            Label(directory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Directory unavailable",
                  systemImage: "folder")
                .foregroundColor(Color(red: 0.36, green: 0.78, blue: 1))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .leading)
                .help(directory ?? "Waiting for the active shell to report its working directory")
                .accessibilityLabel("Active terminal directory: \(directory ?? "unavailable")")
        }
    }

    fileprivate static func color(_ hex: String) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0x5cc8ff
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    private struct Sparkline: Shape {
        let values: [Double]
        func path(in rect: CGRect) -> Path {
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: rect.width * Double(index) / Double(values.count - 1),
                                        y: rect.height * (1 - value))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
        }
    }
}

private func widgetColor(_ hex: String) -> Color { StatusPluginBar.color(hex) }
