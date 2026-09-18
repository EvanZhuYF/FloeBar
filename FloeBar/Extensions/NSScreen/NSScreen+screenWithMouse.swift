//
//  NSScreen+screenWithMouse.swift
//  FloeBar
//

import Cocoa

extension NSScreen {
    /// Returns the screen containing the mouse pointer.
    static var screenWithMouse: NSScreen? {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }

    /// Returns the display currently hosting the active menu bar.
    static var screenWithActiveMenuBar: NSScreen? {
        guard let displayID = Bridging.activeMenuBarDisplayID else {
            return nil
        }
        return screens.first { $0.displayID == displayID }
    }

    static func isPointInMenuBar(
        _ point: CGPoint,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> Bool {
        screenFrame.contains(point) && point.y >= visibleFrame.maxY
    }
}
