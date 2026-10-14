import AppKit
import SwiftUI

/// A sidebar entry of a manager window.
struct ManagerLayoutRow {
    let title: String
    let symbol: String
    var badge: String?
}

/// Shared look of the Plugin Manager and Session Manager windows: a sidebar, a grouped form
/// and a footer. Uses a plain titled window instead of NavigationSplitView, whose toolbar
/// lets the form scroll underneath the titlebar where it can no longer be clicked.
struct ManagerLayout<Page: Hashable & Identifiable, Detail: View, Footer: View>: View {
    let pages: [Page]
    @Binding var selection: Page
    let row: (Page) -> ManagerLayoutRow
    @ViewBuilder let detail: (Page) -> Detail
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<Page?>(get: { selection }, set: { if let value = $0 { selection = value } })) {
                ForEach(pages) { page in
                    let info = row(page)
                    HStack {
                        Label(info.title, systemImage: info.symbol)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let badge = info.badge {
                            Text(badge)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)

            Divider()

            VStack(spacing: 0) {
                Form { detail(selection) }
                    .formStyle(.grouped)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) { footer() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

enum ManagerWindow {
    /// A standard titled window for a manager view.
    static func make<Root: View>(title: String, autosave: String, rootView: Root) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.setContentSize(NSSize(width: 780, height: 560))
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.center()
        window.setFrameAutosaveName(autosave)
        return window
    }
}
