import SwiftUI

/// Typing into the game from the in-game menu: a sign-in, a chat line, a name. The Apple TV's
/// own keyboard takes the text, so the Siri Remote's microphone button dictates into it and a
/// controller can type on it. Send types it on the rig as key presses.
struct StreamKeyboard: View {
    let close: () -> Void
    @EnvironmentObject private var player: Player
    @State private var text = ""
    @State private var sentNote: String?
    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Label("Type in the Game", systemImage: "keyboard")
                    .font(TVType.section)
                    .foregroundStyle(TVColor.primary)
                    .accessibilityAddTraits(.isHeader)
                Text("Hold the mic button to dictate")
                    .font(TVType.callout)
                    .foregroundStyle(TVColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                TextField("Text, an email or a password", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: "field")
                    .padding(.top, 32)
                    .accessibilityIdentifier("keyboard-field")

                HStack(spacing: 18) {
                    Button { send(enter: false) } label: { Label("Send", systemImage: "paperplane.fill") }
                        .focused($focus, equals: "send")
                        .accessibilityIdentifier("keyboard-send")
                    Button { send(enter: true) } label: { Label("Send and Enter", systemImage: "return") }
                        .accessibilityIdentifier("keyboard-send-enter")
                }
                .buttonStyle(TVActionStyle(shape: .capsule, alignment: .center))
                .fixedSize()
                .disabled(text.isEmpty)
                .padding(.top, 28)
                .focusSection()

                Text("Case")
                    .font(TVType.caption.weight(.semibold))
                    .foregroundStyle(TVColor.tertiary)
                    .padding(.top, 32)
                HStack(spacing: 14) {
                    Button { setCase(.lowercased) } label: { Label("all lowercase", systemImage: "textformat.size.smaller") }
                        .accessibilityIdentifier("keyboard-lowercase")
                    Button { setCase(.capitalizedFirst) } label: { Label("Capitalize first", systemImage: "textformat") }
                        .accessibilityIdentifier("keyboard-capitalize")
                }
                .buttonStyle(TVActionStyle(shape: .capsule, height: 68, alignment: .center))
                .fixedSize()
                .disabled(text.isEmpty)
                .padding(.top, 14)
                .focusSection()

                Text("Keys")
                    .font(TVType.caption.weight(.semibold))
                    .foregroundStyle(TVColor.tertiary)
                    .padding(.top, 32)
                HStack(spacing: 14) {
                    key("Enter", "return", KeyText.enter)
                    key("Delete", "delete.left", KeyText.backspace)
                    key("Tab", "arrow.right.to.line", KeyText.tab)
                    key("Esc", "escape", KeyText.escape)
                }
                .buttonStyle(TVActionStyle(shape: .capsule, height: 68, alignment: .center))
                .fixedSize()
                .padding(.top, 14)
                .focusSection()

                Text(sentNote ?? " ")
                    .font(TVType.caption)
                    .foregroundStyle(TVColor.tertiary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: sentNote)
                    .padding(.top, 24)
            }
            .padding(56)
            .frame(width: 1040, alignment: .leading)
            .tvLiquidGlass(radius: 48)
            .shadow(color: .black.opacity(0.45), radius: 50, y: 24)
        }
        .defaultFocus($focus, "field")
        .onBack(perform: close)
    }

    private func key(_ title: String, _ icon: String, _ k: KeyText.Key) -> some View {
        Button {
            player.press(k)
            sentNote = "Pressed \(title)"
        } label: {
            Label(title, systemImage: icon)
        }
        .accessibilityIdentifier("keyboard-key-\(title.lowercased())")
    }

    private enum CaseChange { case lowercased, capitalizedFirst }

    /// Rewrite the field's text before it's sent. Handy when the game's field is case-sensitive
    /// and the Apple TV keyboard or dictation capitalised something it shouldn't have.
    private func setCase(_ change: CaseChange) {
        guard !text.isEmpty else { return }
        switch change {
        case .lowercased:
            text = text.lowercased()
        case .capitalizedFirst:
            let lower = text.lowercased()
            text = lower.prefix(1).uppercased() + lower.dropFirst()
        }
        focus = "field"
    }

    private func send(enter: Bool) {
        guard !text.isEmpty else { return }
        let count = text.count
        // Emoji and letters a US keyboard has no key for (é, ß) can't be typed on the rig.
        let typed = KeyText.keys(text).count
        player.typeText(text, enter: enter)
        text = ""
        let what = typed == count ? "\(count) character\(count == 1 ? "" : "s")"
            : "\(typed) of \(count) characters (the rest have no key on a US keyboard)"
        sentNote = "Typed \(what)\(enter ? " and pressed Enter" : "")"
        focus = "field"
    }
}
