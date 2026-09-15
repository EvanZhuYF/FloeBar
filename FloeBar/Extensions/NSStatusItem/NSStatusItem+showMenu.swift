//
//  NSStatusItem+showMenu.swift
//  FloeBar
//

import Cocoa

extension NSStatusItem {
    /// Shows the given menu under the status item.
    func showMenu(_ menu: NSMenu) {
        let originalMenu = self.menu
        defer {
            self.menu = originalMenu
        }
        self.menu = menu
        button?.performClick(nil)
    }
}
