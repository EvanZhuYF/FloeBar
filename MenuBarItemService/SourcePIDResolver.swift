//
//  SourcePIDResolver.swift
//  FloeBar
//

import AXSwift
import Cocoa
import OSLog

/// Resolves the process that created a menu bar item whose WindowServer owner
/// is Control Center on macOS 26.
final class SourcePIDResolver {
    static let shared = SourcePIDResolver()
    private static let scanBudget: Duration = .seconds(5)
    private static let maximumPositiveAge: TimeInterval = 5 * 60

    private struct WindowFingerprint: Equatable {
        let ownerPID: pid_t
        let title: String?
        let layer: Int
        let minY: Int
        let width: Int
        let height: Int

        init(_ window: MenuBarItemService.Window) {
            ownerPID = window.ownerPID
            title = window.title
            layer = window.layer
            minY = Self.units(window.minY)
            width = Self.units(window.width)
            height = Self.units(window.height)
        }

        fileprivate static func units(_ value: Double) -> Int {
            Int((value * 8).rounded())
        }
    }

    private struct PIDEntry {
        let sourcePID: pid_t
        let sourceLaunchDate: Date?
        let fingerprint: StableWindowFingerprint
        let resolvedAt: Date
    }

    /// Fields expected to remain stable for one WindowServer incarnation.
    private struct StableWindowFingerprint: Equatable {
        let ownerPID: pid_t
        let ownerLaunchDate: Date?
        let layer: Int
        let minY: Int
        let width: Int
        let height: Int
        let semanticTitle: String?

        init(_ window: MenuBarItemService.Window) {
            ownerPID = window.ownerPID
            ownerLaunchDate = NSRunningApplication(
                processIdentifier: window.ownerPID
            )?.launchDate
            layer = window.layer
            minY = WindowFingerprint.units(window.minY)
            width = WindowFingerprint.units(window.width)
            height = WindowFingerprint.units(window.height)
            semanticTitle = SourcePIDResolver.stableSemanticTitle(window.title)
        }
    }

    private struct NegativeEntry {
        let fingerprint: WindowFingerprint
        let retryAfter: Date
        let failures: Int
    }

    private final class CachedApplication {
        let application: NSRunningApplication
        var extrasMenuBar: UIElement?
        var misses = 0
        var retryAfter: Date?

        var pid: pid_t {
            application.processIdentifier
        }

        var launchDate: Date? {
            application.launchDate
        }

        var bundleIdentifier: String? {
            application.bundleIdentifier
        }

        init(application: NSRunningApplication) {
            self.application = application
        }

        func menuBar() -> UIElement? {
            if let extrasMenuBar {
                return extrasMenuBar
            }
            if let retryAfter, retryAfter > .now {
                return nil
            }
            guard application.isFinishedLaunching, !application.isTerminated else {
                return nil
            }
            guard
                let axApplication = Application(application),
                let bar: UIElement = try? axApplication.attribute(.extrasMenuBar)
            else {
                misses += 1
                retryAfter = Date.now.addingTimeInterval(Self.retryDelay(after: misses))
                return nil
            }
            extrasMenuBar = bar
            misses = 0
            retryAfter = nil
            return bar
        }

        private static func retryDelay(after misses: Int) -> TimeInterval {
            switch misses {
            case 0...1: 2
            case 2: 10
            case 3: 30
            default: 120
            }
        }
    }

    private let logger = os.Logger(
        subsystem: "com.evanzhu.FloeBar",
        category: "SourcePIDResolver"
    )

    private var pidEntries = [CGWindowID: PIDEntry]()
    private var negativeEntries = [CGWindowID: NegativeEntry]()
    private var applications = [pid_t: CachedApplication]()

    private init() {}

    func resolve(_ requestedWindows: [MenuBarItemService.Window]) -> [pid_t?] {
        let requestedWindows = Array(
            requestedWindows.prefix(MenuBarItemService.maximumWindowCount)
        )
        guard !requestedWindows.isEmpty else {
            return []
        }
        let windows = Self.liveMenuBarWindows(
            for: requestedWindows.map(\.windowID)
        )
        guard !windows.isEmpty else {
            return Array(repeating: nil, count: requestedWindows.count)
        }

        refreshApplications()
        pruneState(for: windows)

        let now = Date.now
        if windows.contains(where: { needsScan($0, now: now) }) {
            scan(windows)
        }

        let liveWindowsByID = Dictionary(
            windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return requestedWindows.map { requestedWindow in
            guard
                let liveWindow = liveWindowsByID[requestedWindow.windowID],
                StableWindowFingerprint(requestedWindow) ==
                    StableWindowFingerprint(liveWindow)
            else {
                return nil
            }
            return pidEntries[requestedWindow.windowID]?.sourcePID
        }
    }

    private func refreshApplications() {
        let running = NSWorkspace.shared.runningApplications
        let livePIDs = Set(running.map(\.processIdentifier))
        applications = applications.filter { livePIDs.contains($0.key) }

        for application in running where applications[application.processIdentifier] == nil {
            applications[application.processIdentifier] = CachedApplication(application: application)
        }
        for application in running {
            let pid = application.processIdentifier
            if applications[pid]?.launchDate != application.launchDate {
                applications[pid] = CachedApplication(application: application)
            }
        }

        pidEntries = pidEntries.filter { _, entry in
            guard kill(entry.sourcePID, 0) == 0 || errno != ESRCH else {
                return false
            }
            return NSRunningApplication(processIdentifier: entry.sourcePID)?.launchDate ==
                entry.sourceLaunchDate
        }
    }

    private func pruneState(for windows: [MenuBarItemService.Window]) {
        let windowsByID = Dictionary(
            windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = Date.now
        pidEntries = pidEntries.filter { windowID, entry in
            guard let window = windowsByID[windowID] else {
                return false
            }
            return entry.fingerprint == StableWindowFingerprint(window) &&
                now.timeIntervalSince(entry.resolvedAt) <=
                    Self.maximumPositiveAge
        }
        negativeEntries = negativeEntries.filter { windowID, entry in
            guard let window = windowsByID[windowID] else {
                return false
            }
            return entry.fingerprint == WindowFingerprint(window)
        }
    }

    private func needsScan(_ window: MenuBarItemService.Window, now: Date) -> Bool {
        guard window.layer == kCGStatusWindowLevel, window.width > 0, window.height > 0 else {
            return false
        }
        guard pidEntries[window.windowID] == nil else {
            return false
        }
        return negativeEntries[window.windowID]?.retryAfter ?? .distantPast <= now
    }

    private func scan(_ windows: [MenuBarItemService.Window]) {
        let started = ContinuousClock.now
        let deadline = started + Self.scanBudget
        let controlCenterBundleID = "com.apple.controlcenter"
        let floeBarBundlePrefix = "com.evanzhu.FloeBar"
        let statusWindows = windows.filter {
            $0.layer == kCGStatusWindowLevel && $0.width > 0 && $0.height > 0
        }
        var unresolved = Set(
            statusWindows.lazy
                .filter { self.pidEntries[$0.windowID] == nil }
                .map(\.windowID)
        )
        guard !unresolved.isEmpty else {
            return
        }

        let apps = applications.values.sorted {
            if ($0.extrasMenuBar != nil) != ($1.extrasMenuBar != nil) {
                return $0.extrasMenuBar != nil
            }
            return $0.pid < $1.pid
        }
        let appsByBundleID = Dictionary(
            grouping: apps.compactMap { app in
                app.bundleIdentifier.map { ($0.lowercased(), app) }
            },
            by: \.0
        ).mapValues { $0.map(\.1) }

        // A complete reverse-DNS title is direct ownership evidence and is
        // cheaper and more reliable than geometry matching.
        for window in statusWindows where unresolved.contains(window.windowID) {
            guard
                let title = window.title?.lowercased(),
                let matchingApps = appsByBundleID[title],
                matchingApps.count == 1,
                let app = matchingApps.first,
                app.bundleIdentifier != controlCenterBundleID,
                app.bundleIdentifier?.hasPrefix(floeBarBundlePrefix) != true
            else {
                continue
            }
            setPID(app.pid, for: window)
            unresolved.remove(window.windowID)
        }

        var framesByPID = [pid_t: [CGRect]]()
        var exactCandidates = [CGWindowID: Set<pid_t>]()
        var exhaustedBudget = false
        for app in apps where !unresolved.isEmpty {
            guard ContinuousClock.now < deadline else {
                exhaustedBudget = true
                break
            }
            autoreleasepool {
                guard let menuBar = app.menuBar() else {
                    return
                }
                guard ContinuousClock.now < deadline else {
                    exhaustedBudget = true
                    return
                }
                guard let children: [UIElement] = try? menuBar.arrayAttribute(.children) else {
                    // AX objects can be replaced without the process exiting.
                    app.extrasMenuBar = nil
                    app.retryAfter = .now.addingTimeInterval(10)
                    return
                }
                var childFrames = [CGRect]()
                for child in children {
                    guard ContinuousClock.now < deadline else {
                        exhaustedBudget = true
                        break
                    }
                    let enabled: Bool? = try? child.attribute(.enabled)
                    guard enabled != false else {
                        continue
                    }
                    guard ContinuousClock.now < deadline else {
                        exhaustedBudget = true
                        break
                    }
                    guard let frame: CGRect = try? child.attribute(.frame) else {
                        continue
                    }
                    childFrames.append(frame)
                    for window in statusWindows where unresolved.contains(window.windowID) {
                        if app.bundleIdentifier == controlCenterBundleID,
                           Self.isGenericControlCenterTitle(window.title)
                        {
                            continue
                        }
                        if Self.distance(window.frame.center, frame.center) <= 1 {
                            exactCandidates[window.windowID, default: []].insert(app.pid)
                        }
                    }
                }
                if !childFrames.isEmpty {
                    framesByPID[app.pid] = childFrames
                }
            }
        }

        for window in statusWindows where unresolved.contains(window.windowID) {
            guard
                let candidates = exactCandidates[window.windowID],
                candidates.count == 1,
                let pid = candidates.first
            else {
                continue
            }
            setPID(pid, for: window)
            unresolved.remove(window.windowID)
        }

        // Some Control Center hosting slots are wider than the source app's
        // AX child. Permit a wider spatial radius only when the window title
        // independently identifies the same application.
        for window in statusWindows where unresolved.contains(window.windowID) {
            guard let title = window.title else {
                continue
            }
            let matchingApps = apps.filter {
                guard
                    let bundleID = $0.bundleIdentifier,
                    bundleID != controlCenterBundleID,
                    !bundleID.hasPrefix(floeBarBundlePrefix)
                else {
                    return false
                }
                return Self.title(title, indicatesOwner: bundleID)
            }
            let candidates = matchingApps.filter { app in
                framesByPID[app.pid]?.contains {
                    Self.distance(window.frame.center, $0.center) <= 20
                } == true
            }
            guard candidates.count == 1, let app = candidates.first else {
                continue
            }
            setPID(app.pid, for: window)
            unresolved.remove(window.windowID)
        }

        resolveMarkerPairs(
            windows: statusWindows,
            unresolved: &unresolved,
            applicationsByBundleID: appsByBundleID,
            controlCenterBundleID: controlCenterBundleID,
            floeBarBundlePrefix: floeBarBundlePrefix
        )

        let now = Date.now
        for window in statusWindows {
            if pidEntries[window.windowID] != nil {
                negativeEntries.removeValue(forKey: window.windowID)
                continue
            }
            guard unresolved.contains(window.windowID) else {
                continue
            }
            let previousFailures = negativeEntries[window.windowID]?.failures ?? 0
            let failures = previousFailures + 1
            negativeEntries[window.windowID] = NegativeEntry(
                fingerprint: WindowFingerprint(window),
                retryAfter: now.addingTimeInterval(Self.retryDelay(after: failures)),
                failures: failures
            )
        }

        let resolvedCount = statusWindows.count - unresolved.count
        if exhaustedBudget {
            logger.warning(
                "Stopped source PID AX scan at the \(String(describing: Self.scanBudget), privacy: .public) budget"
            )
        }
        logger.debug(
            "Resolved \(resolvedCount, privacy: .public)/\(statusWindows.count, privacy: .public) menu bar source PIDs in \(String(describing: ContinuousClock.now - started), privacy: .public)"
        )
    }

    private func resolveMarkerPairs(
        windows: [MenuBarItemService.Window],
        unresolved: inout Set<CGWindowID>,
        applicationsByBundleID: [String: [CachedApplication]],
        controlCenterBundleID: String,
        floeBarBundlePrefix: String
    ) {
        let markers = windows.filter {
            guard let title = $0.title else {
                return false
            }
            return Self.looksLikeBundleIdentifier(title) &&
                !title.hasPrefix(floeBarBundlePrefix)
        }
        let icons = windows.filter {
            unresolved.contains($0.windowID) &&
                !Self.looksLikeBundleIdentifier($0.title ?? "")
        }

        var iconsByWidth = [Int: [MenuBarItemService.Window]]()
        var markersByWidth = [Int: [MenuBarItemService.Window]]()
        for icon in icons {
            iconsByWidth[WindowFingerprint.units(icon.width), default: []].append(icon)
        }
        for marker in markers {
            markersByWidth[WindowFingerprint.units(marker.width), default: []].append(marker)
        }

        for (width, candidates) in iconsByWidth where candidates.count == 1 {
            guard
                let icon = candidates.first,
                let matchingMarkers = markersByWidth[width],
                matchingMarkers.count == 1,
                let marker = matchingMarkers.first,
                marker.windowID != icon.windowID
            else {
                continue
            }
            let app: CachedApplication? = {
                if
                    let owner = applications[marker.ownerPID],
                    let bundleID = owner.bundleIdentifier,
                    bundleID != controlCenterBundleID,
                    !bundleID.hasPrefix(floeBarBundlePrefix)
                {
                    return owner
                }
                guard
                    let markerTitle = marker.title?.lowercased(),
                    let matchingApps = applicationsByBundleID[markerTitle],
                    matchingApps.count == 1,
                    let matchingApp = matchingApps.first,
                    matchingApp.bundleIdentifier != controlCenterBundleID,
                    matchingApp.bundleIdentifier?.hasPrefix(floeBarBundlePrefix) != true
                else {
                    return nil
                }
                return matchingApp
            }()
            guard let app else {
                continue
            }
            setPID(app.pid, for: icon)
            unresolved.remove(icon.windowID)
        }
    }

    private func setPID(_ pid: pid_t, for window: MenuBarItemService.Window) {
        pidEntries[window.windowID] = PIDEntry(
            sourcePID: pid,
            sourceLaunchDate: NSRunningApplication(
                processIdentifier: pid
            )?.launchDate,
            fingerprint: StableWindowFingerprint(window),
            resolvedAt: .now
        )
    }

    private static func retryDelay(after failures: Int) -> TimeInterval {
        switch failures {
        case 0...1: 1
        case 2: 3
        case 3: 10
        default: 60
        }
    }

    private static func isGenericControlCenterTitle(_ title: String?) -> Bool {
        guard let title, title.hasPrefix("Item-") else {
            return false
        }
        let suffix = title.dropFirst("Item-".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private static func stableSemanticTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty else {
            return nil
        }
        if isGenericControlCenterTitle(title) {
            return title
        }
        guard looksLikeBundleIdentifier(title) else {
            return nil
        }
        return title.lowercased()
    }

    private static func looksLikeBundleIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy { !$0.isEmpty }
    }

    private static func title(_ title: String, indicatesOwner bundleIdentifier: String) -> Bool {
        let titleComponents = title.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        let bundleComponents = bundleIdentifier.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard bundleComponents.count >= 2,
              titleComponents.allSatisfy({ !$0.isEmpty }),
              bundleComponents.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        if titleComponents.count == 1 {
            return titleComponents.first == bundleComponents.last
        }
        guard titleComponents.count >= 3 else {
            return false
        }
        var commonCount = 0
        for (titleComponent, bundleComponent) in zip(titleComponents, bundleComponents) {
            guard titleComponent == bundleComponent else {
                break
            }
            commonCount += 1
        }
        guard commonCount >= 2 else {
            return false
        }
        if commonCount == min(titleComponents.count, bundleComponents.count) {
            return true
        }
        return titleComponents[commonCount].hasPrefix(bundleComponents[commonCount]) ||
            bundleComponents[commonCount].hasPrefix(titleComponents[commonCount])
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private static func liveMenuBarWindows(
        for windowIDs: [CGWindowID]
    ) -> [MenuBarItemService.Window] {
        let descriptions = WindowDescriptionQuery.descriptions(for: windowIDs)
        return descriptions.compactMap { info in
            guard
                let info = info as? [CFString: Any],
                let windowID = info[kCGWindowNumber] as? CGWindowID,
                let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDictionary),
                let layer = info[kCGWindowLayer] as? Int,
                layer == kCGStatusWindowLevel
            else {
                return nil
            }
            return MenuBarItemService.Window(
                windowID: windowID,
                ownerPID: ownerPID,
                minX: frame.minX,
                minY: frame.minY,
                width: frame.width,
                height: frame.height,
                layer: layer,
                title: info[kCGWindowName] as? String,
                ownerName: info[kCGWindowOwnerName] as? String,
                isOnScreen: info[kCGWindowIsOnscreen] as? Bool ?? false
            )
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
