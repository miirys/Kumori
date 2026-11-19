import Foundation

/// Remembers where the person was on each tab, so Back from a detail screen puts focus on the
/// tile that opened it, and switching tabs returns to the last place on that tab (D04).
///
/// It stores stable game and shelf IDs, never indexes or view identities, so it survives a
/// reload that reorders or rebuilds the page. Keep one in the root view's `@State` and let
/// each tab read and write its own entry.
struct BrowseMemory: Equatable {
    /// One remembered place: which shelf (or grid) and which item in it.
    struct Origin: Hashable {
        let section: String
        let item: String
    }

    private(set) var origins: [String: Origin] = [:]
    /// The order each section's items were in when the origin was saved, to find a neighbour
    /// if the item disappears.
    private var orders: [String: [String]] = [:]

    /// Note that `item` in `section` was opened from `tab`, with the section's current order.
    mutating func remember(tab: String, section: String, item: String, order: [String]) {
        origins[tab] = Origin(section: section, item: item)
        orders[tab] = order
    }

    func origin(in tab: String) -> Origin? { origins[tab] }

    /// The item to focus when coming back to `tab`, given what the section shows now.
    func restoreTarget(in tab: String, current: [String]) -> String? {
        Self.restoreTarget(remembered: origins[tab]?.item, previous: orders[tab] ?? [], current: current)
    }

    mutating func forget(tab: String) {
        origins[tab] = nil
        orders[tab] = nil
    }

    /// The remembered item if it is still there. Otherwise its nearest surviving neighbour in
    /// the old order (the one after it first, then the one before), then the first item.
    static func restoreTarget(remembered: String?, previous: [String], current: [String]) -> String? {
        guard let remembered else { return current.first }
        if current.contains(remembered) { return remembered }
        let alive = Set(current)
        if let at = previous.firstIndex(of: remembered) {
            var distance = 1
            while at + distance < previous.count || at - distance >= 0 {
                if at + distance < previous.count, alive.contains(previous[at + distance]) { return previous[at + distance] }
                if at - distance >= 0, alive.contains(previous[at - distance]) { return previous[at - distance] }
                distance += 1
            }
        }
        return current.first
    }
}
