import SwiftUI

/// Compact tabs drawn in the titlebar area by `StripTabsTerminalWindow`.
///
/// Tabs keep a comfortable width instead of stretching across the window, and the strip
/// uses the terminal background so it blends in, including in native fullscreen.
struct TerminalTabStrip: View {
    @ObservedObject var model: TerminalTabStripModel
    let background: Color
    /// The fullscreen titlebar copy is shown regardless of `model.visible`.
    var ignoresVisibility = false

    private let spacing: CGFloat = 4
    private let newTabWidth: CGFloat = 28

    var body: some View {
        if model.visible || ignoresVisibility { strip }
    }

    private var strip: some View {
        GeometryReader { geometry in
            HStack(spacing: spacing) {
                ForEach(model.tabs) { tab in
                    TabItem(model: model, tab: tab, closable: model.tabs.count > 1)
                        .frame(width: tabWidth(available: geometry.size.width))
                }
                NewTabButton { model.newTab() }
                    .frame(width: newTabWidth)
                Spacer(minLength: 0)
            }
            .padding(.leading, model.layout.leadingInset)
            .padding(.trailing, 10)
            .frame(height: geometry.size.height)
        }
        .frame(height: model.layout.height)
        .background(background)
        .opacity(model.isKey ? 1 : 0.65)
        .animation(.easeOut(duration: 0.12), value: model.tabs)
    }

    private func tabWidth(available: CGFloat) -> CGFloat {
        let count = CGFloat(max(model.tabs.count, 1))
        let room = available - model.layout.leadingInset - 10 - newTabWidth - spacing * count
        return min(220, max(64, room / count))
    }

    private struct TabItem: View {
        @ObservedObject var model: TerminalTabStripModel
        let tab: TerminalTabStripModel.Tab
        let closable: Bool
        @State private var hovering = false

        private var fill: Color {
            if tab.selected { return Color.primary.opacity(0.10) }
            return Color.primary.opacity(hovering ? 0.05 : 0)
        }

        var body: some View {
            HStack(spacing: 6) {
                if let color = tab.color.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 7, height: 7)
                }
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .font(.system(size: 12, weight: tab.selected ? .medium : .regular))
            .foregroundStyle(tab.selected ? Color.primary : Color.secondary)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(tab.selected ? 0.10 : 0), lineWidth: 1)
            )
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { model.select(tab.id) }
            .help(tab.title)
            .contextMenu { menu }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(tab.selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(tab.id) }
        }

        /// Shows the close button while hovering, otherwise the tab's shortcut.
        @ViewBuilder private var trailing: some View {
            ZStack {
                if closable && hovering {
                    Button { model.close(tab.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Close Tab")
                    .accessibilityLabel("Close \(tab.title)")
                } else if let shortcut = tab.shortcut {
                    Text(shortcut)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 16)
        }

        @ViewBuilder private var menu: some View {
            Button("Rename Tab…") { model.rename(tab.id) }
            Menu("Tab Color") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button(color.localizedName) { model.setColor(color, for: tab.id) }
                }
            }
            Divider()
            Button("Close Tab") { model.close(tab.id) }
            Button("Close Other Tabs") { model.closeOthers(tab.id) }
                .disabled(!closable)
            Button("Close Tabs to the Right") { model.closeToTheRight(tab.id) }
                .disabled(model.tabs.last?.id == tab.id)
        }
    }

    private struct NewTabButton: View {
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .help("New Tab")
            .accessibilityLabel("New Tab")
        }
    }
}
