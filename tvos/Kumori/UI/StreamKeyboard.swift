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
                Text("Click the field to type, or hold the microphone button on the Siri Remote to dictate.")
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

                Text("Keys")
                    .font(TVType.caption.weight(.semibold))
                    .foregroundStyle(TVColor.tertiary)
                    .padding(.top, 36)
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

    private func send(enter: Bool) {
        guard !text.isEmpty else { return }
        let count = text.count
        player.type(text, enter: enter)
        text = ""
        sentNote = "Typed \(count) character\(count == 1 ? "" : "s")\(enter ? " and pressed Enter" : "")"
        focus = "field"
    }
}
