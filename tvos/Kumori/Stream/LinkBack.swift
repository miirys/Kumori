import SwiftUI

/// What Menu does on each screen, for controllers relayed by Kumori Link: they can't send a
/// real Menu press, so `onBack` registers the same action here as well as with
/// `onExitCommand`.
@MainActor
final class LinkBack {
    static let shared = LinkBack()

    private struct Entry {
        var frame: CGRect
        var action: () -> Void
        var order: Int
    }

    private var entries: [UUID: Entry] = [:]
    private var counter = 0

    func set(_ id: UUID, frame: CGRect, action: @escaping () -> Void) {
        counter += 1
        let order = entries[id]?.order ?? counter
        entries[id] = Entry(frame: frame, action: action, order: order)
    }

    func remove(_ id: UUID) { entries[id] = nil }

    /// The innermost screen whose frame holds the focused item, or the newest one when the
    /// focused item's frame isn't known.
    func action(around focused: CGRect?) -> (() -> Void)? {
        let live = entries.values.filter { $0.frame.width > 1 && $0.frame.height > 1 }
        if let f = focused {
            let p = CGPoint(x: f.midX, y: f.midY)
            let holding = live.filter { $0.frame.contains(p) }
            return holding.min { area($0.frame) < area($1.frame) || (area($0.frame) == area($1.frame) && $0.order > $1.order) }?.action
        }
        return live.max { $0.order < $1.order }?.action
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}

private struct OnBack: ViewModifier {
    let action: () -> Void
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onExitCommand(perform: action)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                LinkBack.shared.set(id, frame: frame, action: action)
            }
            .onDisappear { LinkBack.shared.remove(id) }
    }
}

extension View {
    /// Menu on the remote, and B on a controller relayed by Kumori Link.
    func onBack(perform action: @escaping () -> Void) -> some View {
        modifier(OnBack(action: action))
    }
}
