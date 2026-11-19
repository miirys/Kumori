import SwiftUI

/// Asks before ending a running game (D05). One primitive for every route that can end a
/// session: Home's running row, the detail screen and the in-stream menu.
///
/// - Cancel has focus when it opens, so a reflexive Select does no harm.
/// - Back and Cancel call `cancel` and never `end`.
/// - `end` is called at most once per presentation, however fast Select is pressed.
///
/// Attach it with `.endSessionConfirmation(isPresented:title:onEnd:)` on the screen that asks.
/// That also disables the screen underneath, so focus can't wander out of the dialog.
struct EndSessionConfirmation: View {
    /// The game's name, so the question says which game ends.
    let title: String
    let cancel: () -> Void
    let end: () -> Void

    private enum Choice: Hashable { case cancel, end }

    @FocusState private var focus: Choice?
    @State private var done = false
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        ZStack {
            Color.black.opacity(0.66)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TVTokens.group) {
                Text("End \(title)?")
                    .font(TVType.section)
                    .foregroundStyle(TVColor.primary)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                Text("The game closes on GeForce NOW. Anything you haven't saved in the game is lost.")
                    .font(TVType.body)
                    .foregroundStyle(TVColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: TVTokens.group) {
                    Button("Cancel", action: dismiss)
                        .focused($focus, equals: .cancel)
                        .accessibilityIdentifier("confirm-cancel")
                    Button("End Game", role: .destructive, action: confirm)
                        .focused($focus, equals: .end)
                        .accessibilityIdentifier("confirm-end")
                }
                .padding(.top, TVTokens.small)
                .focusSection()
            }
            .padding(48)
            .frame(width: TVTokens.dialogWidth, alignment: .leading)
            .tvSurface(.overlay, radius: 36)
            .tvAppear()
        }
        .defaultFocus($focus, .cancel)
        .task {
            // The screen underneath is disabled in the same update that shows the dialog, so
            // the focus engine may not take a request straight away. Ask until it lands, and
            // stop as soon as anything in the dialog has focus.
            for wait in [30, 150, 400, 800] {
                try? await Task.sleep(for: .milliseconds(wait))
                if focus != nil { return }
                focus = .cancel
            }
        }
        .onExitCommand(perform: dismiss)
        .accessibilityIdentifier("end-session-confirmation")
    }

    private func dismiss() {
        guard !done else { return }
        done = true
        cancel()
    }

    private func confirm() {
        guard !done else { return }
        done = true
        end()
    }
}

extension View {
    /// Shows `EndSessionConfirmation` over this view while `isPresented` is true. The view
    /// underneath is disabled meanwhile, so the dialog is the only place focus can go. Put it
    /// on a view that fills the screen.
    func endSessionConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        onCancel: @escaping () -> Void = {},
        onEnd: @escaping () -> Void
    ) -> some View {
        disabled(isPresented.wrappedValue)
            .overlay {
                if isPresented.wrappedValue {
                    EndSessionConfirmation(
                        title: title,
                        cancel: {
                            isPresented.wrappedValue = false
                            onCancel()
                        },
                        end: {
                            isPresented.wrappedValue = false
                            onEnd()
                        }
                    )
                }
            }
    }
}
