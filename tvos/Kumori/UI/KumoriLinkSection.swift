import SwiftUI

/// Settings › Controllers › Kumori Link: pick the Android box that relays its controllers,
/// then see whether it's connected.
struct KumoriLinkSection: View {
    @ObservedObject private var link = KumoriLink.shared
    /// Forget and Use replace the rows they sit in. Focus is handed to the row that takes
    /// their place, rather than left to fall out of the page.
    @FocusState private var focused: String?

    var body: some View {
        Section("Kumori Link") {
            if let box = link.box {
                Button {} label: { SettingsRow(title: box.name, value: status) }
                    .focused($focused, equals: "box")
                    .accessibilityIdentifier("link-box")
                if link.status == .connected {
                    Button {} label: { SettingsRow(title: "Controllers", value: "\(link.controllers)") }
                    if let ms = link.roundTripMs {
                        Button {} label: { SettingsRow(title: "Round Trip", value: String(format: "%.1f ms", ms)) }
                    }
                }
                Button { link.forget(); land() } label: { SettingsRow(title: "Forget", icon: "xmark") }
                    .accessibilityIdentifier("link-forget")
            } else {
                if link.found.isEmpty {
                    Button {} label: { SettingsRow(title: link.searching ? "Searching\u{2026}" : "None Found") }
                        .focused($focused, equals: "search")
                } else {
                    ForEach(link.found) { b in
                        Button { link.choose(b); land() } label: { SettingsRow(title: b.name, value: "Use") }
                            .focused($focused, equals: "found-\(b.name)")
                            .accessibilityIdentifier("link-found-\(b.name)")
                    }
                }
            }
        }
        .onAppear { if link.box == nil { link.search() } }
        .onDisappear { link.stopSearch() }
        .onChange(of: link.box) { _, box in if box == nil { link.search() } else { link.stopSearch() } }
    }

    /// Puts focus on the first row of the section once its new rows are there.
    private func land() {
        Task { @MainActor in
            for wait in [50, 150] {
                try? await Task.sleep(for: .milliseconds(wait))
                if link.box != nil { focused = "box" }
                else { focused = link.found.first.map { "found-\($0.name)" } ?? "search" }
            }
        }
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
