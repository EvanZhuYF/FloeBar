//
//  Collection+firstIndex.swift
//  FloeBar
//

extension Collection where Element == MenuBarItem {
    /// Returns the first index where the menu bar item with the specified info
    /// appears in the collection.
    func firstIndex(of info: MenuBarItemInfo) -> Index? {
        firstIndex { $0.info == info }
    }

    /// Returns the first index for the same live window or stable item identity.
    func firstIndex(matching item: MenuBarItem) -> Index? {
        firstIndex {
            $0.windowID == item.windowID || $0.identity == item.identity
        }
    }
}
