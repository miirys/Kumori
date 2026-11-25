import SwiftUI

/// Asks before ending a running game (D05). One primitive for every route that can end a
/// session: Home's running row, the detail screen and the in-stream menu.
///
/// - Cancel has focus when it opens, so a reflexive Select does no harm.
/// - Back and Cancel call `cancel` and never `end`.
/// - `end` is called at most once per presentation, however fast Select is pressed.
///
/// Attach it with `.endSessionConfirmation(isPresented:title:onEnd:)` on the screen that asks.
/// It is presented as a full-screen modal, so focus can't wander out of the dialog.
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
            // Light enough that the game shows, blurred, through the glass.
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                TVPowerGlyph(size: 96)
                    .padding(.bottom, 36)
                Text("End \(title)?")
                    .font(TVType.section)
                    .foregroundStyle(TVColor.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                Text("Unsaved progress will be lost.")
                    .font(TVType.body)
                    .foregroundStyle(TVColor.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                HStack(spacing: 20) {
                    // The same system glass as the End Game button that opened this, equal
                    // widths and heights, so no flat grey pill sits on the glass.
                    Button(action: dismiss) {
                        Text("Cancel")
                            .frame(minWidth: 200, minHeight: GlassButton.label)
                    }
                    .modifier(GlassButton())
                    .fixedSize()
                    .focused($focus, equals: .cancel)
                    .accessibilityIdentifier("confirm-cancel")
                    // Not the system's destructive look, which floods the glass red. Apple's
                    // own pattern for a destructive choice on glass: glass with a faint warm
                    // tint and a soft red word at rest; focused, the same light platter as
                    // Cancel with the word in a deep system red (EndGlass below).
                    Button(action: confirm) {
                        EndGameLabel()
                            .frame(minWidth: 200, minHeight: GlassButton.label)
                    }
                    .modifier(EndGlass())
                    .fixedSize()
                    .accessibilityLabel("End Game")
                    .accessibilityHint("Ends the game. Unsaved progress will be lost.")
                    .focused($focus, equals: .end)
                    .accessibilityIdentifier("confirm-end")
                }
                .padding(.top, 44)
                .focusSection()
            }
            .padding(.horizontal, 64)
            .padding(.top, 52)
            .padding(.bottom, 56)
            .frame(width: TVTokens.dialogWidth)
            .tvLiquidGlass(radius: 48)
            .shadow(color: .black.opacity(0.5), radius: 60, y: 30)
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
        .onBack(perform: dismiss)
        // No identifier on this container: SwiftUI hands a container's identifier down to
        // every element inside, which would hide `confirm-cancel` and `confirm-end`.
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
    /// Shows `EndSessionConfirmation` while `isPresented` is true. It is presented full screen
    /// over this view, so the focus engine moves into it the way it does for any modal, and
    /// nothing underneath can take focus. `onEnd` or `onCancel` runs once the dialog has gone,
    /// so focus is back on this screen when it does.
    func endSessionConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        onCancel: @escaping () -> Void = {},
        onEnd: @escaping () -> Void
    ) -> some View {
        modifier(EndSessionPresenter(isPresented: isPresented, title: title, onCancel: onCancel, onEnd: onEnd))
    }
}

private struct EndSessionPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let onCancel: () -> Void
    let onEnd: () -> Void
    @State private var confirmed = false
    /// End already ran for this presentation (the fallback beat the dismissal), so the
    /// dismissal that follows must report neither End nor Cancel.
    @State private var handled = false

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented, onDismiss: {
            // However it closed (Cancel, Back, or the system), only a press of End ends the game.
            if handled {
                handled = false
            } else if confirmed {
                confirmed = false
                onEnd()
            } else {
                onCancel()
            }
        }) {
            EndSessionConfirmation(
                title: title,
                cancel: { isPresented = false },
                end: {
                    confirmed = true
                    isPresented = false
                    // Don't rely on the cover's dismissal alone: presented over the stream it
                    // didn't always report back, and the session was never ended. Whichever
                    // comes first ends it, once.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        guard confirmed else { return }
                        confirmed = false
                        // The cover may still report its dismissal after this; that report
                        // is then ignored. If it already reported, it saw `confirmed` and ended.
                        handled = true
                        onEnd()
                    }
                }
            )
            .presentationBackground(.clear)
            // A dismissal that never reported must not swallow the next one's.
            .onAppear { handled = false }
        }
    }
}

/// The End Game button's colours: Apple's dark-mode system red, softened for words on glass.
enum EndGlassInk {
    /// Words at rest: a soft coral red that reads on dark glass without shouting.
    static let rest = Color(red: 1, green: 0x6B / 255, blue: 0x63 / 255)
    /// The glass's tint: system red (#FF453A), let through the glass at rest.
    static let glow = Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)
    /// Words on the light focused platter: a deep system red that holds its contrast there.
    static let focused = Color(red: 0xD7 / 255, green: 0x1E / 255, blue: 0x1B / 255)
}

/// "End Game", coral on the tinted glass at rest, deep red on the focused platter.
private struct EndGameLabel: View {
    @Environment(\.isFocused) private var focused

    var body: some View {
        Text("End Game")
            .foregroundStyle(focused ? EndGlassInk.focused : EndGlassInk.rest)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

/// The system's Liquid Glass button, the same size and shape as Cancel beside it, with a
/// warm red tint through the glass at rest. Before tvOS 26, the app's own glass.
private struct EndGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(EndGlassInk.glow.opacity(0.55))
        } else {
            content.buttonStyle(TVActionStyle(shape: .capsule, height: 86, alignment: .center))
        }
    }
}
