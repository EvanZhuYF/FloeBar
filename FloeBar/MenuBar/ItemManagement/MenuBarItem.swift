//
//  MenuBarItem.swift
//  FloeBar
//

import Cocoa

// MARK: - MenuBarItem

/// A representation of an item in the menu bar.
struct MenuBarItem {
    struct OperationEndpoints {
        let item: MenuBarItem
        let target: MenuBarItem
    }

    /// A snapshot identity. Duplicate ordinals are not stable across enumerations.
    struct Identity: Hashable {
        let info: MenuBarItemInfo
        let sourcePID: pid_t?
        let instanceIndex: Int
    }

    /// The item's window.
    let window: WindowInfo

    /// The menu bar item info associated with this item.
    let info: MenuBarItemInfo

    /// The process that created the status item.
    let sourcePID: pid_t?

    /// The item's snapshot index among items with the same source and title.
    let instanceIndex: Int

    /// The identifier of the item's window.
    var windowID: CGWindowID {
        window.windowID
    }

    /// The frame of the item's window.
    var frame: CGRect {
        window.frame
    }

    /// The title of the item's window.
    var title: String? {
        window.title
    }

    /// A Boolean value that indicates whether the item is on screen.
    var isOnScreen: Bool {
        window.isOnScreen
    }

    /// A Boolean value that indicates whether the item can be moved.
    var isMovable: Bool {
        let immovableItems = Set(MenuBarItemInfo.immovableItems)
        return !hasProvisionalIdentity &&
            !immovableItems.contains(info) && !info.isBentoBox &&
            !info.isMisattributedControlCenterModule &&
            !isTransientControlCenterItem
    }

    /// A Boolean value that indicates whether the item can be hidden.
    var canBeHidden: Bool {
        let nonHideableItems = Set(MenuBarItemInfo.nonHideableItems)
        return isMovable && !nonHideableItems.contains(info)
    }

    /// The process identifier of the application that owns the item.
    var ownerPID: pid_t {
        window.ownerPID
    }

    /// The name of the application that owns the item.
    ///
    /// This may have a value when ``owningApplication`` does not have
    /// a localized name.
    var ownerName: String? {
        window.ownerName
    }

    /// The application that owns the item.
    var owningApplication: NSRunningApplication? {
        window.owningApplication
    }

    /// The application that created the item. On macOS 26 this commonly
    /// differs from ``owningApplication``, which is Control Center.
    var sourceApplication: NSRunningApplication? {
        guard let sourcePID else {
            return nil
        }
        return NSRunningApplication(processIdentifier: sourcePID)
    }

    /// The source identity in this snapshot, not a cross-window matching key.
    var identity: Identity {
        Identity(
            info: info,
            sourcePID: sourcePID,
            instanceIndex: instanceIndex
        )
    }

    /// Whether the item's source application is still unknown on macOS 26.
    var hasProvisionalIdentity: Bool {
        // The source cache supplies ownerPID on older systems; unresolved hosted
        // identity is a property of this snapshot, not the OS reading it.
        return sourcePID == nil && info.namespace == .controlCenter
    }

    /// A short-lived Control Center item that should not enter layout state.
    var isTransientControlCenterItem: Bool {
        info.isGenericControlCenterItem && sourcePID != nil &&
            sourceApplication?.bundleIdentifier == MenuBarItemInfo.Namespace.controlCenter.rawValue
    }

    /// A name associated with the item that is suited for display to
    /// the user.
    var displayName: String {
        var fallback: String { "Unknown" }
        let application = sourceApplication ?? owningApplication
        guard let application else {
            return ownerName ?? title ?? fallback
        }
        var bestName: String {
            application.localizedName ??
            ownerName ??
            application.bundleIdentifier ??
            fallback
        }
        guard let title else {
            return bestName
        }
        // by default, use the application name, but handle a few special cases
        return switch info.namespace {
        case .controlCenter:
            switch title {
            case "AccessibilityShortcuts": String(localized: "Accessibility Shortcuts")
            case let value where value.hasPrefix("BentoBox"): bestName // Control Center
            case "FocusModes": String(localized: "Focus")
            case "KeyboardBrightness": String(localized: "Keyboard Brightness")
            case "MusicRecognition": String(localized: "Music Recognition")
            case "NowPlaying": String(localized: "Now Playing")
            case "ScreenMirroring": String(localized: "Screen Mirroring")
            case "StageManager": String(localized: "Stage Manager")
            case "UserSwitcher": String(localized: "Fast User Switching")
            case "WiFi": String(localized: "Wi-Fi")
            default: title
            }
        case .systemUIServer:
            switch title {
            case "TimeMachine.TMMenuExtraHost"/*Sonoma*/, "TimeMachineMenuExtra.TMMenuExtraHost"/*Sequoia*/:
                String(localized: "Time Machine")
            default: title
            }
        case MenuBarItemInfo.Namespace("com.apple.Passwords.MenuBarExtra"): String(localized: "Passwords")
        default:
            bestName
        }
    }

    /// A Boolean value that indicates whether the item is currently
    /// in the menu bar.
    var isCurrentlyInMenuBar: Bool {
        let list = Set(Bridging.getWindowList(option: .menuBarItems))
        return list.contains(windowID)
    }

    /// A string to use for logging purposes.
    var logString: String {
        var value = String(describing: info)
        if instanceIndex > 0 {
            value += ":\(instanceIndex)"
        }
        return "\(value) [windowID=\(windowID), ownerPID=\(ownerPID), sourcePID=\(sourcePID.map(String.init) ?? "nil")]"
    }

    /// Creates a menu bar item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    private init(
        uncheckedItemWindow itemWindow: WindowInfo,
        sourcePID: pid_t?,
        instanceIndex: Int = 0
    ) {
        self.window = itemWindow
        self.info = MenuBarItemInfo(
            uncheckedItemWindow: itemWindow,
            sourcePID: sourcePID
        )
        self.sourcePID = sourcePID
        self.instanceIndex = instanceIndex
    }

    /// Creates a menu bar item.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `itemWindow` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter itemWindow: A window that contains information about the item.
    init?(itemWindow: WindowInfo) {
        guard itemWindow.isMenuBarItem else {
            return nil
        }
        self.init(
            uncheckedItemWindow: itemWindow,
            sourcePID: MenuBarItemSourcePIDCache.shared.sourcePID(for: itemWindow)
        )
    }

    /// Creates a menu bar item with the given window identifier.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `windowID` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter windowID: An identifier for a window that contains information
    ///   about the item.
    init?(windowID: CGWindowID) {
        guard let window = WindowInfo(windowID: windowID) else {
            return nil
        }
        self.init(itemWindow: window)
    }

    /// Re-reads this exact window for an operation that must not act on a
    /// stale or recycled WindowServer identifier.
    func refreshedForOperation() -> MenuBarItem? {
        guard
            let window = WindowInfo(windowID: windowID),
            window.isMenuBarItem
        else {
            return nil
        }
        let refreshed = MenuBarItem(
            uncheckedItemWindow: window,
            sourcePID: MenuBarItemSourcePIDCache.shared.sourcePID(for: window),
            instanceIndex: instanceIndex
        )
        return Self.exactlyMatching(self, in: [refreshed])
    }

    /// Matches this snapshot to a newer snapshot of the same live window.
    /// Only an older provisional identity may transition to a resolved one.
    func isSameWindow(as current: MenuBarItem) -> Bool {
        guard
            windowID == current.windowID,
            ownerPID == current.ownerPID,
            title == current.title
        else {
            return false
        }
        if hasProvisionalIdentity {
            return true
        }
        guard !current.hasProvisionalIdentity else {
            return false
        }
        return sourcePID == current.sourcePID && info == current.info
    }

    /// Application titles/ordinals do not identify a replacement window. Only our
    /// own uniquely named controls have a cross-window fallback.
    static func matching(_ target: MenuBarItem, in items: [MenuBarItem]) -> MenuBarItem? {
        if let exact = items.first(where: { $0.windowID == target.windowID }) {
            return exactlyMatching(target, in: [exact])
        }
        guard [.iceIcon, .hiddenControlItem, .alwaysHiddenControlItem].contains(target.info) else {
            return nil
        }
        let candidates = items.filter { $0.info == target.info && $0.ownerPID == target.ownerPID }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Finds the same live window, allowing only provisional-to-stable source
    /// resolution to change its identity.
    static func exactlyMatching(
        _ target: MenuBarItem,
        in items: [MenuBarItem]
    ) -> MenuBarItem? {
        guard
            let current = items.first(where: { $0.windowID == target.windowID }),
            current.ownerPID == target.ownerPID,
            current.title == target.title
        else {
            return nil
        }
        if target.hasProvisionalIdentity {
            return current
        }
        guard
            !current.hasProvisionalIdentity,
            current.sourcePID == target.sourcePID,
            current.info == target.info
        else {
            return nil
        }
        return current
    }

    /// Validates both move endpoints from one coherent window-description batch.
    static func operationEndpoints(
        item: MenuBarItem,
        target: MenuBarItem,
        in windows: [WindowInfo]
    ) -> OperationEndpoints? {
        guard item.windowID != target.windowID else {
            return nil
        }
        let items = getMenuBarItems(from: windows)
        guard
            let currentItem = exactlyMatching(item, in: items),
            let currentTarget = exactlyMatching(target, in: items)
        else {
            return nil
        }
        return OperationEndpoints(item: currentItem, target: currentTarget)
    }

    static func isInterfaceWindow(
        _ window: WindowInfo,
        ownedBy pids: Set<pid_t>
    ) -> Bool {
        guard pids.contains(window.ownerPID), window.isOnScreen else {
            return false
        }
        let level = CGWindowLevel(Int32(window.layer))
        if level == CGWindowLevelForKey(.popUpMenuWindow) ||
            level == CGWindowLevelForKey(.popUpMenuWindow) - 1
        {
            return true
        }
        if
            level == CGWindowLevelForKey(.statusWindow) ||
            level == CGWindowLevelForKey(.mainMenuWindow)
        {
            return window.frame.height > 40
        }
        return false
    }

    static func firstInterfaceWindow(
        in windows: [WindowInfo],
        ownedBy pids: Set<pid_t>,
        excluding windowIDs: Set<CGWindowID> = []
    ) -> WindowInfo? {
        windows.first {
            !windowIDs.contains($0.windowID) &&
                isInterfaceWindow($0, ownedBy: pids)
        }
    }
}

// MARK: MenuBarItem Getters
extension MenuBarItem {
    /// Returns menu bar items for an already-filtered list of window identifiers.
    static func getMenuBarItems(
        from windowIDs: [CGWindowID],
        on display: CGDirectDisplayID? = nil,
        excludeUntitled: Bool = false
    ) -> [MenuBarItem] {
        getMenuBarItems(
            from: WindowInfo.createWindows(from: windowIDs),
            on: display,
            excludeUntitled: excludeUntitled
        )
    }

    /// Returns menu bar items for already-created window descriptions.
    static func getMenuBarItems(
        from windows: [WindowInfo],
        on display: CGDirectDisplayID? = nil,
        excludeUntitled: Bool = false
    ) -> [MenuBarItem] {
        let baseItems = windows.compactMap { window -> MenuBarItem? in
            guard window.isMenuBarItem else {
                return nil
            }
            let sourcePID = MenuBarItemSourcePIDCache.shared.sourcePID(for: window)
            return MenuBarItem(
                uncheckedItemWindow: window,
                sourcePID: sourcePID
            )
        }

        // Assign snapshot ordinals before display filtering. Persistence separately
        // quarantines every same-bundle/title group ever observed as ambiguous.
        var instanceIndices = [CGWindowID: Int]()
        let groups = Dictionary(grouping: baseItems.indices, by: { baseItems[$0].info })
        for indices in groups.values where indices.count > 1 {
            let sorted = indices.sorted {
                baseItems[$0].windowID < baseItems[$1].windowID
            }
            for (instanceIndex, itemIndex) in sorted.enumerated() {
                instanceIndices[baseItems[itemIndex].windowID] = instanceIndex
            }
        }

        var displayBounds = [CGDirectDisplayID: CGRect]()
        if let display {
            for screen in NSScreen.screens {
                displayBounds[screen.displayID] = CGDisplayBounds(screen.displayID)
            }
            displayBounds[display] = CGDisplayBounds(display)
        }
        return baseItems.compactMap { item in
            if let display, !belongsToDisplay(
                frame: item.frame,
                isOnScreen: item.isOnScreen,
                display: display,
                bounds: displayBounds,
                isOnCurrentSpace: { Bridging.isWindow(item.windowID, onCurrentSpaceOf: $0) }
            ) {
                return nil
            }
            guard !excludeUntitled || item.title != "" else {
                return nil
            }
            return MenuBarItem(
                uncheckedItemWindow: item.window,
                sourcePID: item.sourcePID,
                instanceIndex: instanceIndices[item.windowID, default: 0]
            )
        }
        .sortedByOrderInMenuBar()
    }

    static func belongsToDisplay(
        frame: CGRect,
        isOnScreen: Bool,
        display: CGDirectDisplayID,
        bounds: [CGDirectDisplayID: CGRect],
        isOnCurrentSpace: (CGDirectDisplayID) -> Bool
    ) -> Bool {
        guard let target = bounds[display] else {
            return false
        }
        if isOnScreen || bounds.values.contains(where: { $0.intersects(frame) }) {
            return target.intersects(frame)
        }
        // A vertical lane alone cannot distinguish side-by-side displays.
        let lanes = bounds.filter { frame.midY >= $0.value.minY && frame.midY < $0.value.maxY }
        guard lanes[display] != nil else {
            return false
        }
        if lanes.count == 1 {
            return true
        }
        let spaceMatches = lanes.keys.filter(isOnCurrentSpace)
        return spaceMatches.count == 1 && spaceMatches.first == display
    }

    /// Returns an array of the current menu bar items in the menu bar on the given display.
    ///
    /// - Parameters:
    ///   - display: The display to retrieve the menu bar items on. Pass `nil` to return the
    ///     menu bar items across all displays.
    ///   - onScreenOnly: A Boolean value that indicates whether only the menu bar items that
    ///     are on screen should be returned.
    ///   - activeSpaceOnly: A Boolean value that indicates whether only the menu bar items
    ///     that are on the active space should be returned.
    static func getMenuBarItems(on display: CGDirectDisplayID? = nil, onScreenOnly: Bool, activeSpaceOnly: Bool) -> [MenuBarItem] {
        var option: Bridging.WindowListOption = [.menuBarItems]

        var titlePredicate: (MenuBarItem) -> Bool = { _ in true }

        if onScreenOnly {
            option.insert(.onScreen)
        }
        if activeSpaceOnly {
            titlePredicate = { $0.title != "" }
            if display == nil {
                option.insert(.activeSpace)
            }
        }

        var windowIDs = Bridging.getWindowList(option: option)
        if activeSpaceOnly, let display {
            windowIDs = windowIDs.filter {
                Bridging.isWindow($0, onCurrentSpaceOf: display)
            }
        }
        return getMenuBarItems(
            from: windowIDs,
            on: display
        ).filter(titlePredicate)
    }
}

// MARK: MenuBarItem: Equatable
extension MenuBarItem: Equatable {
    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.window == rhs.window &&
        lhs.info == rhs.info &&
        lhs.sourcePID == rhs.sourcePID &&
        lhs.instanceIndex == rhs.instanceIndex
    }
}

// MARK: MenuBarItem: Hashable
extension MenuBarItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(window)
        hasher.combine(info)
        hasher.combine(sourcePID)
        hasher.combine(instanceIndex)
    }
}

// MARK: MenuBarItemInfo Unchecked Item Window Initializer
private extension MenuBarItemInfo {
    /// Creates a simplified item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?) {
        switch itemWindow.title.flatMap(ControlItem.Identifier.init(recognizedTitle:)) {
        case .iceIcon:
            self = .iceIcon
            return
        case .hidden:
            self = .hiddenControlItem
            return
        case .alwaysHidden:
            self = .alwaysHiddenControlItem
            return
        case nil:
            break
        }

        if let sourcePID {
            let sourceApplication = NSRunningApplication(
                processIdentifier: sourcePID
            )
            self.namespace = Namespace(sourceApplication?.bundleIdentifier)
        } else if let bundleIdentifier = itemWindow.owningApplication?.bundleIdentifier {
            self.namespace = Namespace(bundleIdentifier)
        } else {
            self.namespace = .null
        }
        if let title = itemWindow.title {
            self.title = title
        } else {
            self.title = ""
        }
    }
}
