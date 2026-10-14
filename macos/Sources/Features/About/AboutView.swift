import SwiftUI

struct AboutView: View {
    private let githubURL = URL(string: "https://github.com/ghostty-org/ghostty")
    private let docsURL = URL(string: "https://ghostty.org/docs")

    /// Read the commit from the bundle.
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? { Bundle.main.infoDictionary?["GhosttyCommit"] as? String }
    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    private var statusLabVersion: String? { metadata("StatusLabVersion") }
    private func metadata(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }

    private enum VersionConfig {
        case stable(version: String)
        case tip(commit: String?)
        case other(String)
        case none

        init(version: String?) {
            guard let version else { self = .none; return }
            if version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
                self = .stable(version: version)
                return
            }
            if version.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil {
                self = .tip(commit: version)
                return
            }
            self = .other(version)
        }

        var url: URL? {
            switch self {
            case .stable(let version):
                let slug = version.replacingOccurrences(of: ".", with: "-")
                return URL(string: "https://ghostty.org/docs/install/release-notes/\(slug)")
            default:
                return nil
            }
        }
    }

    private var versionConfig: VersionConfig { VersionConfig(version: version) }

    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    // This creates a background style similar to the Apple "About My Mac" Window
    private struct VisualEffectBackground: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
        let isEmphasized: Bool

        init(material: NSVisualEffectView.Material,
             blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
             isEmphasized: Bool = false) {
            self.material = material
            self.blendingMode = blendingMode
            self.isEmphasized = isEmphasized
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
            nsView.isEmphasized = isEmphasized
        }

        func makeNSView(context: Context) -> NSVisualEffectView {
            let visualEffect = NSVisualEffectView()
            visualEffect.autoresizingMask = [.width, .height]
            return visualEffect
        }
    }

    var body: some View {
        VStack(alignment: .center) {
            CyclingIconView()

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text(statusLabVersion == nil ? "Ghostty" : metadata("CFBundleDisplayName") ?? "Ghostty Status Lab")
                        .bold()
                        .font(.title)
                    Text(statusLabVersion == nil
                         ? "Fast, native, feature-rich terminal \nemulator pushing modern features."
                         : "Experimental local build based on Ghostty.\nNative status plugins and automatic recovery.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let statusLabVersion {
                        PropertyRow(label: "Status Lab", text: statusLabVersion)
                        PropertyRow(label: "Build number", text: build ?? "Unknown")
                        PropertyRow(label: "Built (UTC)", text: metadata("StatusLabBuildDate") ?? "Unknown")
                        PropertyRow(label: "Ghostty core", text: metadata("StatusLabGhosttyVersion") ?? "Unknown")
                        if let base = metadata("StatusLabUpstreamCommit") {
                            PropertyRow(label: "Ghostty base", text: String(base.prefix(7)),
                                        url: githubURL?.appendingPathComponent("commit/\(base)"))
                        }
                        if let source = metadata("StatusLabSourceCommit") {
                            PropertyRow(label: "Plugin base", text: String(source.prefix(7)),
                                        url: URL(string: "https://github.com/arwinters/ghostty/commit/\(source)"))
                        }
                        PropertyRow(label: "Source state", text: metadata("StatusLabSourceState") ?? "Unknown")
                        PropertyRow(label: "Plugin protocol", text: "1")
                    } else {
                        switch versionConfig {
                        case .stable(let version):
                            PropertyRow(label: "Version", text: version, url: versionConfig.url)
                        case .tip:
                            PropertyRow(label: "Version", text: "Tip Release")
                        case .other(let v):
                            PropertyRow(label: "Version", text: v)
                        case .none:
                            EmptyView()
                        }
                        if let build {
                            PropertyRow(label: "Build", text: build)
                        }
                        if let commit, commit != "",
                           let url = githubURL?.appendingPathComponent("/commits/\(commit)") {
                            PropertyRow(label: "Commit", text: commit, url: url)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Link("Docs", destination: url)
                            .help("Ghostty documentation")
                    }
                    if statusLabVersion != nil, let url = URL(string: "https://github.com/arwinters/ghostty") {
                        Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                        Link("Status Lab", destination: url)
                            .help("Status Lab source code")
                    }
                    if let url = githubURL {
                        Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                        Link("Ghostty", destination: url)
                            .help("Original Ghostty source code")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.callout)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)

                if let copy = self.copyright {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 256)
        .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }

    private struct PropertyRow: View {
        private let label: String
        private let text: String
        private let url: URL?

        init(label: String, text: String, url: URL? = nil) {
            self.label = label
            self.text = text
            self.url = url
        }

        @ViewBuilder private var textView: some View {
            Text(text)
                .frame(width: 170, alignment: .leading)
                .padding(.leading, 2)
                .tint(.secondary)
                .opacity(0.8)
                .monospaced()
        }

        var body: some View {
            HStack(spacing: 4) {
                Text(label)
                    .frame(width: 126, alignment: .trailing)
                    .padding(.trailing, 2)
                if let url {
                    Link(destination: url) {
                        textView
                    }
                } else {
                    textView
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
