import Foundation

private typealias Store = MenuBarItemSectionStore

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "SectionPersistenceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func item(
    _ name: String = "Icon",
    window: UInt32 = 1,
    pid: Int32 = 100,
    section: Store.Section = .hidden,
    bundle: String = "test.application",
    instance: Int = 0
) -> Store.Item {
    .init(
        identity: .init(
            bundleIdentifier: bundle,
            title: name,
            instanceIndex: instance
        ),
        windowID: window,
        processID: pid,
        section: section
    )
}

private func withStore(_ body: (Store, UserDefaults) throws -> Void) throws {
    let name = "Ice.SectionPersistenceTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        fatalError("Could not create isolated test defaults")
    }
    defer { defaults.removePersistentDomain(forName: name) }
    try body(Store(defaults: defaults), defaults)
}

@main
private enum SectionPersistenceTests {
    static func main() throws {
        try bootstrapAndRelaunch()
        try rememberUserMoves()
        try retryBudget()
        try protectTemporaryAndDisabledSections()
        try ambiguousIdentities()
        try retainClosedApplications()
        try rejectCorruptDocuments()
        try settlingAndSingleStepRestore()
        try noGuessingAcrossTitles()
        try boundedAutomaticLearning()
        try rejectAmbiguousOrdinalPersistence()
        try decodeLegacyIdentity()
        print("PASS: 12 section persistence test groups")
    }

    private static func bootstrapAndRelaunch() throws {
        try withStore { store, defaults in
            let original = item("Icon:with:colons")
            let first = try store.observe([original], now: 0)
            try check(!first.isSettled, "Must wait for stable layout")
            try check(store.section(for: original.identity) == nil, "Must not save a transient snapshot")
            let stable = try store.observe([original], now: 1)
            try check(stable.restore == nil, "Initial layout must not move")
            let restoredStore = try Store(defaults: defaults)
            try check(restoredStore.section(for: original.identity) == .hidden, "Settings must survive relaunch")
            let drifted = item("Icon:with:colons", window: 2, section: .alwaysHidden)
            _ = try restoredStore.observe([drifted], now: 2)
            let result = try restoredStore.observe([drifted], now: 3)
            try check(result.restore?.section == .hidden, "Restore saved section after app relaunch")
            try check(restoredStore.section(for: drifted.identity) == .hidden, "Drift must not overwrite intent")
        }
    }

    private static func rememberUserMoves() throws {
        try withStore { store, _ in
            let original = item()
            try store.remember(original.identity, in: .alwaysHidden)
            try check(store.section(for: original.identity) == .alwaysHidden, "Layout drop should save immediately")
            let moved = item(section: .visible)
            _ = try store.observe([moved], now: 0, userChangedIdentities: [moved.identity])
            let result = try store.observe([moved], now: 1, userChangedIdentities: [moved.identity])
            try check(result.restore == nil, "Must not undo Cmd-drag")
            try check(store.section(for: moved.identity) == .visible, "Cmd-drag should update saved section")
            let boundaryMove = item(section: .hidden)
            _ = try store.observe([boundaryMove], now: 2, acceptAllChanges: true)
            let boundaryResult = try store.observe([boundaryMove], now: 3, acceptAllChanges: true)
            try check(boundaryResult.restore == nil, "Must respect separator drag")
            try check(store.section(for: moved.identity) == .hidden, "Separator drag must save new boundaries")
        }
    }

    private static func retryBudget() throws {
        try withStore { store, _ in
            let drifted = item(section: .visible)
            try store.remember(drifted.identity, in: .hidden)
            _ = try store.observe([drifted], now: 0)
            try check(tryRestore(store, drifted, at: 1) != nil, "First attempt")
            try check(tryRestore(store, drifted, at: 2) == nil, "Back off after first attempt")
            try check(tryRestore(store, drifted, at: 6) != nil, "Second attempt")
            try check(tryRestore(store, drifted, at: 7) == nil, "Back off after second attempt")
            try check(tryRestore(store, drifted, at: 21) != nil, "Third attempt")
            try check(tryRestore(store, drifted, at: 100) == nil, "Must stop after three attempts")
            let relaunched = item(window: 2, pid: 200, section: .visible)
            _ = try store.observe([relaunched], now: 101)
            try check(tryRestore(store, relaunched, at: 102) != nil, "New window gets a new retry budget")
            try check(store.section(for: drifted.identity) == .hidden, "Failures must not delete saved intent")
        }
    }

    private static func tryRestore(_ store: Store, _ value: Store.Item, at time: TimeInterval) -> Store.Restore? {
        // Test-only convenience; an encoding error must fail the entire test run.
        do {
            return try store.observe([value], now: time).restore
        } catch {
            fatalError("Unexpected persistence error: \(error)")
        }
    }

    private static func protectTemporaryAndDisabledSections() throws {
        try withStore { store, _ in
            let shown = item(section: .visible)
            try store.remember(shown.identity, in: .alwaysHidden)
            _ = try store.observe([shown], now: 0, excludedWindowIDs: [1])
            let temporary = try store.observe([shown], now: 1, excludedWindowIDs: [1])
            try check(temporary.restore == nil, "Do not restore an actively shown item")
            try check(store.section(for: shown.identity) == .alwaysHidden, "Do not save temporary visible position")
            let disabled = try store.observe([shown], now: 2, alwaysHiddenEnabled: false)
            try check(disabled.restore == nil, "Disabled always-hidden section must not cause movement")
            let busy = try store.observe([shown], now: 3, allowRestore: false)
            try check(busy.restore == nil, "Busy input must defer movement")
            let enabled = try store.observe([shown], now: 4)
            try check(enabled.restore?.section == .alwaysHidden, "Re-enabling should restore original section")
        }
    }

    private static func ambiguousIdentities() throws {
        try withStore { store, _ in
            let a = item()
            let b = item(window: 2, section: .visible)
            _ = try store.observe([a, b], now: 0)
            _ = try store.observe([a, b], now: 1)
            try check(store.section(for: a.identity) == nil, "Must not learn ambiguous identical titles")
            try store.remember(a.identity, in: .alwaysHidden)
            _ = try store.observe([a, b], now: 2)
            let duplicate = try store.observe([a, b], now: 3)
            try check(duplicate.restore == nil, "Must not restore ambiguous identical titles")
            let distinct = item("Other", window: 2, section: .visible)
            _ = try store.observe([a, distinct], now: 4)
            _ = try store.observe([a, distinct], now: 5)
            try check(store.section(for: distinct.identity) == .visible, "Different titles must remain independent")
        }
    }

    private static func retainClosedApplications() throws {
        try withStore { store, defaults in
            let closed = item()
            try store.remember(closed.identity, in: .hidden)
            _ = try store.observe([], now: 0)
            _ = try store.observe([], now: 1)
            let later = item(window: 20, section: .alwaysHidden)
            _ = try store.observe([later], now: 2)
            let result = try store.observe([later], now: 3)
            try check(result.restore?.section == .hidden, "Separate exit and launch scans must still restore")
            let loaded = try Store(defaults: defaults)
            try check(loaded.section(for: closed.identity) == .hidden, "Closed app must not be forgotten")
            let emptyIdentity = Store.Identity(bundleIdentifier: "", title: "Unknown")
            try store.remember(emptyIdentity, in: .hidden)
            try check(store.section(for: emptyIdentity) == nil, "Do not persist missing bundle IDs")
        }
    }

    private static func rejectCorruptDocuments() throws {
        try withStore { _, defaults in
            for contents in [
                "not-json",
                #"{"version":2,"records":[]}"#,
                #"{"version":1,"records":[{"identity":{"bundleIdentifier":"app","title":"x"},"section":"bogus"}]}"#,
            ] {
                let bytes = Data(contents.utf8)
                defaults.set(bytes, forKey: Store.defaultsKey)
                var rejected = false
                do { _ = try Store(defaults: defaults) } catch { rejected = true }
                try check(rejected, "Corrupt and future documents should fail closed")
                try check(defaults.data(forKey: Store.defaultsKey) == bytes, "Never overwrite unrecognized data")
            }
        }
    }

    private static func settlingAndSingleStepRestore() throws {
        try withStore { store, _ in
            let a = item(section: .visible)
            let b = item("Second", window: 2, section: .visible)
            try store.remember(a.identity, in: .hidden)
            try store.remember(b.identity, in: .alwaysHidden)
            _ = try store.observe([a], now: 0)
            let changed = try store.observe([a, b], now: 1)
            try check(!changed.isSettled, "New windows must restart settling")
            let stillSettling = try store.observe([a, b], now: 1.5)
            try check(stillSettling.restore == nil, "Do not move during settling")
            let first = try store.observe([a, b], now: 2)
            try check(first.restore?.item.windowID == 1, "Only one item is restored per observation")
            let correctedA = item(section: .hidden)
            _ = try store.observe([correctedA, b], now: 3)
            let second = try store.observe([correctedA, b], now: 4)
            try check(second.restore?.item.windowID == 2, "Re-sample before restoring the next item")
            store.invalidateSnapshot()
            let invalidated = try store.observe([correctedA, b], now: 50)
            try check(!invalidated.isSettled, "Screen/wake invalidation must force a new stable sample")
        }
    }

    private static func noGuessingAcrossTitles() throws {
        try withStore { store, _ in
            let old = item("Old title")
            try store.remember(old.identity, in: .alwaysHidden)
            let new = item("New title", window: 2, section: .visible)
            _ = try store.observe([new], now: 0)
            let result = try store.observe([new], now: 1)
            try check(result.restore == nil, "Do not hide an unrelated new icon just because the bundle matches")
            try check(store.section(for: old.identity) == .alwaysHidden, "Keep the old icon's record")
        }
    }

    private static func boundedAutomaticLearning() throws {
        try withStore { store, _ in
            let values = (0..<300).map {
                item("Dynamic \($0)", window: UInt32($0 + 1))
            }
            _ = try store.observe(values, now: 0)
            _ = try store.observe(values, now: 1)
            try check(
                store.savedItemCount == Store.maxAutomaticallyLearnedItems,
                "Automatic title learning must be bounded"
            )
            let explicit = Store.Identity(bundleIdentifier: "manual.application", title: "Manual")
            try store.remember(explicit, in: .alwaysHidden)
            try check(store.section(for: explicit) == .alwaysHidden, "Explicit choices must still be saved")
        }
    }

    private static func rejectAmbiguousOrdinalPersistence() throws {
        try withStore { store, defaults in
            let first = item(instance: 0)
            let second = item(window: 2, section: .visible, instance: 1)
            _ = try store.observe([first, second], now: 0)
            _ = try store.observe([first, second], now: 1, acceptAllChanges: true)
            try store.remember(first.identity, in: .hidden)
            try store.remember(second.identity, in: .visible)
            try check(store.savedItemCount == 0, "Neither learning nor explicit moves may persist ambiguous ordinals")
            try check(store.section(for: first.identity) == nil, "Index zero must not identify a duplicate")
            try check(store.section(for: second.identity) == nil, "Index one must not identify a duplicate")
            let reloaded = try Store(defaults: defaults)
            _ = try reloaded.observe([first], now: 2)
            let result = try reloaded.observe([first], now: 3)
            try check(result.restore == nil && reloaded.savedItemCount == 0, "Confirmed ambiguity must survive relaunch")
        }
    }

    private static func decodeLegacyIdentity() throws {
        let name = "Ice.SectionPersistenceTests.Legacy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("Could not create isolated test defaults")
        }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(
            Data(
                #"{"version":1,"records":[{"identity":{"bundleIdentifier":"legacy.app","title":"Icon"},"section":"hidden"}]}"#.utf8
            ),
            forKey: Store.defaultsKey
        )
        let store = try Store(defaults: defaults)
        let identity = Store.Identity(bundleIdentifier: "legacy.app", title: "Icon")
        try check(store.section(for: identity) == .hidden, "Legacy identities must decode as instance zero")
    }
}
