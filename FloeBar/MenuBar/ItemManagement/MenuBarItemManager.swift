//
//  MenuBarItemManager.swift
//  FloeBar
//

import Cocoa
import Combine

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// All cached menu bar items, keyed by section.
        private var items = [MenuBarSection.Name: [MenuBarItem]]()

        /// All cached menu bar items.
        var allItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: self[section])
            }
        }

        /// The cached menu bar items managed by Ice.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                result.append(contentsOf: managedItems(for: section))
            }
        }

        /// Clears the cache.
        mutating func clear() {
            items.removeAll()
        }

        /// Returns the cached menu bar items managed by Ice for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section].filter { item in
                // Filter out items that can't be hidden.
                guard item.canBeHidden else {
                    return false
                }

                if item.info.namespace == .ice {
                    // Ice icon is the only item owned by Ice that should be included.
                    guard item.info == .iceIcon else {
                        return false
                    }
                }

                return true
            }
        }

        /// Returns the name of the section for the given menu bar item.
        func section(for item: MenuBarItem) -> MenuBarSection.Name? {
            guard let match = MenuBarItem.matching(item, in: allItems) else {
                return nil
            }
            for (section, items) in self.items where items.contains(where: {
                $0.windowID == match.windowID
            }) {
                return section
            }
            return nil
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { items[section, default: []] }
            set { items[section] = newValue }
        }
    }

    /// Context for a temporarily shown menu bar item.
    private struct TempShownItemContext {
        /// The exact item shown; a sibling must not inherit its return context.
        let item: MenuBarItem

        /// Processes that may own the interface opened by this item.
        var interfacePIDs: Set<pid_t>

        /// Interface windows that were already visible before this item opened.
        let preexistingInterfaceWindowIDs: Set<CGWindowID>

        /// Display containing the item while it is temporarily shown.
        let displayID: CGDirectDisplayID

        /// The destination to return the item to.
        let returnDestination: MoveDestination

        let originalSection: MenuBarItemSectionStore.Section

        /// The window of the item's shown interface.
        var shownInterfaceWindow: WindowInfo?

        /// A Boolean value that indicates whether the menu bar item's interface is showing.
        var isShowingInterface: Bool {
            if
                let currentWindow = shownInterfaceWindow.flatMap({
                    WindowInfo(windowID: $0.windowID)
                }),
                MenuBarItem.isInterfaceWindow(currentWindow, ownedBy: interfacePIDs)
            {
                return true
            }
            return MenuBarItem.firstInterfaceWindow(
                in: WindowInfo.getOnScreenWindows(),
                ownedBy: interfacePIDs,
                excluding: preexistingInterfaceWindowIDs
            ) != nil
        }

        func matches(_ item: MenuBarItem) -> Bool {
            self.item.isSameWindow(as: item)
        }
    }

    private struct WindowSignature: Equatable {
        let windowID: CGWindowID
        let frame: CGRect
    }

    private struct SectionPlacement: Hashable {
        let identity: MenuBarItemSectionStore.Identity
        let windowID: CGWindowID
        let section: MenuBarItemSectionStore.Section
    }

    private struct NativeDrag {
        let item: MenuBarItem
        let initialSection: MenuBarItemSectionStore.Section?
        let wasAwaitingStableIdentity: Bool
        let initialPlacements: Set<SectionPlacement>
        var didDrag: Bool
    }

    /// The manager's menu bar item cache.
    @Published private(set) var itemCache = ItemCache()

    private var persistenceIdentityPolicy = MenuBarItemPersistenceIdentityPolicy()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    private var sectionStore: MenuBarItemSectionStore?
    private var isCachingItems = false
    private var isRestoringSection = false
    private var isPerformingUserMove = false
    private var isTemporarilyShowingItem = false
    private var layoutReadyDate: TimeInterval = 0
    private var cachedWindowSignature: [WindowSignature]?
    private var lastFullCacheDate: TimeInterval = 0
    private var sectionObservationPending = false
    private var nativeDrag: NativeDrag?
    private var pendingUserChanges = [MenuBarItemSectionStore.Identity: TimeInterval]()
    private var pendingNativeDragIntents = MenuBarItemPendingSectionIntents()
    private var acceptNextLayout = false
    private var sourcePIDResolutionTask: Task<Void, Never>?
    private var sourcePIDRetryTask: Task<Void, Never>?
    private var cacheRefreshTask: Task<Void, Never>?

    /// Context values for the current temporarily shown items.
    private var tempShownItemContexts = [TempShownItemContext]()

    /// A timer that determines when to rehide the temporarily shown items.
    private var tempShownItemsTimer: Timer?

    /// The last time a menu bar item was moved.
    private var lastItemMoveStartDate: Date?

    /// The last time the mouse was moved.
    private var lastMouseMoveStartDate: Date?

    /// Counter to determine if a menu bar item, or group of menu bar
    /// items is being moved.
    private var itemMoveCount = 0

    /// A Boolean value that indicates whether a mouse button is down.
    private var isMouseButtonDown = false

    /// Event type mask for tracking mouse events.
    private let mouseTrackingMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp,
    ]

    /// A Boolean value that indicates whether a menu bar item, or
    /// group of menu bar items is being moved.
    var isMovingItem: Bool {
        itemMoveCount > 0
    }

    /// A Boolean value that indicates whether a menu bar item has
    /// recently moved.
    var itemHasRecentlyMoved: Bool {
        guard let lastItemMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastItemMoveStartDate) <= 1
    }

    /// A Boolean value that indicates whether the mouse has recently moved.
    var mouseHasRecentlyMoved: Bool {
        guard let lastMouseMoveStartDate else {
            return false
        }
        return Date.now.timeIntervalSince(lastMouseMoveStartDate) <= 1
    }

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the manager.
    func performSetup() {
        do {
            sectionStore = try MenuBarItemSectionStore()
            sectionObservationPending = true
        } catch {
            // Leave unrecognized/corrupt data intact instead of overwriting it.
            Logger.itemManager.error("Cannot load saved menu bar sections: \(error)")
        }
        layoutReadyDate = ProcessInfo.processInfo.systemUptime + 5
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Timer.publish(every: 5, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        for notification in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            NSWorkspace.shared.notificationCenter.publisher(for: notification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.deferSectionRestoration() }
                .store(in: &c)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.deferSectionRestoration() }
            .store(in: &c)

        Publishers.Merge(
            UniversalEventMonitor.publisher(for: mouseTrackingMask),
            RunLoopLocalEventMonitor.publisher(for: mouseTrackingMask, mode: .eventTracking)
        )
        .removeDuplicates()
        .sink { [weak self] event in
            guard let self else {
                return
            }
            switch event.type {
            case .mouseMoved:
                lastMouseMoveStartDate = .now
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                isMouseButtonDown = true
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                isMouseButtonDown = false
            default:
                break
            }
        }
        .store(in: &c)

        cancellables = c
    }
}

// MARK: - Cache Items

extension MenuBarItemManager {
    /// Logs a warning that the given menu bar item was not added to the cache.
    private func logNotCachedWarning(for item: MenuBarItem) {
        Logger.itemManager.warning("\(item.logString) was not cached")
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.itemManager.debug("Skipping menu bar item cache as \(reason)")
    }

    /// Caches the given menu bar items, without checking whether the control
    /// items are in the correct order.
    private func uncheckedCacheItems(
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem?,
        otherItems: [MenuBarItem]
    ) {
        Logger.itemManager.debug("Caching menu bar items")

        let predicates = Predicates.sectionPredicates(
            hiddenControlItem: hiddenControlItem,
            alwaysHiddenControlItem: alwaysHiddenControlItem
        )

        var cache = ItemCache()
        var tempShownItems = [(MenuBarItem, MoveDestination)]()

        for item in otherItems {
            if let context = tempShownItemContexts.first(where: { $0.matches(item) }) {
                // Keep track of temporarily shown items and their return destinations separately.
                // We want to cache them as if they were in their original locations. Once all other
                // items are cached, use the return destinations to insert the items into the cache
                // at the correct position.
                tempShownItems.append((item, context.returnDestination))
            } else if predicates.isInVisibleSection(item) {
                cache[.visible].append(item)
            } else if predicates.isInHiddenSection(item) {
                cache[.hidden].append(item)
            } else if predicates.isInAlwaysHiddenSection(item) {
                cache[.alwaysHidden].append(item)
            } else {
                logNotCachedWarning(for: item)
            }
        }

        for (item, destination) in tempShownItems {
            switch destination {
            case .leftOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.hidden].append(item)
                case .alwaysHiddenControlItem:
                    cache[.alwaysHidden].append(item)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let target = MenuBarItem.matching(targetItem, in: cache[section]),
                        let index = cache[section].firstIndex(where: { $0.windowID == target.windowID })
                    {
                        let clampedIndex = index.clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            case .rightOfItem(let targetItem):
                switch targetItem.info {
                case .hiddenControlItem:
                    cache[.visible].insert(item, at: 0)
                case .alwaysHiddenControlItem:
                    cache[.hidden].insert(item, at: 0)
                default:
                    if
                        let section = cache.section(for: targetItem),
                        let target = MenuBarItem.matching(targetItem, in: cache[section]),
                        let index = cache[section].firstIndex(where: { $0.windowID == target.windowID })
                    {
                        // Insert to the right of the target item. Since the array is
                        // ordered left-to-right, "right of" means the position after
                        // the target's index.
                        let clampedIndex = (index + 1).clamped(to: cache[section].startIndex...cache[section].endIndex)
                        cache[section].insert(item, at: clampedIndex)
                    }
                }
            }
            if cache.section(for: item) == nil,
               let context = tempShownItemContexts.first(where: { $0.matches(item) }) {
                // A neighboring app may have exited while this item was shown.
                cache[MenuBarSection.Name(storedSection: context.originalSection)].append(item)
            }
        }

        if itemCache != cache {
            itemCache = cache
        }
    }

    /// Caches the current menu bar items if needed, ensuring that the control
    /// items are in the correct order.
    func cacheItemsIfNeeded() async {
        guard
            !isCachingItems, !isPerformingUserMove, !isTemporarilyShowingItem,
            !isMouseButtonDown, nativeDrag == nil
        else {
            return
        }
        isCachingItems = true
        defer { isCachingItems = false }

        do {
            try await waitForItemsToStopMoving(timeout: .seconds(1))
        } catch is TaskTimeoutError {
            logSkippingCache(reason: "an item is currently being moved")
            return
        } catch {
            guard !itemHasRecentlyMoved else {
                logSkippingCache(reason: "an item was recently moved")
                return
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        // Read all descriptions in one WindowServer call. Space changes
        // explicitly invalidate the signature.
        let windowIDs = Bridging.getWindowList(option: .menuBarItems)
        let windows = WindowInfo.createWindows(from: windowIDs)
        let sourcePIDCacheChanged =
            MenuBarItemSourcePIDCache.shared.reconcile(
                withFullSnapshot: windows
            )
        let signature = windows.map {
            WindowSignature(windowID: $0.windowID, frame: $0.frame)
        }.sorted { $0.windowID < $1.windowID }
        let signatureChanged = signature != cachedWindowSignature
        let needsPeriodicRefresh = now - lastFullCacheDate >= 60
        guard
            signatureChanged || sourcePIDCacheChanged ||
            sectionObservationPending || !pendingNativeDragIntents.isEmpty ||
            needsPeriodicRefresh
        else {
            logSkippingCache(reason: "item windows and frames have not changed")
            return
        }
        cachedWindowSignature = signature
        lastFullCacheDate = now
        if signatureChanged || sourcePIDCacheChanged {
            sectionObservationPending = sectionStore != nil
            sourcePIDRetryTask?.cancel()
            sourcePIDRetryTask = nil
        }

        let activeDisplayID = Bridging.activeMenuBarDisplayID
        let activeWindowIDs = if let activeDisplayID {
            windowIDs.filter {
                Bridging.isWindow($0, onCurrentSpaceOf: activeDisplayID)
            }
        } else {
            windowIDs.filter(Bridging.isWindowOnActiveSpace)
        }
        scheduleSourcePIDResolution(
            windows: windows,
            requiredWindowIDs: Set(
                windows.lazy.filter(\.isMenuBarItem).map(\.windowID)
            )
        )
        // This unfiltered enumeration is the sole authority for provisional
        // title ambiguity. Display/Space-filtered paths only query the policy.
        let fullSnapshot = MenuBarItem.getMenuBarItems(from: windows)
        guard updateSectionIdentities(fromFullSnapshot: fullSnapshot) else {
            return
        }
        let activeWindowIDSet = Set(activeWindowIDs)
        var items = MenuBarItem.getMenuBarItems(
            from: windows.filter { activeWindowIDSet.contains($0.windowID) },
            on: activeDisplayID,
            excludeUntitled: true
        )
        let allItems = items

        Logger.itemManager.debug(
            "Cache pass: menuBarItem windows=\(windowIDs.count), onActiveSpace=\(activeWindowIDs.count), items=\(items.count)"
        )
        if items.isEmpty {
            // No menu bar items were resolved. Log the raw window layers so we can tell
            // whether enumeration returned nothing or the layer filter dropped everything.
            let layers = activeWindowIDs.compactMap { WindowInfo(windowID: $0)?.layer }
            Logger.itemManager.warning(
                "No menu bar items resolved. statusLevel=\(kCGStatusWindowLevel), rawWindowIDs=\(windowIDs), activeLayers=\(layers)"
            )
        }

        let hiddenControlItem = removeControlItem(
            named: .hidden,
            from: &items
        )
        let alwaysHiddenControlItem = removeControlItem(
            named: .alwaysHidden,
            from: &items
        )

        guard let hiddenControlItem else {
            Logger.itemManager.warning("Missing control item for hidden section")
            sectionStore?.invalidateSnapshot()
            return
        }

        do {
            if let alwaysHiddenControlItem,
               hiddenControlItem.frame.maxX <= alwaysHiddenControlItem.frame.minX {
                try await enforceControlItemOrder(
                    hiddenControlItem: hiddenControlItem,
                    alwaysHiddenControlItem: alwaysHiddenControlItem
                )
                // All frames above predate the move. Resample after AppKit settles.
                cachedWindowSignature = nil
                sectionStore?.invalidateSnapshot()
                scheduleCacheRefresh(after: .milliseconds(150))
                return
            }
            uncheckedCacheItems(
                hiddenControlItem: hiddenControlItem,
                alwaysHiddenControlItem: alwaysHiddenControlItem,
                otherItems: items
            )
            await restoreSavedSections(in: allItems)
        } catch {
            Logger.itemManager.error("Error enforcing control item order: \(error)")
            sectionStore?.invalidateSnapshot()
        }
    }

    private func scheduleCacheRefresh(after delay: Duration) {
        cacheRefreshTask?.cancel()
        cacheRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.cacheItemsIfNeeded()
        }
    }

    private func removeControlItem(
        named name: MenuBarSection.Name,
        from items: inout [MenuBarItem]
    ) -> MenuBarItem? {
        let expectedInfo: MenuBarItemInfo = switch name {
        case .visible: .iceIcon
        case .hidden: .hiddenControlItem
        case .alwaysHidden: .alwaysHiddenControlItem
        }
        if
            let windowID = appState?.menuBarManager.section(withName: name)?
                .controlItem.windowID,
            let index = items.firstIndex(where: { $0.windowID == windowID })
        {
            return items.remove(at: index)
        }

        let matches = items.indices.filter { items[$0].info == expectedInfo }
        guard matches.count == 1, let index = matches.first else {
            if matches.count > 1 {
                Logger.itemManager.warning(
                    "Refusing ambiguous \(name.logString) control item title match"
                )
            }
            return nil
        }
        return items.remove(at: index)
    }

    private func scheduleSourcePIDResolution(
        windows: [WindowInfo],
        requiredWindowIDs: Set<CGWindowID>
    ) {
        if #unavailable(macOS 26.0) {
            return
        }
        guard
            sourcePIDResolutionTask == nil,
            MenuBarItemSourcePIDCache.shared.needsResolution(
                for: requiredWindowIDs,
                in: windows
            )
        else {
            return
        }

        sourcePIDResolutionTask = Task { [weak self] in
            let result = await MenuBarItemSourcePIDResolver.shared.resolve(
                windows: windows,
                requiredWindowIDs: requiredWindowIDs
            )
            guard let self else {
                return
            }
            sourcePIDResolutionTask = nil
            if result.changed {
                cachedWindowSignature = nil
                sectionObservationPending = sectionStore != nil
                scheduleCacheRefresh(after: .milliseconds(100))
            }
            guard let retryDelay = result.retryDelay else {
                return
            }
            sourcePIDRetryTask?.cancel()
            sourcePIDRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(retryDelay))
                guard let self, !Task.isCancelled else {
                    return
                }
                sourcePIDRetryTask = nil
                cachedWindowSignature = nil
                await cacheItemsIfNeeded()
            }
        }
    }
}

// MARK: - Remember Sections

extension MenuBarItemManager {
    private func deferSectionRestoration() {
        layoutReadyDate = ProcessInfo.processInfo.systemUptime + 2
        cachedWindowSignature = nil
        sectionObservationPending = sectionStore != nil
        sectionStore?.invalidateSnapshot()
    }

    private func physicalSection(of item: MenuBarItem, in items: [MenuBarItem]) -> MenuBarItemSectionStore.Section? {
        guard let hidden = items.first(where: { $0.info == .hiddenControlItem }) else {
            return nil
        }
        let predicates = Predicates.sectionPredicates(
            hiddenControlItem: hidden,
            alwaysHiddenControlItem: items.first(where: { $0.info == .alwaysHiddenControlItem })
        )
        if predicates.isInVisibleSection(item) { return .visible }
        if predicates.isInHiddenSection(item) { return .hidden }
        if predicates.isInAlwaysHiddenSection(item) { return .alwaysHidden }
        return nil
    }

    /// Updates persistence identity state from an unfiltered menu bar snapshot.
    private func updateSectionIdentities(
        fromFullSnapshot items: [MenuBarItem]
    ) -> Bool {
        let identities = persistenceIdentityPolicy.update(
            fromFullSnapshot: items
        )
        let now = ProcessInfo.processInfo.systemUptime
        let resolutions = pendingNativeDragIntents.reconcile(
            withFullSnapshot: items,
            policy: persistenceIdentityPolicy,
            now: now
        )
        do {
            try sectionStore?.noteIdentities(identities)
            let expiration = now + 10
            for resolution in resolutions {
                try sectionStore?.remember(
                    resolution.identity,
                    in: resolution.section
                )
                pendingUserChanges[resolution.identity] = expiration
                pendingNativeDragIntents.finish(windowID: resolution.windowID)
            }
            return true
        } catch {
            Logger.itemManager.error("Could not update menu bar persistence identities: \(error)")
            return false
        }
    }

    /// Callers note identities before filtering so excluded siblings still block matching titles.
    private func sectionObservations(in items: [MenuBarItem]) -> [MenuBarItemSectionStore.Item]? {
        let hidden = items.filter { $0.info == .hiddenControlItem }
        let alwaysHidden = items.filter { $0.info == .alwaysHiddenControlItem }
        let expectsAlwaysHidden = appState?.menuBarManager.section(withName: .alwaysHidden)?.isEnabled == true
        guard
            hidden.count == 1,
            alwaysHidden.count == (expectsAlwaysHidden ? 1 : 0),
            let h = hidden.first,
            h.frame.height > 0,
            h.frame.minX != -1
        else {
            return nil
        }
        if let ah = alwaysHidden.first {
            guard ah.frame.minX != -1,
                  ah.frame.maxX <= h.frame.minX,
                  ah.frame.minY < h.frame.maxY, ah.frame.maxY > h.frame.minY else {
                return nil
            }
        }
        let predicates = Predicates.sectionPredicates(hiddenControlItem: h, alwaysHiddenControlItem: alwaysHidden.first)
        var observations = [MenuBarItemSectionStore.Item]()
        for item in items {
            guard let identity = persistenceIdentityPolicy.eligibleIdentity(for: item) else {
                continue
            }
            guard
                item.frame.minX != -1,
                item.frame.width > 0, item.frame.height > 0,
                item.frame.minY < h.frame.maxY, item.frame.maxY > h.frame.minY
            else {
                return nil
            }
            let section: MenuBarItemSectionStore.Section
            if predicates.isInVisibleSection(item) {
                section = .visible
            } else if predicates.isInHiddenSection(item) {
                section = .hidden
            } else if predicates.isInAlwaysHiddenSection(item) {
                section = .alwaysHidden
            } else {
                return nil
            }
            observations.append(.init(
                identity: identity,
                windowID: item.windowID,
                processID: item.sourcePID ?? item.ownerPID,
                section: section
            ))
        }
        return observations
    }

    private func sectionPlacements(in items: [MenuBarItem]) -> Set<SectionPlacement>? {
        sectionObservations(in: items).map { observations in
            Set(observations.map {
                SectionPlacement(identity: $0.identity, windowID: $0.windowID, section: $0.section)
            })
        }
    }

    private func restoreSavedSections(in items: [MenuBarItem]) async {
        guard let sectionStore else {
            sectionObservationPending = false
            return
        }
        guard
            let appState,
            ProcessInfo.processInfo.systemUptime >= layoutReadyDate,
            !appState.isActiveSpaceFullscreen,
            !appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults,
            !isMouseButtonDown, !isMovingItem, !isPerformingUserMove,
            nativeDrag == nil, !isTemporarilyShowingItem,
            tempShownItemContexts.isEmpty
        else {
            return
        }
        guard let observations = sectionObservations(in: items) else {
            Logger.itemManager.debug("Waiting for a complete menu bar section snapshot")
            sectionStore.invalidateSnapshot()
            return
        }
        do {
            let now = ProcessInfo.processInfo.systemUptime
            pendingUserChanges = pendingUserChanges.filter { $0.value >= now }
            let observation = try sectionStore.observe(
                observations,
                now: now,
                userChangedIdentities: Set(pendingUserChanges.keys),
                acceptAllChanges: acceptNextLayout,
                alwaysHiddenEnabled: appState.menuBarManager.section(withName: .alwaysHidden)?.isEnabled == true,
                allowRestore: !mouseHasRecentlyMoved && !itemHasRecentlyMoved &&
                    !appState.eventManager.isMouseInsideMenuBar &&
                    !appState.eventManager.isMouseInsideIceBar
            )
            sectionObservationPending = !observation.isSettled
            if observation.isSettled {
                let observedIdentities = Set(observations.map(\.identity))
                pendingUserChanges = pendingUserChanges.filter {
                    !observedIdentities.contains($0.key) && $0.value >= now
                }
                acceptNextLayout = false
            }
            guard
                let restore = observation.restore,
                let item = items.first(where: { $0.windowID == restore.item.windowID }),
                !pendingNativeDragIntents.contains(item),
                let destination = sectionDestination(restore.section, in: items)
            else {
                return
            }
            isRestoringSection = true
            defer {
                isRestoringSection = false
                deferSectionRestoration()
            }
            Logger.itemManager.info("Restoring \(item.logString) to saved section \(restore.section.rawValue)")
            try await slowMove(item: item, to: destination, maxAttempts: 1)
        } catch {
            Logger.itemManager.error("Could not restore saved menu bar section: \(error)")
        }
    }

    private func sectionDestination(
        _ section: MenuBarItemSectionStore.Section,
        in items: [MenuBarItem]
    ) -> MoveDestination? {
        switch section {
        case .visible:
            return items.first(where: { $0.info == .hiddenControlItem }).map { .rightOfItem($0) }
        case .hidden:
            return items.first(where: { $0.info == .hiddenControlItem }).map { .leftOfItem($0) }
        case .alwaysHidden:
            return items.first(where: { $0.info == .alwaysHiddenControlItem }).map { .leftOfItem($0) }
        }
    }

    /// Records only explicit layout edits, never the physical result of a restore.
    func moveByUser(item: MenuBarItem, to destination: MoveDestination, section: MenuBarSection.Name) async throws {
        guard !isRestoringSection, !isPerformingUserMove, !isTemporarilyShowingItem, !isMovingItem else {
            throw EventError(code: .couldNotComplete, item: item)
        }
        guard !persistenceIdentityPolicy.isAwaitingStableIdentity(item) else {
            throw EventError(code: .couldNotComplete, item: item)
        }
        guard
            item.isMovable,
            persistenceIdentityPolicy.eligibleIdentity(for: item) != nil
        else {
            throw EventError(code: .notMovable, item: item)
        }
        isPerformingUserMove = true
        defer {
            isPerformingUserMove = false
            deferSectionRestoration()
        }
        try await slowMove(item: item, to: destination)
        removeTempShownItemFromCache(matching: item)
        let currentItems = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        if let currentItem = MenuBarItem.exactlyMatching(item, in: currentItems),
           let identity = persistenceIdentityPolicy.eligibleIdentity(for: currentItem) {
            do {
                try sectionStore?.remember(identity, in: section.storedSection)
            } catch {
                Logger.itemManager.error("Could not save user-selected section: \(error)")
            }
        }
    }

    func beginUserDrag() {
        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        guard
            !isMovingItem, !isRestoringSection, !isPerformingUserMove, !isTemporarilyShowingItem,
            let point = MouseCursor.location(in: .coreGraphics),
            let item = items.first(where: { $0.isOnScreen && $0.frame.contains(point) }),
            let placements = sectionPlacements(in: items)
        else {
            return
        }
        nativeDrag = NativeDrag(
            item: item,
            initialSection: physicalSection(of: item, in: items),
            wasAwaitingStableIdentity: persistenceIdentityPolicy
                .isAwaitingStableIdentity(item),
            initialPlacements: placements,
            didDrag: false
        )
    }

    func updateUserDrag() {
        guard nativeDrag != nil else {
            return
        }
        nativeDrag?.didDrag = true
        if let item = nativeDrag?.item {
            removeTempShownItemFromCache(matching: item)
        }
    }

    func endUserDrag() {
        guard let drag = nativeDrag else {
            return
        }
        nativeDrag = nil
        guard drag.didDrag else {
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
            guard
                let currentItem = MenuBarItem.exactlyMatching(drag.item, in: items),
                let currentSection = physicalSection(of: currentItem, in: items),
                let currentPlacements = sectionPlacements(in: items)
            else {
                return
            }
            if drag.item.info == .hiddenControlItem || drag.item.info == .alwaysHiddenControlItem {
                let changedExistingItem = drag.initialPlacements.contains { initial in
                    currentPlacements.contains {
                        $0.identity == initial.identity &&
                        $0.windowID == initial.windowID &&
                        $0.section != initial.section
                    }
                }
                guard changedExistingItem else {
                    return
                }
                acceptNextLayout = true
            } else {
                guard drag.initialSection != currentSection else {
                    return
                }
                if drag.wasAwaitingStableIdentity {
                    pendingNativeDragIntents.record(
                        postDragItem: currentItem,
                        section: currentSection,
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    layoutReadyDate = ProcessInfo.processInfo.systemUptime
                    cachedWindowSignature = nil
                    sectionObservationPending = sectionStore != nil
                    sectionStore?.invalidateSnapshot()
                    await cacheItemsIfNeeded()
                    return
                }
                guard let identity = persistenceIdentityPolicy.eligibleIdentity(for: currentItem) else {
                    return
                }
                let initial = drag.initialPlacements.filter {
                    $0.identity == identity && $0.windowID == drag.item.windowID
                }
                let current = currentPlacements.filter {
                    $0.identity == identity && $0.windowID == drag.item.windowID
                }
                guard
                    initial.count == 1, current.count == 1
                else {
                    return
                }
                pendingUserChanges[identity] = ProcessInfo.processInfo.systemUptime + 10
            }
            layoutReadyDate = ProcessInfo.processInfo.systemUptime
            cachedWindowSignature = nil
            sectionObservationPending = sectionStore != nil
            sectionStore?.invalidateSnapshot()
            await cacheItemsIfNeeded()
            try? await Task.sleep(for: .milliseconds(1200))
            await cacheItemsIfNeeded()
        }
    }
}

private extension MenuBarSection.Name {
    init(storedSection: MenuBarItemSectionStore.Section) {
        self = switch storedSection {
        case .visible: .visible
        case .hidden: .hidden
        case .alwaysHidden: .alwaysHidden
        }
    }

    var storedSection: MenuBarItemSectionStore.Section {
        switch self {
        case .visible: .visible
        case .hidden: .hidden
        case .alwaysHidden: .alwaysHidden
        }
    }
}

// MARK: - Menu Bar Item Events -

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    struct EventError: Error, CustomStringConvertible, LocalizedError {
        /// Error codes within the domain of menu bar item event errors.
        enum ErrorCode: Int, CustomStringConvertible {
            /// An operation could not be completed.
            case couldNotComplete
            /// The creation of a menu bar item event failed.
            case eventCreationFailure
            /// The shared app state is invalid or could not be found.
            case invalidAppState
            /// An event source could not be created or is otherwise invalid.
            case invalidEventSource
            /// The location of the mouse cursor is invalid or could not be found.
            case invalidCursorLocation
            /// A menu bar item is invalid.
            case invalidItem
            /// A menu bar item cannot be moved.
            case notMovable
            /// A menu bar item event operation timed out.
            case eventOperationTimeout
            /// A menu bar item frame check timed out.
            case frameCheckTimeout
            /// An operation timed out.
            case otherTimeout

            /// Description of the code for debugging purposes.
            var description: String {
                switch self {
                case .couldNotComplete: "couldNotComplete"
                case .eventCreationFailure: "eventCreationFailure"
                case .invalidAppState: "invalidAppState"
                case .invalidEventSource: "invalidEventSource"
                case .invalidCursorLocation: "invalidCursorLocation"
                case .invalidItem: "invalidItem"
                case .notMovable: "notMovable"
                case .eventOperationTimeout: "eventOperationTimeout"
                case .frameCheckTimeout: "frameCheckTimeout"
                case .otherTimeout: "otherTimeout"
                }
            }

            /// A string to use for logging purposes.
            var logString: String {
                "\(self) (rawValue: \(rawValue))"
            }
        }

        /// The error code of this error.
        let code: ErrorCode

        /// The error's menu bar item.
        let item: MenuBarItem

        /// The message associated with this error.
        var message: String {
            switch code {
            case .couldNotComplete:
                String(localized: "Could not complete event operation for \"\(item.displayName)\"")
            case .eventCreationFailure:
                String(localized: "Failed to create event for \"\(item.displayName)\"")
            case .invalidAppState:
                String(localized: "Invalid app state for \"\(item.displayName)\"")
            case .invalidEventSource:
                String(localized: "Invalid event source for \"\(item.displayName)\"")
            case .invalidCursorLocation:
                String(localized: "Invalid cursor location for \"\(item.displayName)\"")
            case .invalidItem:
                String(localized: "\"\(item.displayName)\" is invalid")
            case .notMovable:
                String(localized: "\"\(item.displayName)\" is not movable")
            case .eventOperationTimeout:
                String(localized: "Event operation timed out for \"\(item.displayName)\"")
            case .frameCheckTimeout:
                String(localized: "Frame check timed out for \"\(item.displayName)\"")
            case .otherTimeout:
                String(localized: "Operation timed out for \"\(item.displayName)\"")
            }
        }

        /// Description of the error for debugging purposes.
        var description: String {
            var parameters = [String]()
            parameters.append("code: \(code.logString)")
            parameters.append("item: \(item.logString)")
            return "\(Self.self)(\(parameters.joined(separator: ", ")))"
        }

        /// Description of the error for display purposes.
        var errorDescription: String? {
            message
        }

        /// Suggestion for recovery from the error.
        var recoverySuggestion: String? {
            String(localized: "Please try again. If the error persists, please file a bug report.")
        }
    }
}

// MARK: - Async Waiters

extension MenuBarItemManager {
    /// Waits asynchronously for all menu bar items to stop moving.
    ///
    /// - Parameter timeout: Amount of time to wait before throwing an error.
    func waitForItemsToStopMoving(timeout: Duration? = nil) async throws {
        let taskBody: @Sendable () async throws -> Void = {
            while await self.isMovingItem {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let checkTask = if let timeout {
            Task(timeout: timeout) {
                try await taskBody()
            }
        } else {
            Task {
                try await taskBody()
            }
        }
        try await checkTask.value
    }

    /// Waits asynchronously for the mouse to stop moving.
    ///
    /// - Parameters:
    ///   - threshold: A threshold to use to determine whether the mouse has stopped moving.
    ///   - timeout: Amount of time to wait before throwing an error.
    func waitForMouseToStopMoving(threshold: TimeInterval = 0.1, timeout: Duration? = nil) async throws {
        let taskBody: @Sendable () async throws -> Void = {
            while true {
                try Task.checkCancellation()
                guard let date = await self.lastMouseMoveStartDate else {
                    break
                }
                if Date.now.timeIntervalSince(date) > threshold {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let checkTask = if let timeout {
            Task(timeout: timeout) {
                try await taskBody()
            }
        } else {
            Task {
                try await taskBody()
            }
        }
        try await checkTask.value
    }
}

// MARK: - Move Items

extension MenuBarItemManager {
    /// A destination that a menu bar item can be moved to.
    enum MoveDestination {
        /// The menu bar item will be moved to the left of the given menu bar item.
        case leftOfItem(MenuBarItem)

        /// The menu bar item will be moved to the right of the given menu bar item.
        case rightOfItem(MenuBarItem)

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item):
                "left of \(item.logString)"
            case .rightOfItem(let item):
                "right of \(item.logString)"
            }
        }

        func replacingTarget(with item: MenuBarItem) -> MoveDestination {
            switch self {
            case .leftOfItem:
                .leftOfItem(item)
            case .rightOfItem:
                .rightOfItem(item)
            }
        }
    }

    /// Returns the current frame for the given item.
    ///
    /// - Parameter item: The item to return the current frame for.
    private func getCurrentFrame(for item: MenuBarItem) -> CGRect? {
        guard let frame = Bridging.getWindowFrame(for: item.window.windowID) else {
            Logger.itemManager.error("Couldn't get current frame for \(item.logString)")
            return nil
        }
        return frame
    }

    /// Returns the end point for moving an item to the given destination.
    ///
    /// - Parameter destination: The destination to return the end point for.
    private func getEndPoint(for destination: MoveDestination) -> CGPoint {
        switch destination {
        case .leftOfItem(let targetItem):
            return CGPoint(x: targetItem.frame.minX, y: targetItem.frame.midY)
        case .rightOfItem(let targetItem):
            return CGPoint(x: targetItem.frame.maxX, y: targetItem.frame.midY)
        }
    }

    /// Returns the fallback point for returning the given item to its original
    /// position if a move fails.
    ///
    /// - Parameter item: The item to return the fallback point for.
    private func getFallbackPoint(for item: MenuBarItem) -> CGPoint {
        CGPoint(x: item.frame.midX, y: item.frame.midY)
    }

    /// Returns the target item for the given destination.
    ///
    /// - Parameter destination: The destination to get the target item from.
    private func getTargetItem(for destination: MoveDestination) -> MenuBarItem {
        switch destination {
        case .leftOfItem(let targetItem), .rightOfItem(let targetItem): targetItem
        }
    }

    /// Returns a Boolean value that indicates whether the given item is in the
    /// correct position for the given destination.
    ///
    /// - Parameters:
    ///   - item: The item to check the position of.
    ///   - destination: The destination to compare the item's position against.
    private func itemHasCorrectPosition(item: MenuBarItem, for destination: MoveDestination) -> Bool {
        switch destination {
        case .leftOfItem(let targetItem):
            return item.frame.maxX == targetItem.frame.minX
        case .rightOfItem(let targetItem):
            return item.frame.minX == targetItem.frame.maxX
        }
    }

    private func refreshedMoveEndpoints(
        item: MenuBarItem,
        destination: MoveDestination
    ) -> (item: MenuBarItem, destination: MoveDestination)? {
        let target = getTargetItem(for: destination)
        let windows = WindowInfo.createWindows(
            from: [item.windowID, target.windowID]
        )
        guard
            let endpoints = MenuBarItem.operationEndpoints(
                item: item,
                target: target,
                in: windows
            ),
            isUsableMoveFrame(endpoints.item.frame),
            isUsableMoveFrame(endpoints.target.frame)
        else {
            return nil
        }
        return (
            endpoints.item,
            destination.replacingTarget(with: endpoints.target)
        )
    }

    private func isUsableMoveFrame(_ frame: CGRect) -> Bool {
        frame.minX != -1 &&
            frame.width > 0 && frame.height > 0 &&
            frame.minX.isFinite && frame.minY.isFinite &&
            frame.maxX.isFinite && frame.maxY.isFinite
    }

    private func moveFailureKind(for error: any Error) -> MenuBarItemMoveFailureKind {
        guard let eventError = error as? EventError else {
            return .terminal
        }
        return switch eventError.code {
        case .couldNotComplete, .eventOperationTimeout, .frameCheckTimeout, .otherTimeout:
            .noResponse
        case .eventCreationFailure, .invalidAppState, .invalidEventSource,
            .invalidCursorLocation, .invalidItem, .notMovable:
            .terminal
        }
    }

    /// Returns a Boolean value that indicates whether the given events have the
    /// same values for each integer value field.
    ///
    /// - Parameters:
    ///   - events: The events to compare.
    ///   - integerFields: An array of integer value fields to compare on each event.
    private nonisolated func eventsMatch(_ events: [CGEvent], by integerFields: [CGEventField]) -> Bool {
        var fieldValues = Set<[Int64]>()
        for event in events {
            let values = integerFields.map(event.getIntegerValueField)
            fieldValues.insert(values)
            if fieldValues.count != 1 {
                return false
            }
        }
        return true
    }

    /// Posts an event to the given event tap location.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    private nonisolated func postEvent(_ event: CGEvent, to location: EventTap.Location) {
        Logger.itemManager.debug("Posting \(event.type.logString) to \(location.logString)")
        switch location {
        case .hidEventTap:
            event.post(tap: .cghidEventTap)
        case .sessionEventTap:
            event.post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap:
            event.post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        }
    }

    /// Posts an event to the given event tap location and waits until it is
    /// received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - location: The event tap location to post the event to.
    ///   - item: The menu bar item that the event affects.
    private func postEventAndWaitToReceive(
        _ event: CGEvent,
        to location: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let eventTap = EventTap(
                options: .listenOnly,
                location: location,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                Logger.itemManager.debug("Received \(type.logString) at \(location.logString) (item: \(item.logString))")

                proxy.disable()
                continuation.resume()

                return nil
            }

            eventTap.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap.label)\" timed out (item: \(item.logString))")
                eventTap.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            postEvent(event, to: location)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The menu bar item that the event affects.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        item: MenuBarItem
    ) async throws {
        guard let nullEvent = CGEvent(source: nil) else {
            throw EventError(code: .eventCreationFailure, item: item)
        }
        let userData: Int64 = 0x1CE
        nullEvent.setIntegerValueField(.eventSourceUserData, value: userData)

        return try await withCheckedThrowingContinuation { continuation in
            // Create an event tap for the null event at the first location that throws away
            // all events it receives. Once the null event is received, post the real event
            // to the second location.
            let eventTap1 = EventTap(
                label: "EventTap 1",
                options: .defaultTap,
                location: firstLocation,
                place: .tailAppendEventTap,
                types: [nullEvent.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard rEvent.getIntegerValueField(.eventSourceUserData) == userData else {
                    return nil
                }

                proxy.disable()
                postEvent(event, to: secondLocation)

                return nil
            }

            // Create an event tap for the real event at the second location that can listen
            // for events but not alter or discard them. Once the event is received, post it
            // to the first location.
            let eventTap2 = EventTap(
                label: "EventTap 2",
                options: .listenOnly,
                location: secondLocation,
                place: .tailAppendEventTap,
                types: [event.type]
            ) { [weak self] proxy, type, rEvent in
                guard let self else {
                    proxy.disable()
                    return nil
                }

                // Reenable the tap if disabled by the system.
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }

                // Verify that the received event was the sent event.
                guard eventsMatch([rEvent, event], by: CGEventField.menuBarItemEventFields) else {
                    return nil
                }

                // Ensure the tap is enabled, preventing multiple calls to resume().
                guard proxy.isEnabled else {
                    Logger.itemManager.debug("Event tap \"\(proxy.label)\" is disabled (item: \(item.logString))")
                    return nil
                }

                proxy.disable()
                postEvent(event, to: firstLocation)
                continuation.resume()

                return nil
            }

            // Enable both taps, with a timeout on the second tap.
            eventTap1.enable()
            eventTap2.enable(timeout: .milliseconds(50)) {
                Logger.itemManager.error("Event tap \"\(eventTap2.label)\" timed out (item: \(item.logString))")
                eventTap1.disable()
                eventTap2.disable()
                continuation.resume(throwing: EventError(code: .eventOperationTimeout, item: item))
            }

            // Post the null event to the first location.
            postEvent(nullEvent, to: firstLocation)
        }
    }

    /// Does a lot of weird magic to make a menu bar item receive an event, then
    /// waits for the frame of the given menu bar item to change before returning.
    ///
    /// - Parameters:
    ///   - event: The event to send.
    ///   - firstLocation: The first location to send the event to.
    ///   - secondLocation: The second location to send the event to.
    ///   - item: The item whose frame should be observed.
    private func scrombleEvent(
        _ event: CGEvent,
        from firstLocation: EventTap.Location,
        to secondLocation: EventTap.Location,
        waitingForFrameChangeOf item: MenuBarItem
    ) async throws {
        guard let currentFrame = getCurrentFrame(for: item) else {
            try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
            Logger.itemManager.warning("Couldn't get menu bar item frame for \(item.logString), so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
            return
        }
        try await scrombleEvent(event, from: firstLocation, to: secondLocation, item: item)
        try await waitForFrameChange(of: item, initialFrame: currentFrame, timeout: .milliseconds(50))
    }

    /// Waits for a menu bar item's frame to change from an initial frame.
    ///
    /// - Parameters:
    ///   - item: The item whose frame should be observed.
    ///   - initialFrame: An initial frame to compare the item's frame against.
    ///   - timeout: The amount of time to wait before throwing a timeout error.
    private func waitForFrameChange(
        of item: MenuBarItem,
        initialFrame: CGRect,
        timeout: Duration
    ) async throws {
        struct FrameCheckCancellationError: Error { }

        let frameCheckTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                guard let currentFrame = await self.getCurrentFrame(for: item) else {
                    throw FrameCheckCancellationError()
                }
                if currentFrame != initialFrame {
                    Logger.itemManager.debug("Menu bar item frame for \(item.logString) has changed to \(NSStringFromRect(currentFrame))")
                    return
                }
            }
        }
        do {
            try await frameCheckTask.value
        } catch is FrameCheckCancellationError {
            Logger.itemManager.warning("Menu bar item frame check for \(item.logString) was cancelled, so using fixed delay")
            // This will be slow, but subsequent events will have a better chance of succeeding.
            try await Task.sleep(for: .milliseconds(50))
        } catch is TaskTimeoutError {
            throw EventError(code: .frameCheckTimeout, item: item)
        }
    }

    /// Permits all events for an event source during the given suppression states,
    /// suppressing local events for the given interval.
    private func permitAllEvents(
        for stateID: CGEventSourceStateID,
        during states: [CGEventSuppressionState],
        suppressionInterval: TimeInterval,
        item: MenuBarItem
    ) throws {
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = suppressionInterval
    }

    /// Tries to wake up the given item if it is not responding to events.
    private func wakeUpItem(_ item: MenuBarItem) async throws {
        guard item.isMovable else {
            throw EventError(code: .notMovable, item: item)
        }
        Logger.itemManager.debug("Attempting to wake up \(item.logString)")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        let currentFrame = item.frame

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: CGPoint(x: currentFrame.midX, y: currentFrame.midY),
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try await scrombleEvent(
            mouseDownEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
        try await scrombleEvent(
            mouseUpEvent,
            from: .pid(item.ownerPID),
            to: .sessionEventTap,
            item: item
        )
    }

    /// Moves a menu bar item to the given destination, without restoring the mouse
    /// pointer to its initial location.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    private func moveItemWithoutRestoringMouseLocation(
        _ item: MenuBarItem,
        to destination: MoveDestination
    ) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }

        guard item.isMovable else {
            throw EventError(code: .notMovable, item: item)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }

        let startPoint = CGPoint(x: 20_000, y: 20_000)
        let endPoint = getEndPoint(for: destination)
        let fallbackPoint = getFallbackPoint(for: item)
        let targetItem = getTargetItem(for: destination)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseDown),
                location: startPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: endPoint,
                item: targetItem,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .move(.leftMouseUp),
                location: fallbackPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        lastItemMoveStartDate = .now

        do {
            try await scrombleEvent(
                mouseDownEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
            try await scrombleEvent(
                mouseUpEvent,
                from: .pid(item.ownerPID),
                to: .sessionEventTap,
                waitingForFrameChangeOf: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for moving \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for moving \(item.logString)")
            }
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    func move(item: MenuBarItem, to destination: MoveDestination, maxAttempts: Int = 5) async throws {
        guard let initialEndpoints = refreshedMoveEndpoints(
            item: item,
            destination: destination
        ) else {
            throw EventError(code: .invalidItem, item: item)
        }
        guard initialEndpoints.item.isMovable else {
            throw EventError(code: .notMovable, item: initialEndpoints.item)
        }
        if itemHasCorrectPosition(
            item: initialEndpoints.item,
            for: initialEndpoints.destination
        ) {
            Logger.itemManager.debug(
                "\(initialEndpoints.item.logString) is already in the correct position"
            )
            return
        }

        do {
            try await waitForMouseToStopMoving(timeout: maxAttempts == 1 ? .seconds(1) : nil)
        } catch {
            throw EventError(code: .couldNotComplete, item: item)
        }
        if maxAttempts == 1, NSEvent.pressedMouseButtons != 0 {
            throw EventError(code: .couldNotComplete, item: item)
        }

        Logger.itemManager.info("Moving \(item.logString) to \(destination.logString)")

        guard let appState else {
            throw EventError(code: .invalidAppState, item: item)
        }
        guard let cursorLocation = MouseCursor.location(in: .coreGraphics) else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        appState.eventManager.stopAll()
        defer {
            appState.eventManager.startAll()
        }

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        // Automatic restoration uses one attempt and must not click to wake an item.
        let attemptLimit = max(1, maxAttempts)
        for n in 1...attemptLimit {
            guard let endpoints = refreshedMoveEndpoints(
                item: item,
                destination: destination
            ) else {
                throw EventError(code: .invalidItem, item: item)
            }
            guard endpoints.item.isMovable else {
                throw EventError(code: .notMovable, item: endpoints.item)
            }
            if itemHasCorrectPosition(
                item: endpoints.item,
                for: endpoints.destination
            ) {
                Logger.itemManager.info("Successfully moved \(endpoints.item.logString)")
                return
            }
            do {
                try await moveItemWithoutRestoringMouseLocation(
                    endpoints.item,
                    to: endpoints.destination
                )
                guard let current = refreshedMoveEndpoints(
                    item: item,
                    destination: destination
                ) else {
                    throw EventError(code: .invalidItem, item: item)
                }
                guard itemHasCorrectPosition(
                    item: current.item,
                    for: current.destination
                ) else {
                    throw EventError(code: .couldNotComplete, item: item)
                }
                Logger.itemManager.info("Successfully moved \(current.item.logString)")
                return
            } catch {
                Logger.itemManager.warning("Attempt \(n) to move \(item.logString) failed (error: \(error))")
                guard
                    let current = refreshedMoveEndpoints(
                        item: item,
                        destination: destination
                    )
                else {
                    throw EventError(code: .invalidItem, item: item)
                }
                if itemHasCorrectPosition(
                    item: current.item,
                    for: current.destination
                ) {
                    Logger.itemManager.info("Successfully moved \(current.item.logString)")
                    return
                }
                let failure = moveFailureKind(for: error)
                guard MenuBarItemMoveRetryPolicy.shouldWake(
                    item: current.item,
                    failure: failure,
                    attemptsRemain: n < attemptLimit
                ) else {
                    throw error
                }
                try await wakeUpItem(current.item)
                Logger.itemManager.info("Retrying move of \(item.logString)")
            }
        }
    }

    /// Moves a menu bar item to the given destination and waits until the move
    /// completes before returning.
    /// 
    /// - Parameters:
    ///   - item: A menu bar item to move.
    ///   - destination: A destination to move the menu bar item.
    ///   - timeout: Amount of time to wait before throwing an error.
    func slowMove(
        item: MenuBarItem,
        to destination: MoveDestination,
        timeout: Duration = .seconds(1),
        maxAttempts: Int = 5
    ) async throws {
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
        }
        try await move(item: item, to: destination, maxAttempts: maxAttempts)
        let waitTask = Task(timeout: timeout) {
            while true {
                try Task.checkCancellation()
                guard let endpoints = await self.refreshedMoveEndpoints(
                    item: item,
                    destination: destination
                ) else {
                    throw EventError(code: .invalidItem, item: item)
                }
                if await self.itemHasCorrectPosition(
                    item: endpoints.item,
                    for: endpoints.destination
                ) {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        do {
            try await waitTask.value
        } catch is TaskTimeoutError {
            throw EventError(code: .otherTimeout, item: item)
        }
    }
}

// MARK: - Click Items

extension MenuBarItemManager {
    /// Clicks the given menu bar item with the given button states.
    private func click(
        item: MenuBarItem,
        mouseDownButtonState: CGEvent.MenuBarItemEventButtonState,
        mouseUpButtonState: CGEvent.MenuBarItemEventButtonState
    ) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw EventError(code: .invalidEventSource, item: item)
        }
        guard let cursorLocation = MouseCursor.location(in: .coreGraphics) else {
            throw EventError(code: .invalidCursorLocation, item: item)
        }
        guard let currentFrame = getCurrentFrame(for: item) else {
            throw EventError(code: .invalidItem, item: item)
        }

        let clickPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        guard
            let mouseDownEvent = CGEvent.menuBarItemEvent(
                type: .click(mouseDownButtonState),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let mouseUpEvent = CGEvent.menuBarItemEvent(
                type: .click(mouseUpButtonState),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            ),
            let fallbackEvent = CGEvent.menuBarItemEvent(
                type: .click(mouseUpButtonState),
                location: clickPoint,
                item: item,
                pid: item.ownerPID,
                source: source
            )
        else {
            throw EventError(code: .eventCreationFailure, item: item)
        }

        try permitAllEvents(
            for: .combinedSessionState,
            during: [
                .eventSuppressionStateRemoteMouseDrag,
                .eventSuppressionStateSuppressionInterval,
            ],
            suppressionInterval: 0,
            item: item
        )

        MouseCursor.hide()

        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.show()
        }

        do {
            try await postEventAndWaitToReceive(
                mouseDownEvent,
                to: .sessionEventTap,
                item: item
            )
            try await postEventAndWaitToReceive(
                mouseUpEvent,
                to: .sessionEventTap,
                item: item
            )
        } catch {
            do {
                Logger.itemManager.debug("Posting fallback event for clicking \(item.logString)")
                // Catch this, as we still want to throw the existing error if the fallback fails.
                try await postEventAndWaitToReceive(
                    fallbackEvent,
                    to: .sessionEventTap,
                    item: item
                )
            } catch {
                Logger.itemManager.error("Failed to post fallback event for clicking \(item.logString)")
            }
            throw error
        }
    }

    /// Clicks the given menu bar item with the given mouse button.
    func click(item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        Logger.itemManager.info("Clicking \(item.logString) with \(mouseButton.logString)")
        try await click(
            item: item,
            mouseDownButtonState: mouseButton.downState,
            mouseUpButtonState: mouseButton.upState
        )
    }
}

// MARK: - Temporarily Show Items

extension MenuBarItemManager {
    /// Gets the destination to return the given item to after it is temporarily shown.
    private func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        if let index = items.firstIndex(where: { $0.windowID == item.windowID }) {
            if items.indices.contains(index + 1) {
                return .leftOfItem(items[index + 1])
            } else if items.indices.contains(index - 1) {
                return .rightOfItem(items[index - 1])
            }
        }
        return nil
    }

    /// Schedules a timer for the given interval, attempting to rehide the current
    /// temporarily shown items when the timer fires.
    private func runTempShownItemTimer(for interval: TimeInterval) {
        Logger.itemManager.debug("Running rehide timer for temporarily shown items with interval: \(interval)")
        tempShownItemsTimer?.invalidate()
        tempShownItemsTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Logger.itemManager.debug("Rehide timer fired")
            Task {
                await self.rehideTempShownItems()
            }
        }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached alongside a destination that it will be automatically
    /// returned to. If `true` is passed to the `clickWhenFinished` parameter, the
    /// item is clicked once movement is finished.
    ///
    /// - Parameters:
    ///   - item: An item to show.
    ///   - clickWhenFinished: A Boolean value that indicates whether the item should
    ///     be clicked once movement has finished.
    ///   - mouseButton: The mouse button of the click.
    func tempShowItem(
        _ item: MenuBarItem,
        clickWhenFinished: Bool,
        mouseButton: CGMouseButton
    ) {
        guard !isRestoringSection, !isPerformingUserMove, !isTemporarilyShowingItem,
              !isMovingItem, nativeDrag == nil, item.isMovable, item.canBeHidden else {
            return
        }
        if
            let latest = MenuBarItem(windowID: item.windowID),
            item.isSameWindow(as: latest),
            latest.isOnScreen
        {
            if clickWhenFinished {
                Task {
                    do {
                        try await click(item: latest, with: mouseButton)
                    } catch {
                        Logger.itemManager.error("ERROR: \(error)")
                    }
                }
            }
            return
        }

        guard
            let appState,
            let screen = NSScreen.screenWithActiveMenuBar ??
            NSScreen.screens.first(where: {
                let bounds = CGDisplayBounds($0.displayID)
                return (bounds.minY ... bounds.maxY).contains(item.frame.midY)
            }) ?? NSScreen.main,
            let applicationMenuFrame = appState.menuBarManager.getApplicationMenuFrame(for: screen.displayID)
        else {
            Logger.itemManager.warning("No application menu frame, so not showing \(item.logString)")
            return
        }

        Logger.itemManager.info("Temporarily showing \(item.logString)")

        var items = MenuBarItem.getMenuBarItems(
            on: screen.displayID,
            onScreenOnly: false,
            activeSpaceOnly: true
        )

        guard
            !tempShownItemContexts.contains(where: { $0.matches(item) }),
            items.contains(where: { $0.info == .hiddenControlItem }),
            let destination = getReturnDestination(for: item, in: items),
            let currentItem = MenuBarItem.exactlyMatching(item, in: items),
            let currentSection = physicalSection(of: currentItem, in: items)
        else {
            Logger.itemManager.warning("No return destination for \(item.logString)")
            return
        }
        let identity = persistenceIdentityPolicy.eligibleIdentity(for: currentItem)
        let originalSection = identity.flatMap {
            sectionStore?.section(for: $0)
        } ?? currentSection

        // Remove all items up to the hidden control item.
        items.trimPrefix { $0.info != .hiddenControlItem }
        // Remove the hidden control item.
        items.removeFirst()
        // Remove all offscreen items.
        items.trimPrefix { !$0.isOnScreen }

        let maxX = if let rightArea = screen.auxiliaryTopRightArea {
            max(rightArea.minX + 20, applicationMenuFrame.maxX)
        } else {
            applicationMenuFrame.maxX
        }

        // Remove items until we have enough room to show this item.
        items.trimPrefix { $0.frame.minX - item.frame.width <= maxX }

        guard let targetItem = items.first else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Not enough room to show \"\(item.displayName)\"")
            alert.runModal()
            return
        }

        let initialWindows = WindowInfo.getOnScreenWindows()
        if let identity {
            do {
                // Survives Ice or the other app quitting before the item is returned.
                // A pending restore must keep its saved section, not the drifted one.
                try sectionStore?.remember(identity, in: originalSection)
            } catch {
                Logger.itemManager.error("Could not preserve temporarily shown item's section: \(error)")
            }
        }
        tempShownItemContexts.append(TempShownItemContext(
            item: currentItem,
            interfacePIDs: Set(
                [currentItem.ownerPID, currentItem.sourcePID].compactMap(\.self)
            ),
            preexistingInterfaceWindowIDs: Set(
                initialWindows.map(\.windowID)
            ),
            displayID: screen.displayID,
            returnDestination: destination,
            originalSection: originalSection,
            shownInterfaceWindow: nil
        ))
        isTemporarilyShowingItem = true

        Task {
            defer {
                isTemporarilyShowingItem = false
                deferSectionRestoration()
            }
            if clickWhenFinished {
                do {
                    try await slowMove(item: item, to: .leftOfItem(targetItem))
                    try await click(item: item, with: mouseButton)
                } catch {
                    Logger.itemManager.error("ERROR: \(error)")
                }
            } else {
                do {
                    try await move(item: item, to: .leftOfItem(targetItem))
                } catch {
                    Logger.itemManager.error("ERROR: \(error)")
                }
            }

            try? await Task.sleep(for: .milliseconds(100))

            let currentWindows = WindowInfo.getOnScreenWindows()
            let latestItem = MenuBarItem(windowID: item.windowID)
            let interfacePIDs = Set(
                [
                    currentItem.ownerPID,
                    currentItem.sourcePID,
                    latestItem?.ownerPID,
                    latestItem?.sourcePID,
                ].compactMap(\.self)
            )
            let shownInterfaceWindow = MenuBarItem.firstInterfaceWindow(
                in: currentWindows,
                ownedBy: interfacePIDs,
                excluding: Set(initialWindows.map(\.windowID))
            )

            if let index = tempShownItemContexts.firstIndex(where: { $0.matches(item) }) {
                tempShownItemContexts[index].interfacePIDs.formUnion(
                    interfacePIDs
                )
                tempShownItemContexts[index].shownInterfaceWindow = shownInterfaceWindow
            }
            runTempShownItemTimer(for: appState.settingsManager.advancedSettingsManager.tempShowInterval)
        }
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits for the
    /// interface to close before hiding the items.
    func rehideTempShownItems() async {
        guard !isRestoringSection, !isPerformingUserMove, !isTemporarilyShowingItem,
              !isMovingItem, nativeDrag == nil else {
            runTempShownItemTimer(for: 3)
            return
        }
        itemMoveCount += 1
        defer {
            itemMoveCount -= 1
            deferSectionRestoration()
        }

        guard !tempShownItemContexts.isEmpty else {
            return
        }

        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }
        guard !tempShownItemContexts.contains(where: { $0.isShowingInterface }) else {
            Logger.itemManager.debug("Menu bar item interface is shown, so waiting to rehide")
            runTempShownItemTimer(for: 3)
            return
        }

        Logger.itemManager.info("Rehiding temporarily shown items")

        var failedContexts = [TempShownItemContext]()

        while let context = tempShownItemContexts.popLast() {
            let globalItems = MenuBarItem.getMenuBarItems(
                onScreenOnly: false,
                activeSpaceOnly: false
            )
            guard
                let globalItem = MenuBarItem.exactlyMatching(
                    context.item,
                    in: globalItems
                )
            else {
                continue
            }

            var candidateDisplayIDs = NSScreen.screens.compactMap { screen in
                CGDisplayBounds(screen.displayID).intersects(globalItem.frame) ?
                    screen.displayID : nil
            }
            if !candidateDisplayIDs.contains(context.displayID) {
                candidateDisplayIDs.append(context.displayID)
            }
            for displayID in NSScreen.screens.map(\.displayID)
                where !candidateDisplayIDs.contains(displayID) {
                candidateDisplayIDs.append(displayID)
            }

            var liveItem: MenuBarItem?
            var destination: MoveDestination?
            for displayID in candidateDisplayIDs {
                let items = MenuBarItem.getMenuBarItems(
                    on: displayID,
                    onScreenOnly: false,
                    activeSpaceOnly: true
                )
                guard
                    let item = MenuBarItem.exactlyMatching(context.item, in: items),
                    let resolvedDestination = resolvedReturnDestination(
                        context,
                        in: items
                    )
                else {
                    continue
                }
                liveItem = item
                destination = resolvedDestination
                break
            }
            guard let item = liveItem, let destination else {
                failedContexts.append(context)
                continue
            }
            do {
                try await slowMove(item: item, to: destination)
            } catch {
                Logger.itemManager.error("Failed to rehide \(item.logString) (error: \(error))")
                failedContexts.append(context)
            }
        }

        if failedContexts.isEmpty {
            tempShownItemsTimer?.invalidate()
            tempShownItemsTimer = nil
        } else {
            tempShownItemContexts = failedContexts
            Logger.itemManager.warning("Some items failed to rehide")
            runTempShownItemTimer(for: 3)
        }
    }

    private func resolvedReturnDestination(_ context: TempShownItemContext, in items: [MenuBarItem]) -> MoveDestination? {
        let targetItem = getTargetItem(for: context.returnDestination)
        let target = MenuBarItem.matching(targetItem, in: items)
        if let target,
           physicalSection(of: target, in: items) == context.originalSection {
            switch context.returnDestination {
            case .leftOfItem: return .leftOfItem(target)
            case .rightOfItem: return .rightOfItem(target)
            }
        }
        // Resolve against fresh windows, never a stale neighbor's window ID.
        if context.originalSection == .alwaysHidden,
           appState?.menuBarManager.section(withName: .alwaysHidden)?.isEnabled == false {
            return sectionDestination(.hidden, in: items)
        }
        return sectionDestination(context.originalSection, in: items)
    }

    /// Removes a temporarily shown item from the cache.
    ///
    /// This ensures that the item will _not_ be returned to its previous location.
    func removeTempShownItemFromCache(matching item: MenuBarItem) {
        tempShownItemContexts.removeAll { $0.matches(item) }
    }
}

// MARK: - Arrange Items

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the always-hidden
    /// control item stays to the left of the hidden control item.
    ///
    /// - Parameters:
    ///   - hiddenControlItem: A menu bar item that represents the control item for
    ///     the hidden section.
    ///   - alwaysHiddenControlItem: A menu bar item that represents the control item
    ///     for the always-hidden section.
    func enforceControlItemOrder(
        hiddenControlItem: MenuBarItem,
        alwaysHiddenControlItem: MenuBarItem
    ) async throws {
        guard !isMouseButtonDown else {
            Logger.itemManager.debug("Mouse button is down, so will not enforce control item order")
            return
        }
        guard !mouseHasRecentlyMoved else {
            Logger.itemManager.debug("Mouse has recently moved, so will not enforce control item order")
            return
        }
        if hiddenControlItem.frame.maxX <= alwaysHiddenControlItem.frame.minX {
            Logger.itemManager.info("Arranging menu bar items")
            try await slowMove(item: alwaysHiddenControlItem, to: .leftOfItem(hiddenControlItem))
        }
    }
}

// MARK: - CGEvent Helpers

private extension CGEvent {
    /// Button states for menu bar item events.
    enum MenuBarItemEventButtonState {
        case leftMouseDown
        case leftMouseUp
        case rightMouseDown
        case rightMouseUp
        case otherMouseDown
        case otherMouseUp
    }

    /// Event types for menu bar item events.
    enum MenuBarItemEventType {
        /// The event type for moving a menu bar item.
        case move(MenuBarItemEventButtonState)
        /// The event type for clicking a menu bar item.
        case click(MenuBarItemEventButtonState)

        /// The button state of this event type.
        var buttonState: MenuBarItemEventButtonState {
            switch self {
            case .move(let state), .click(let state): state
            }
        }

        /// This event type's equivalent CGEventType.
        var cgEventType: CGEventType {
            switch buttonState {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseUp: .leftMouseUp
            case .rightMouseDown: .rightMouseDown
            case .rightMouseUp: .rightMouseUp
            case .otherMouseDown: .otherMouseDown
            case .otherMouseUp: .otherMouseUp
            }
        }

        /// The event flags for this event type.
        var cgEventFlags: CGEventFlags {
            switch self {
            case .move(.leftMouseDown): .maskCommand
            case .move, .click: []
            }
        }

        /// The mouse button for this event type.
        var mouseButton: CGMouseButton {
            switch buttonState {
            case .leftMouseDown, .leftMouseUp: .left
            case .rightMouseDown, .rightMouseUp: .right
            case .otherMouseDown, .otherMouseUp: .center
            }
        }
    }

    /// A context that manages the user data for menu bar item events.
    enum MenuBarItemEventUserDataContext {
        /// The internal state of the context.
        private static var state: Int64 = 0x1CE

        /// Returns the current user data and increments the internal state.
        static func next() -> Int64 {
            defer { state += 1 }
            return state
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the window number of the event.
    static let windowNumber = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// An array of integer event fields that can be used to compare two menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowNumber,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }

    /// The menu bar item event state for when this mouse button is down.
    var downState: CGEvent.MenuBarItemEventButtonState {
        switch self {
        case .left:
            return .leftMouseDown
        case .right:
            return .rightMouseDown
        case .center:
            return .otherMouseDown
        @unknown default:
            fatalError("Unknown mouse button \(rawValue)")
        }
    }

    /// The menu bar item event state for when this mouse button is up.
    var upState: CGEvent.MenuBarItemEventButtonState {
        switch self {
        case .left:
            return .leftMouseUp
        case .right:
            return .rightMouseUp
        case .center:
            return .otherMouseUp
        @unknown default:
            fatalError("Unknown mouse button \(rawValue)")
        }
    }
}

// MARK: - CGEvent Constructor

private extension CGEvent {
    /// Returns an event that can be sent to the given menu bar item.
    ///
    /// - Parameters:
    ///   - type: The type of the event.
    ///   - location: The location of the event. Does not need to be within the bounds of the item.
    ///   - item: The target item of the event.
    ///   - pid: The target process identifier of the event. Does not need to be the item's `ownerPID`.
    ///   - source: The source of the event.
    class func menuBarItemEvent(
        type: MenuBarItemEventType,
        location: CGPoint,
        item: MenuBarItem,
        pid: pid_t,
        source: CGEventSource
    ) -> CGEvent? {
        let mouseType = type.cgEventType
        let mouseButton = type.mouseButton

        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: mouseType,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        ) else {
            return nil
        }

        event.flags = type.cgEventFlags

        let targetPID = Int64(pid)
        let userData = MenuBarItemEventUserDataContext.next()
        let windowNumber = Int64(item.windowID)

        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowNumber)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowNumber)
        event.setIntegerValueField(.windowNumber, value: windowNumber)

        if case .click = type {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        return event
    }
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for the menu bar item manager.
    static let itemManager = Logger(category: "MenuBarItemManager")
}
