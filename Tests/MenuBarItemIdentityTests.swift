import Cocoa

private typealias Store = MenuBarItemSectionStore

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw NSError(domain: "ItemIdentityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func withStore(_ body: (Store, UserDefaults) throws -> Void) throws {
    let name = "FloeBar.ItemIdentityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(Store(defaults: defaults), defaults)
}

private func sample(
    _ items: [MenuBarItem],
    section: Store.Section = .visible,
    policy: MenuBarItemPersistenceIdentityPolicy = .init()
) -> [Store.Item] {
    items.compactMap { item in
        policy.eligibleIdentity(for: item).map {
            Store.Item(identity: $0, windowID: item.windowID, processID: item.sourcePID ?? item.ownerPID, section: section)
        }
    }
}

private func enumerate(_ ids: [UInt32], owner: pid_t = 100) -> [MenuBarItem] {
    MenuBarItem.getMenuBarItems(from: ids.map { WindowInfo($0, ownerPID: owner, x: CGFloat($0)) })
}

@main
private enum MenuBarItemIdentityTests {
    static func main() throws {
        try equalityAndCacheReplacement()
        try duplicateRemovalAndRelaunch()
        try legacyDuplicateRecords()
        try duplicateLearningAndExclusions()
        try provisionalTransition()
        try runtimeMatching()
        try operationEndpointValidation()
        try pendingNativeDragIntent()
        try actionabilityAndRetryPolicy()
        try interfaceWindowSelection()
        try controlItemTitleRecognition()
        try visibleControlItemLayoutBehavior()
        try displayFiltering()
        try uniqueRestoration()
        print("PASS: 14 item identity regression groups")
    }

    private static func equalityAndCacheReplacement() throws {
        let window = WindowInfo(1, ownerPID: 10)
        let cache = MenuBarItemSourcePIDCache.shared
        cache.sources = [:]
        let unresolved = MenuBarItem(itemWindow: window)!
        cache.sources[1] = 100
        let resolved = MenuBarItem(itemWindow: window)!
        try expect(unresolved.window == resolved.window, "Fixture window metadata must be identical")
        try expect(unresolved != resolved, "Source resolution must invalidate item equality")

        // Change only sourcePID: both PIDs resolve to the same bundle.
        NSRunningApplication.bundles[101] = "test.application"
        cache.sources[1] = 101
        let differentPID = MenuBarItem(itemWindow: window)!
        try expect(resolved.info == differentPID.info && resolved != differentPID, "Equality must include sourcePID")

        // Change only info: the same source PID now has a different resolved bundle.
        NSRunningApplication.bundles[101] = "renamed.application"
        let differentInfo = MenuBarItem(itemWindow: window)!
        try expect(differentPID.sourcePID == differentInfo.sourcePID && differentPID != differentInfo,
                   "Equality must include source-derived info")
        try expect(Set([unresolved, resolved, differentPID, differentInfo]).count == 4,
                   "Hashed collections must retain distinct resolved identities")

        var published = ["visible": [unresolved]]
        let refreshed = ["visible": [resolved]]
        var publications = 0
        if published != refreshed {
            published = refreshed
            publications += 1
        }
        try expect(publications == 1 && published["visible"]?.first?.sourcePID == 100,
                   "An unchanged-window cache must publish resolved identity")

        cache.sources = [10: 100, 20: 100]
        let before = enumerate([10, 20]).first { $0.windowID == 20 }!
        let after = enumerate([20])[0]
        try expect(before.window == after.window && before.info == after.info && before.sourcePID == after.sourcePID,
                   "Only the ordinal should differ")
        try expect(before.instanceIndex == 1 && after.instanceIndex == 0 && before != after,
                   "Equality must include snapshot index")
        try expect(Set([before, after]).count == 2, "Hashable must agree with ordinal equality")
    }

    private static func duplicateRemovalAndRelaunch() throws {
        try withStore { store, defaults in
            MenuBarItemSourcePIDCache.shared.sources = [10: 100, 20: 100, 30: 100, 40: 100]
            let original = enumerate([10])[0]
            try store.remember(original.sectionIdentity!, in: .hidden)
            let pair = enumerate([10, 20])
            // A single unsettled sighting must suffice, even if a sibling vanishes immediately.
            _ = try store.observe(sample(pair), now: 0, excludedWindowIDs: [20])
            let survivor = enumerate([20])
            try expect(survivor[0].instanceIndex == 0, "Exercise actual index-one to index-zero renumbering")
            try expect(MenuBarItem.matching(pair[1], in: survivor)?.windowID == 20, "Keep the surviving exact window")
            try expect(MenuBarItem.matching(pair[0], in: survivor) == nil, "Do not match the removed sibling to new index zero")
            _ = try store.observe(sample(survivor), now: 1)
            try expect(try store.observe(sample(survivor), now: 2).restore == nil, "Survivor must not steal hidden index zero")

            let reloaded = try Store(defaults: defaults)
            let recreated = enumerate([40, 30])
            _ = try reloaded.observe(sample(recreated), now: 3)
            try expect(try reloaded.observe(sample(recreated), now: 4).restore == nil, "Reordered recreated windows remain ambiguous")
            let singleton = enumerate([30])
            _ = try reloaded.observe(sample(singleton), now: 5)
            try expect(try reloaded.observe(sample(singleton), now: 6).restore == nil, "Next-launch singleton remains quarantined")
            try expect(reloaded.section(for: original.sectionIdentity!) == nil, "Temporary moves must not read ambiguous saved intent")
            try expect(reloaded.savedItemCount == 1, "Old records must be retained")
            let document = try JSONSerialization.jsonObject(with: defaults.data(forKey: Store.defaultsKey)!) as! [String: Any]
            let records = document["records"] as! [[String: Any]]
            try expect(records.first?["section"] as? String == "hidden", "Quarantine must not overwrite the old record")

            // Also exercise removal of index one, leaving the original index zero.
            let firstSurvives = enumerate([10])
            _ = try reloaded.observe(sample(firstSurvives), now: 7)
            try expect(try reloaded.observe(sample(firstSurvives), now: 8).restore == nil, "Remaining index zero is still ambiguous")
        }
    }

    private static func legacyDuplicateRecords() throws {
        try withStore { _, defaults in
            defaults.set(Data(#"{"version":1,"records":[{"identity":{"bundleIdentifier":"test.application","title":"Icon","instanceIndex":0},"section":"hidden"},{"identity":{"bundleIdentifier":"test.application","title":"Icon","instanceIndex":1},"section":"visible"}]}"#.utf8),
                         forKey: Store.defaultsKey)
            let migrated = try Store(defaults: defaults)
            try expect(migrated.savedItemCount == 2, "Migration must retain both records")
            let singleton = sample(enumerate([20]))
            _ = try migrated.observe(singleton, now: 0)
            try expect(try migrated.observe(singleton, now: 1).restore == nil, "Legacy duplicate records must be quarantined on load")
            let relaunched = try Store(defaults: defaults)
            try expect(relaunched.section(for: singleton[0].identity) == nil, "Legacy ambiguity must survive another launch")
        }
    }

    private static func duplicateLearningAndExclusions() throws {
        try withStore { store, defaults in
            let pair = enumerate([10, 20])
            _ = try store.observe(sample(pair), now: 0, excludedWindowIDs: [20])
            _ = try store.observe(sample(pair), now: 1, excludedWindowIDs: [20], acceptAllChanges: true)
            try store.remember(pair[0].sectionIdentity!, in: .alwaysHidden)
            try expect(store.savedItemCount == 0, "Neither automatic nor explicit moves may persist ambiguous ordinals")
            let singleton = sample(enumerate([10]))
            let relaunched = try Store(defaults: defaults)
            _ = try relaunched.observe(singleton, now: 2)
            _ = try relaunched.observe(singleton, now: 3)
            try expect(relaunched.savedItemCount == 0, "Ambiguity must persist even with no saved records")
        }
        try withStore { store, _ in
            let second = enumerate([10, 20])[1]
            try store.remember(second.sectionIdentity!, in: .hidden)
            try expect(store.savedItemCount == 0, "A nonzero ordinal alone proves ambiguity")
        }
    }

    private static func provisionalTransition() throws {
        func snapshot(_ ids: [UInt32]) -> [MenuBarItem] {
            MenuBarItem.getMenuBarItems(from: ids.map {
                WindowInfo($0, title: "Item-0", ownerPID: 10, x: CGFloat($0))
            })
        }
        try withStore { store, defaults in
            let cache = MenuBarItemSourcePIDCache.shared
            NSRunningApplication.bundles[200] = "other.application"
            cache.sources = [10: 100, 20: 200]
            let known = snapshot([10, 20])
            try expect(known[0].sectionIdentity!.bundleIdentifier != known[1].sectionIdentity!.bundleIdentifier,
                       "Fixture must contain two distinct bundles with title Item-0")
            for item in known {
                try store.remember(item.sectionIdentity!, in: .hidden)
            }
            let saved = defaults.data(forKey: Store.defaultsKey)
            cache.sources = [:]
            let provisional = snapshot([10, 20])
            var policy = MenuBarItemPersistenceIdentityPolicy()
            let unresolved = policy.update(fromFullSnapshot: provisional)
            try expect(unresolved.isEmpty, "Never persist unresolved source identities")
            try expect(policy.provisionalDuplicateTitles == ["Item-0"], "Block unresolved duplicate titles temporarily")
            try store.noteIdentities(unresolved)
            try expect(defaults.data(forKey: Store.defaultsKey) == saved, "Unknown ownership must not persist ambiguity")

            cache.sources = [10: 100, 30: 100]
            let partial = snapshot([10, 20])
            let unrelated = MenuBarItem(itemWindow: WindowInfo(30, title: "Other", ownerPID: 10))!
            let identities = policy.update(fromFullSnapshot: partial + [unrelated])
            try expect(identities.count == 2, "Return each resolved identity exactly once")
            try store.noteIdentities(identities)
            try expect(sample(partial, policy: policy).isEmpty, "Partially resolved matching titles must remain blocked")
            try expect(sample(partial.filter { !$0.hasProvisionalIdentity }, policy: policy).isEmpty,
                       "Filtering out an unresolved sibling must not clear the full snapshot's block")
            let observations = sample(partial + [unrelated], policy: policy)
            _ = try store.observe(observations, now: 0)
            try expect(try store.observe(observations, now: 1).restore == nil, "Do not restore a temporarily blocked title")
            try expect(store.section(for: unrelated.sectionIdentity!) == .visible, "Other titles must still be learned")
            let reloaded = try Store(defaults: defaults)
            for item in known {
                try expect(reloaded.section(for: item.sectionIdentity!) == .hidden,
                           "Quitting before resolution must preserve independent saved intent")
            }

            cache.sources = [10: 100, 20: 200]
            let resolved = snapshot([10, 20])
            try expect(MenuBarItem.matching(provisional[0], in: resolved)?.windowID == provisional[0].windowID,
                       "Source resolution must retain the exact live window")
            try store.noteIdentities(policy.update(fromFullSnapshot: resolved))
            try expect(policy.provisionalDuplicateTitles.isEmpty, "Resolved bundles must clear the temporary block")
            _ = try store.observe(sample(resolved, policy: policy), now: 2)
            let first = try store.observe(sample(resolved, policy: policy), now: 3).restore
            try expect(first?.item.windowID == 10 && first?.section == .hidden, "First resolved Item-0 bundle must restore")
            let corrected = sample(resolved.filter { $0.windowID == 10 }, section: .hidden, policy: policy) +
                sample(resolved.filter { $0.windowID == 20 }, policy: policy)
            _ = try store.observe(corrected, now: 4)
            let second = try store.observe(corrected, now: 5).restore
            try expect(second?.item.windowID == 20 && second?.section == .hidden, "Second resolved Item-0 bundle must restore")
        }
        try withStore { store, defaults in
            let cache = MenuBarItemSourcePIDCache.shared
            cache.sources = [:]
            var policy = MenuBarItemPersistenceIdentityPolicy()
            try store.noteIdentities(policy.update(fromFullSnapshot: snapshot([10, 20])))
            cache.sources = [10: 100]
            let partial = snapshot([10, 20])
            try store.noteIdentities(policy.update(fromFullSnapshot: partial))
            _ = try store.observe(sample(partial, policy: policy), now: 0)
            _ = try store.observe(sample(partial, policy: policy), now: 1, acceptAllChanges: true)
            try expect(store.savedItemCount == 0, "Do not learn matching titles while ownership is unresolved")
            // A vanished unknown sibling is not proof of same-bundle ambiguity.
            cache.sources = [20: 100]
            let resolved = snapshot([20])
            try store.noteIdentities(policy.update(fromFullSnapshot: resolved))
            _ = try store.observe(sample(resolved, section: .hidden, policy: policy), now: 2)
            _ = try store.observe(sample(resolved, section: .hidden, policy: policy), now: 3)
            try expect(store.savedItemCount == 1, "A resolved singleton must become eligible for learning")
            let reloaded = try Store(defaults: defaults)
            _ = try reloaded.observe(sample(resolved), now: 4)
            try expect(try reloaded.observe(sample(resolved), now: 5).restore?.section == .hidden,
                       "Learned intent must restore after relaunch")
        }
        try withStore { store, defaults in
            let cache = MenuBarItemSourcePIDCache.shared
            cache.sources = [10: 100, 20: 100]
            var policy = MenuBarItemPersistenceIdentityPolicy()
            let mixed = snapshot([10, 20, 30])
            try store.noteIdentities(policy.update(fromFullSnapshot: mixed))
            try expect(sample(mixed, policy: policy).isEmpty, "An unresolved sibling must temporarily block the title")
            cache.sources = [20: 100]
            let singleton = snapshot([20])
            try store.noteIdentities(policy.update(fromFullSnapshot: singleton))
            try expect(policy.eligibleIdentity(for: singleton[0]) != nil, "Snapshot-local blocking must clear")
            let reloaded = try Store(defaults: defaults)
            _ = try reloaded.observe(sample(singleton, policy: policy), now: 0)
            _ = try reloaded.observe(sample(singleton, policy: policy), now: 1)
            try expect(reloaded.savedItemCount == 0, "Confirmed same-bundle duplicates must still persist ambiguity")
        }
    }

    private static func runtimeMatching() throws {
        MenuBarItemSourcePIDCache.shared.sources = [10: 100, 20: 100, 30: 100]
        let pair = enumerate([10, 20])
        try expect(MenuBarItem.matching(pair[1], in: pair)?.windowID == 20, "Exact window must beat earlier same-title candidate")
        try expect(MenuBarItem.matching(pair[0], in: enumerate([30])) == nil, "New application windows must not inherit runtime contexts")
        MenuBarItemSourcePIDCache.shared.sources[10] = 200
        try expect(MenuBarItem.matching(pair[0], in: enumerate([10])) == nil, "Reject a recycled window with a different resolved source")
        MenuBarItemSourcePIDCache.shared.sources[80] = 100
        let resolvedHosted = MenuBarItem(
            itemWindow: WindowInfo(
                80,
                title: "Item-0",
                ownerPID: 10
            )
        )!
        MenuBarItemSourcePIDCache.shared.sources[80] = nil
        let provisionalHosted = MenuBarItem(
            itemWindow: WindowInfo(
                80,
                title: "Item-0",
                ownerPID: 10
            )
        )!
        try expect(
            !resolvedHosted.isSameWindow(as: provisionalHosted),
            "A resolved item must not transfer context to a provisional replacement"
        )
        try expect(
            provisionalHosted.isSameWindow(as: resolvedHosted),
            "The same provisional item may acquire a resolved source"
        )
        let control = MenuBarItem(itemWindow: WindowInfo(70, title: "HItem"))!
        let replacement = MenuBarItem(itemWindow: WindowInfo(71, title: "HItem"))!
        let duplicate = MenuBarItem(itemWindow: WindowInfo(72, title: "HItem"))!
        try expect(MenuBarItem.matching(control, in: [replacement])?.windowID == 71, "Unique own controls may fall back by name")
        try expect(MenuBarItem.matching(control, in: [replacement, duplicate]) == nil, "Even control fallback must be unique")
    }

    private static func operationEndpointValidation() throws {
        let cache = MenuBarItemSourcePIDCache.shared
        cache.sources = [10: 100, 20: 200]
        let item = MenuBarItem(itemWindow: WindowInfo(10, x: 100))!
        let target = MenuBarItem(itemWindow: WindowInfo(20, ownerPID: 20, x: 200))!
        let freshWindows = [
            WindowInfo(10, x: 125),
            WindowInfo(20, ownerPID: 20, x: 275),
        ]
        let endpoints = MenuBarItem.operationEndpoints(
            item: item,
            target: target,
            in: freshWindows
        )
        try expect(
            endpoints?.item.frame.minX == 125 &&
                endpoints?.target.frame.minX == 275,
            "A move attempt must use both frames from the same fresh snapshot"
        )
        try expect(
            MenuBarItem.operationEndpoints(
                item: item,
                target: target,
                in: [freshWindows[0], WindowInfo(20, ownerPID: 21, x: 275)]
            ) == nil,
            "A recycled target window must invalidate the operation"
        )
        cache.sources[10] = 200
        try expect(
            MenuBarItem.operationEndpoints(
                item: item,
                target: target,
                in: freshWindows
            ) == nil,
            "A changed source identity must invalidate the operation"
        )
        try expect(
            MenuBarItem.operationEndpoints(
                item: target,
                target: target,
                in: freshWindows
            ) == nil,
            "A move cannot target its own window"
        )
    }

    private static func pendingNativeDragIntent() throws {
        let cache = MenuBarItemSourcePIDCache.shared
        cache.sources = [:]
        var policy = MenuBarItemPersistenceIdentityPolicy()
        var pending = MenuBarItemPendingSectionIntents()
        let provisional = MenuBarItem(
            itemWindow: WindowInfo(10, title: "Item-0", ownerPID: 10)
        )!
        _ = policy.update(fromFullSnapshot: [provisional])
        pending.record(postDragItem: provisional, section: .hidden, now: 0)
        try expect(
            pending.reconcile(
                withFullSnapshot: [provisional],
                policy: policy,
                now: 1
            ).isEmpty &&
                !pending.isEmpty,
            "A native drag must stay pending while its exact window is unresolved"
        )

        cache.sources[10] = 100
        let resolved = MenuBarItem(
            itemWindow: WindowInfo(10, title: "Item-0", ownerPID: 10)
        )!
        _ = policy.update(fromFullSnapshot: [resolved])
        let resolutions = pending.reconcile(
            withFullSnapshot: [resolved],
            policy: policy,
            now: 2
        )
        try expect(
            resolutions.count == 1 &&
                resolutions[0].windowID == 10 &&
                resolutions[0].section == .hidden,
            "Source resolution must apply the exact window's requested section"
        )
        pending.finish(windowID: 10)
        try expect(pending.isEmpty, "Applied native-drag intent must be removed")

        cache.sources = [:]
        let unresolvedBeforeReplacement = MenuBarItem(
            itemWindow: WindowInfo(12, title: "Item-0", ownerPID: 10)
        )!
        pending.record(
            postDragItem: unresolvedBeforeReplacement,
            section: .hidden,
            now: 5
        )
        cache.sources[12] = 200
        let immediatelyResolvedReplacement = MenuBarItem(
            itemWindow: WindowInfo(12, title: "Item-0", ownerPID: 10)
        )!
        _ = policy.update(
            fromFullSnapshot: [immediatelyResolvedReplacement]
        )
        let replacementResolution = pending.reconcile(
            withFullSnapshot: [immediatelyResolvedReplacement],
            policy: policy,
            now: 6
        )
        try expect(
            replacementResolution.isEmpty && pending.isEmpty,
            "A source appearing before continuity is observed must not inherit an intent"
        )

        pending.record(postDragItem: resolved, section: .visible, now: 10)
        _ = pending.reconcile(
            withFullSnapshot: [MenuBarItem(
                itemWindow: WindowInfo(10, title: "Item-0", ownerPID: 11)
            )!],
            policy: policy,
            now: 11
        )
        try expect(pending.isEmpty, "A recycled window must discard pending intent")

        pending.record(postDragItem: resolved, section: .hidden, now: 20)
        _ = pending.reconcile(
            withFullSnapshot: [MenuBarItem(
                itemWindow: WindowInfo(20, title: "Item-0", ownerPID: 10)
            )!],
            policy: policy,
            now: 21
        )
        try expect(pending.isEmpty, "A sibling window must not inherit pending intent")

        pending.record(postDragItem: resolved, section: .hidden, now: 30)
        _ = pending.reconcile(
            withFullSnapshot: [],
            policy: policy,
            now: 31
        )
        let reappeared = pending.reconcile(
            withFullSnapshot: [resolved],
            policy: policy,
            now: 32
        )
        try expect(
            pending.isEmpty && reappeared.isEmpty,
            "An intent must not survive absence from an authoritative snapshot"
        )

        pending.record(postDragItem: resolved, section: .hidden, now: 40)
        _ = pending.reconcile(
            withFullSnapshot: [resolved],
            policy: policy,
            now: 40 + MenuBarItemPendingSectionIntents.expirationInterval
        )
        try expect(pending.isEmpty, "A native-drag intent must expire after 30 seconds")

        cache.sources = [:]
        let beforeDrag = MenuBarItem(
            itemWindow: WindowInfo(30, title: "Item-0", ownerPID: 10, x: 100)
        )!
        _ = policy.update(fromFullSnapshot: [beforeDrag])
        cache.sources[30] = 100
        let afterDrag = MenuBarItem(
            itemWindow: WindowInfo(30, title: "Item-0", ownerPID: 10, x: 300)
        )!
        pending.record(postDragItem: afterDrag, section: .hidden, now: 50)
        try expect(
            pending.contains(afterDrag, now: 51),
            "The post-drag item must be the continuity baseline and ignore minX"
        )
        cache.sources[30] = 200
        let transferredSource = MenuBarItem(
            itemWindow: WindowInfo(30, title: "Item-0", ownerPID: 10, x: 300)
        )!
        _ = policy.update(fromFullSnapshot: [transferredSource])
        let transferred = pending.reconcile(
            withFullSnapshot: [transferredSource],
            policy: policy,
            now: 51
        )
        try expect(
            transferred.isEmpty && pending.isEmpty,
            "A post-drag intent must not transfer to another resolved source"
        )

        cache.sources = [:]
        let generationOne = Date(timeIntervalSince1970: 10)
        let generationTwo = Date(timeIntervalSince1970: 11)
        NSRunningApplication.launchDates[10] = generationOne
        let originalGeneration = MenuBarItem(
            itemWindow: WindowInfo(40, title: "Item-0", ownerPID: 10)
        )!
        pending.record(
            postDragItem: originalGeneration,
            section: .hidden,
            now: 60
        )
        NSRunningApplication.launchDates[10] = generationTwo
        let reusedGeneration = MenuBarItem(
            itemWindow: WindowInfo(40, title: "Item-0", ownerPID: 10)
        )!
        _ = policy.update(fromFullSnapshot: [reusedGeneration])
        _ = pending.reconcile(
            withFullSnapshot: [reusedGeneration],
            policy: policy,
            now: 61
        )
        try expect(
            pending.isEmpty,
            "Owner process generation changes must reject same-ID reuse"
        )
        NSRunningApplication.launchDates[10] = generationOne

        let originalSize = MenuBarItem(
            itemWindow: WindowInfo(
                50,
                title: "Item-0",
                ownerPID: 10,
                width: 24
            )
        )!
        pending.record(postDragItem: originalSize, section: .hidden, now: 70)
        let reusedSize = MenuBarItem(
            itemWindow: WindowInfo(
                50,
                title: "Item-0",
                ownerPID: 10,
                y: 4,
                width: 32
            )
        )!
        _ = policy.update(fromFullSnapshot: [reusedSize])
        _ = pending.reconcile(
            withFullSnapshot: [reusedSize],
            policy: policy,
            now: 71
        )
        try expect(
            pending.isEmpty,
            "Stable size and lane changes must reject common same-ID reuse"
        )
    }

    private static func actionabilityAndRetryPolicy() throws {
        let cache = MenuBarItemSourcePIDCache.shared
        cache.sources = [:]
        let provisional = MenuBarItem(
            itemWindow: WindowInfo(10, title: "Item-0", ownerPID: 10)
        )!
        try expect(
            !provisional.isMovable && !provisional.canBeHidden,
            "A provisional placeholder must not appear actionable"
        )
        try expect(
            !MenuBarItemMoveRetryPolicy.shouldWake(
                item: provisional,
                failure: .noResponse,
                attemptsRemain: true
            ),
            "A provisional placeholder must never receive a wake-up click"
        )

        cache.sources[20] = 100
        let movable = MenuBarItem(itemWindow: WindowInfo(20))!
        try expect(
            !MenuBarItemMoveRetryPolicy.shouldWake(
                item: movable,
                failure: .terminal,
                attemptsRemain: true
            ),
            "Terminal move errors must not trigger wake-up clicks"
        )
        try expect(
            MenuBarItemMoveRetryPolicy.shouldWake(
                item: movable,
                failure: .noResponse,
                attemptsRemain: true
            ),
            "A live movable item may be woken after a retryable no-response"
        )
        try expect(
            !MenuBarItemMoveRetryPolicy.shouldWake(
                item: movable,
                failure: .noResponse,
                attemptsRemain: false
            ),
            "The final failed attempt must not trigger a wake-up click"
        )
    }

    private static func interfaceWindowSelection() throws {
        let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let regular = WindowInfo(1, ownerPID: 100, layer: 0)
        let popup = WindowInfo(2, ownerPID: 100, layer: popupLevel)
        let tallStatus = WindowInfo(
            3,
            ownerPID: 100,
            height: 80,
            layer: statusLevel
        )
        let hiddenPopup = WindowInfo(
            4,
            ownerPID: 100,
            layer: popupLevel,
            onScreen: false
        )
        try expect(
            !MenuBarItem.isInterfaceWindow(regular, ownedBy: [100]),
            "An ordinary same-process window is not an item interface"
        )
        try expect(
            MenuBarItem.firstInterfaceWindow(
                in: [regular, hiddenPopup, popup],
                ownedBy: [100]
            )?.windowID == popup.windowID,
            "A stale tracked candidate must fall back to a valid interface scan"
        )
        try expect(
            MenuBarItem.firstInterfaceWindow(
                in: [tallStatus],
                ownedBy: [100]
            )?.windowID == tallStatus.windowID,
            "A tall status-level panel remains an interface candidate"
        )
        try expect(
            MenuBarItem.firstInterfaceWindow(
                in: [popup],
                ownedBy: [200]
            ) == nil,
            "Interface candidates must belong to an expected process"
        )
        let newlyOpenedPopup = WindowInfo(
            5,
            ownerPID: 100,
            layer: popupLevel
        )
        try expect(
            MenuBarItem.firstInterfaceWindow(
                in: [popup, newlyOpenedPopup],
                ownedBy: [100],
                excluding: [popup.windowID]
            )?.windowID == newlyOpenedPopup.windowID,
            "Fallback scans must ignore interfaces visible before the item click"
        )
    }

    private static func controlItemTitleRecognition() throws {
        let legacyVisible = MenuBarItem(
            itemWindow: WindowInfo(81, title: "SItem")
        )!
        let legacyHidden = MenuBarItem(
            itemWindow: WindowInfo(82, title: "HItem")
        )!
        let legacyAlwaysHidden = MenuBarItem(
            itemWindow: WindowInfo(83, title: "AHItem")
        )!
        let currentHidden = MenuBarItem(
            itemWindow: WindowInfo(
                84,
                title: "FloeBar.ControlItem.Hidden"
            )
        )!
        try expect(
            legacyVisible.info == .iceIcon,
            "Visible control item must keep legacy title compatibility"
        )
        try expect(
            legacyHidden.info == .hiddenControlItem &&
                currentHidden.info == .hiddenControlItem,
            "Hidden control items must be recognized by legacy and current titles"
        )
        try expect(
            legacyAlwaysHidden.info == .alwaysHiddenControlItem,
            "Always-hidden control items must keep legacy title compatibility"
        )
    }

    private static func visibleControlItemLayoutBehavior() throws {
        let visibleControl = MenuBarItem(
            itemWindow: WindowInfo(
                85,
                title: "FloeBar.ControlItem.Visible"
            )
        )!
        try expect(
            visibleControl.isMovable && visibleControl.canBeHidden,
            "The visible control item must remain physically movable"
        )
        try expect(
            visibleControl.sectionIdentity == nil,
            "The visible control item must use status-item autosave, not app section persistence"
        )
    }

    private static func displayFiltering() throws {
        let bounds: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1000, height: 800),
            2: CGRect(x: 1000, y: 0, width: 1000, height: 800),
        ]
        let left = CGRect(x: 900, y: 0, width: 24, height: 24)
        let right = CGRect(x: 1900, y: 0, width: 32, height: 24)
        let hidden = CGRect(x: -5000, y: 0, width: 24, height: 24)
        func belongs(_ frame: CGRect, _ display: CGDirectDisplayID, visible: Bool = true,
                     spaces: Set<CGDirectDisplayID> = []) -> Bool {
            MenuBarItem.belongsToDisplay(frame: frame, isOnScreen: visible, display: display, bounds: bounds,
                                         isOnCurrentSpace: { spaces.contains($0) })
        }
        let leftWidth = [left, right].filter { belongs($0, 1) }.reduce(0) { $0 + $1.width }
        let rightWidth = [left, right].filter { belongs($0, 2) }.reduce(0) { $0 + $1.width }
        try expect(leftWidth == 24 && rightWidth == 32, "Split-shape widths must exclude the adjacent display's visible icons")
        try expect(!belongs(right, 1, visible: false, spaces: [1]), "Geometry must beat an offscreen flag or Space hint")
        try expect(!belongs(hidden, 1, visible: true, spaces: [1]), "Never use lanes for visible windows")
        try expect(!belongs(hidden, 1, visible: false, spaces: [1, 2]), "Shared lanes and shared Spaces are ambiguous")
        try expect(!belongs(hidden, 1, visible: false), "No display evidence means no lane guess")
        try expect(belongs(hidden, 2, visible: false, spaces: [2]), "Unique Space evidence disambiguates hidden lanes")
        let stacked: [CGDirectDisplayID: CGRect] = [
            1: bounds[1]!, 2: CGRect(x: 0, y: 800, width: 1000, height: 800),
        ]
        try expect(MenuBarItem.belongsToDisplay(frame: hidden, isOnScreen: false, display: 1, bounds: stacked,
                                                isOnCurrentSpace: { _ in false }), "A unique offscreen lane remains supported")

        let lowerScreen = CGRect(x: 0, y: -800, width: 1000, height: 800)
        let lowerVisibleFrame = CGRect(x: 0, y: -800, width: 1000, height: 776)
        try expect(
            NSScreen.isPointInMenuBar(
                CGPoint(x: 500, y: -12),
                screenFrame: lowerScreen,
                visibleFrame: lowerVisibleFrame
            ),
            "The lower display's own top strip must count as its menu bar"
        )
        try expect(
            !NSScreen.isPointInMenuBar(
                CGPoint(x: 500, y: 100),
                screenFrame: lowerScreen,
                visibleFrame: lowerVisibleFrame
            ),
            "A point on the display above must start timed rehide"
        )
    }

    private static func uniqueRestoration() throws {
        try withStore { store, defaults in
            MenuBarItemSourcePIDCache.shared.sources = [10: 100, 90: 100]
            let original = enumerate([10])[0]
            try store.remember(original.sectionIdentity!, in: .hidden)
            let reloaded = try Store(defaults: defaults)
            let recreated = sample(enumerate([90]))
            _ = try reloaded.observe(recreated, now: 0)
            try expect(try reloaded.observe(recreated, now: 1).restore?.section == .hidden,
                       "Never-ambiguous unique items retain cross-launch section restoration")
        }
    }
}
