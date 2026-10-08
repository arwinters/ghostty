import SwiftUI

/// Lives below the entire split tree, outside the terminal's character grid.
struct StatusPluginBar: View {
    let manifest: String
    let background: Color
    @StateObject private var host = StatusPluginHost()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(host.items) { item in
                    let widget = item.widget
                    HStack(spacing: 6) {
                        Text(widget.label).foregroundColor(.secondary)
                        Text(widget.value).monospacedDigit()
                        if let history = widget.history, history.count > 1 {
                            Sparkline(values: history)
                                .stroke(color(widget.color), lineWidth: 1.5)
                                .frame(width: 70, height: 18)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundColor(color(widget.color))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(widget.label): \(widget.value)")
                }
                ForEach(Array(host.errors.enumerated()), id: \.offset) { _, message in
                    Text(message).foregroundColor(.orange)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .frame(height: 30)
        .background(background)
        .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1) }
        .onAppear { host.start(manifest: manifest) }
        .onChange(of: manifest) { host.start(manifest: $0) }
        .onDisappear { host.stop() }
    }

    private func color(_ hex: String) -> Color {
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
