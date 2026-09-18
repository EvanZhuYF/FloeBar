import CoreGraphics
import Foundation

private func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw NSError(
            domain: "MenuBarItemSourcePIDResolverTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@main
private enum MenuBarItemSourcePIDResolverTests {
    static func main() throws {
        try fixedPointAt257()
        try unresolvedRotation()
        try semanticTitleFingerprint()
        try positiveCacheReconciliation()
        print("PASS: menu bar source PID request policy")
    }

    private static func fixedPointAt257() throws {
        var state = MenuBarItemSourcePIDRequestPolicy.State()
        let selected = MenuBarItemSourcePIDRequestPolicy.selectWindowIDs(
            unresolvedRequired: [257],
            supporting: [],
            maximumCount: MenuBarItemService.maximumWindowCount,
            state: &state
        )
        try check(
            selected == [257],
            "Cached windows must not displace the unresolved 257th window"
        )
        try check(
            selected.first == 257,
            "The unresolved 257th window must displace a cached window"
        )
        let remaining =
            MenuBarItemSourcePIDRequestPolicy.remainingUnresolvedWindowIDs(
                required: Set((1 ... 257).map(CGWindowID.init)),
                resolved: Set((1 ... 256).map(CGWindowID.init))
            )
        try check(
            remaining == [257],
            "Retry state must be computed from all 257 required windows"
        )
    }

    private static func unresolvedRotation() throws {
        var state = MenuBarItemSourcePIDRequestPolicy.State()
        let unresolved = (1 ... 257).map(CGWindowID.init)
        let supporting = (1_001 ... 1_064).map(CGWindowID.init)
        let first = MenuBarItemSourcePIDRequestPolicy.selectWindowIDs(
            unresolvedRequired: unresolved,
            supporting: supporting,
            maximumCount: MenuBarItemService.maximumWindowCount,
            state: &state
        )
        let second = MenuBarItemSourcePIDRequestPolicy.selectWindowIDs(
            unresolvedRequired: unresolved,
            supporting: supporting,
            maximumCount: MenuBarItemService.maximumWindowCount,
            state: &state
        )
        try check(
            first.count == 256 && second.count == 256,
            "Each rotated source request must remain bounded"
        )
        try check(
            Set(first).isSuperset(of: supporting) &&
                Set(second).isSuperset(of: supporting),
            "Each request must retain the support window budget"
        )
        let coveredRequired = Set(first + second).intersection(unresolved)
        try check(
            coveredRequired == Set(unresolved),
            "Repeated unresolved requests must rotate across all 257 windows"
        )
    }

    private static func semanticTitleFingerprint() throws {
        try check(
            MenuBarItemSourcePIDRequestPolicy.stableSemanticTitle("Item-0") ==
                "Item-0",
            "Generic Control Center slots must contribute to the fingerprint"
        )
        try check(
            MenuBarItemSourcePIDRequestPolicy.stableSemanticTitle(
                "COM.Example.Widget"
            ) == "com.example.widget",
            "Bundle-shaped titles must have a stable normalized fingerprint"
        )
        try check(
            MenuBarItemSourcePIDRequestPolicy.stableSemanticTitle("12:34") ==
                nil,
            "Dynamic titles must not invalidate positive entries continuously"
        )
    }

    private static func positiveCacheReconciliation() throws {
        let cache = MenuBarItemSourcePIDCache.shared
        _ = cache.reconcile(withFullSnapshot: [])
        let processID = ProcessInfo.processInfo.processIdentifier
        let original = WindowInfo(
            windowID: 700,
            frame: CGRect(x: 100, y: 0, width: 24, height: 24),
            title: "Item-0",
            layer: Int(kCGStatusWindowLevel),
            ownerPID: processID,
            ownerName: "Fixture",
            isOnScreen: true
        )
        try check(
            cache.merge(
                liveWindows: [original],
                resolvedWindows: [original],
                sourcePIDs: [processID]
            ),
            "The fixture must seed a positive source PID entry"
        )
        try check(
            cache.reconcile(withFullSnapshot: []),
            "An authoritative snapshot must prune a disappeared window"
        )
        try check(
            !cache.reconcile(withFullSnapshot: []),
            "A previously pruned window must stay absent"
        )

        _ = cache.merge(
            liveWindows: [original],
            resolvedWindows: [original],
            sourcePIDs: [processID]
        )
        let reused = WindowInfo(
            windowID: original.windowID,
            frame: original.frame,
            title: "Item-1",
            layer: original.layer,
            ownerPID: original.ownerPID,
            ownerName: original.ownerName,
            isOnScreen: original.isOnScreen
        )
        try check(
            cache.reconcile(withFullSnapshot: [reused]),
            "A semantic fingerprint change must prune a reused window ID"
        )

        let dynamic = WindowInfo(
            windowID: 701,
            frame: CGRect(x: 100, y: 0, width: 24, height: 24),
            title: "12:34",
            layer: Int(kCGStatusWindowLevel),
            ownerPID: processID,
            ownerName: "Fixture",
            isOnScreen: true
        )
        _ = cache.merge(
            liveWindows: [dynamic],
            resolvedWindows: [dynamic],
            sourcePIDs: [processID]
        )
        let updatedDynamic = WindowInfo(
            windowID: dynamic.windowID,
            frame: CGRect(x: 100, y: 0, width: 40, height: 24),
            title: "12:35",
            layer: dynamic.layer,
            ownerPID: dynamic.ownerPID,
            ownerName: dynamic.ownerName,
            isOnScreen: dynamic.isOnScreen
        )
        try check(
            cache.reconcile(withFullSnapshot: [updatedDynamic]),
            "A width change must conservatively invalidate a potentially reused window ID"
        )
        _ = cache.reconcile(withFullSnapshot: [])
    }
}
