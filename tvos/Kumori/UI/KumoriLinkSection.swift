import SwiftUI

/// Settings › Controllers › Kumori Link: pick the Android box that relays its controllers,
/// then see whether it's connected.
struct KumoriLinkSection: View {
    @ObservedObject private var link = KumoriLink.shared

    var body: some View {
        Section("Kumori Link") {
            if let box = link.box {
                Button {} label: { SettingsRow(title: box.name, value: status) }
                    .accessibilityIdentifier("link-box")
                if link.status == .connected {
                    Button {} label: { SettingsRow(title: "Controllers", value: "\(link.controllers)") }
                    if let ms = link.roundTripMs {
                        Button {} label: { SettingsRow(title: "Round Trip", value: String(format: "%.1f ms", ms)) }
                    }
                }
                Button { link.forget() } label: { SettingsRow(title: "Forget", icon: "xmark") }
                    .accessibilityIdentifier("link-forget")
            } else {
                if link.found.isEmpty {
                    Button {} label: { SettingsRow(title: link.searching ? "Searching\u{2026}" : "None Found") }
                } else {
                    ForEach(link.found) { b in
                        Button { link.choose(b) } label: { SettingsRow(title: b.name, value: "Use") }
                            .accessibilityIdentifier("link-found-\(b.name)")
                    }
                }
            }
        }
        .onAppear { if link.box == nil { link.search() } }
        .onDisappear { link.stopSearch() }
        .onChange(of: link.box) { _, box in if box == nil { link.search() } else { link.stopSearch() } }
    }

    private var status: String {
        switch link.status {
        case .off: return "Off"
        case .connecting: return "Connecting\u{2026}"
        case .connected: return "Connected"
        case .lost: return "Not Found"
        }
    }
}
