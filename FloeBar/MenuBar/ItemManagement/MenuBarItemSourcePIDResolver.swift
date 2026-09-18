//
//  MenuBarItemSourcePIDResolver.swift
//  FloeBar
//

import Cocoa
import os.lock

private extension MenuBarItemService.Window {
    init(_ window: WindowInfo) {
        self.init(
            windowID: window.windowID,
            ownerPID: window.ownerPID,
            minX: window.frame.minX,
            minY: window.frame.minY,
            width: window.frame.width,
            height: window.frame.height,
            layer: window.layer,
            title: window.title,
            ownerName: window.ownerName,
            isOnScreen: window.isOnScreen
        )
    }
}

enum MenuBarItemSourcePIDRequestPolicy {
    struct State {
        var unresolvedOffset = 0
        var supportingOffset = 0
    }

    static func selectWindowIDs(
        unresolvedRequired: [CGWindowID],
        supporting: [CGWindowID],
        maximumCount: Int,
        state: inout State
    ) -> [CGWindowID] {
        guard maximumCount > 0 else {
            return []
        }

        let supportCount = min(supporting.count, maximumCount / 4)
        let unresolvedCount = min(
            unresolvedRequired.count,
            maximumCount - supportCount
        )
        var result = rotatingPrefix(
            unresolvedRequired,
            count: unresolvedCount,
            offset: &state.unresolvedOffset
        )
        result += rotatingPrefix(
            supporting,
            count: min(supportCount, maximumCount - result.count),
            offset: &state.supportingOffset
        )
        return result
    }

    static func stableSemanticTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty else {
            return nil
        }
        if title.hasPrefix("Item-") {
            let suffix = title.dropFirst("Item-".count)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                return title
            }
        }
        guard isBundleShapedTitle(title) else {
            return nil
        }
        return title.lowercased()
    }

    static func isBundleShapedTitle(_ title: String?) -> Bool {
        guard let title else {
            return false
        }
        let components = title.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return components.count >= 2 &&
            components.allSatisfy { !$0.isEmpty }
    }

    static func remainingUnresolvedWindowIDs(
        required: Set<CGWindowID>,
        resolved: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        required.subtracting(resolved)
    }

    private static func rotatingPrefix(
        _ values: [CGWindowID],
        count: Int,
        offset: inout Int
    ) -> [CGWindowID] {
        guard !values.isEmpty, count > 0 else {
            offset = 0
            return []
        }
        let start = offset % values.count
        let result = (0 ..< min(count, values.count)).map {
            values[(start + $0) % values.count]
        }
        offset = (start + result.count) % values.count
        return result
    }
}

/// Thread-safe source PID values used by synchronous menu bar enumeration.
///
/// The XPC request is asynchronous, but most existing FloeBar call sites are
/// intentionally synchronous. They read the most recent confirmed value here.
final class MenuBarItemSourcePIDCache: @unchecked Sendable {
    static let shared = MenuBarItemSourcePIDCache()
    private static let maximumPositiveAge: TimeInterval = 5 * 60

    private struct Fingerprint: Equatable {
        let ownerPID: pid_t
        let ownerLaunchDate: Date?
        let layer: Int
        let minY: Int
        let width: Int
        let height: Int
        let semanticTitle: String?

        init(_ window: WindowInfo) {
            ownerPID = window.ownerPID
            ownerLaunchDate = window.owningApplication?.launchDate
            layer = window.layer
            minY = Self.units(window.frame.minY)
            width = Self.units(window.frame.width)
            height = Self.units(window.frame.height)
            semanticTitle =
                MenuBarItemSourcePIDRequestPolicy.stableSemanticTitle(
                    window.title
                )
        }

        private static func units(_ value: CGFloat) -> Int {
            Int((value * 8).rounded())
        }
    }

    private struct Entry: Equatable {
        let sourcePID: pid_t
        let sourceLaunchDate: Date?
        let fingerprint: Fingerprint
        let resolvedAt: Date

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sourcePID == rhs.sourcePID &&
                lhs.sourceLaunchDate == rhs.sourceLaunchDate &&
                lhs.fingerprint == rhs.fingerprint
        }
    }

    private struct State {
        var entries = [CGWindowID: Entry]()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    func sourcePID(for window: WindowInfo) -> pid_t? {
        if #unavailable(macOS 26.0) {
            return window.ownerPID
        }
        if Self.isOwnControlItem(window) {
            return ProcessInfo.processInfo.processIdentifier
        }
        if let ownerBundleIdentifier = window.owningApplication?.bundleIdentifier,
           ownerBundleIdentifier != MenuBarItemInfo.Namespace.controlCenter.rawValue
        {
            return window.ownerPID
        }
        if Self.isHostedByControlCenter(window),
           let title = window.title,
           MenuBarItemInfo.isControlCenterModuleTitle(title)
        {
            return window.ownerPID
        }
        return state.withLock { state in
            guard
                let entry = state.entries[window.windowID],
                entry.fingerprint == Fingerprint(window),
                Date.now.timeIntervalSince(entry.resolvedAt) <=
                    Self.maximumPositiveAge,
                Self.processIsAlive(
                    entry.sourcePID,
                    launchedAt: entry.sourceLaunchDate
                )
            else {
                state.entries.removeValue(forKey: window.windowID)
                return nil
            }
            return entry.sourcePID
        }
    }

    func needsResolution(for windowIDs: Set<CGWindowID>, in windows: [WindowInfo]) -> Bool {
        if #unavailable(macOS 26.0) {
            return false
        }
        let windowsByID = Dictionary(
            windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return windowIDs.contains { windowID in
            guard
                let window = windowsByID[windowID],
                window.isMenuBarItem,
                !Self.isOwnControlItem(window)
            else {
                return false
            }
            return sourcePID(for: window) == nil
        }
    }

    /// Reconciles positive entries against one authoritative WindowServer snapshot.
    ///
    /// This runs independently of XPC resolution so disappeared or recycled
    /// window IDs cannot retain a source merely because every current item is
    /// already resolved.
    @discardableResult
    func reconcile(withFullSnapshot windows: [WindowInfo]) -> Bool {
        let windowsByID = Dictionary(
            windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = Date.now
        return state.withLock { state in
            let oldEntries = state.entries
            Self.reconcile(
                entries: &state.entries,
                windowsByID: windowsByID,
                now: now
            )
            return state.entries != oldEntries
        }
    }

    @discardableResult
    func merge(
        liveWindows: [WindowInfo],
        resolvedWindows: [WindowInfo],
        sourcePIDs: [pid_t?]
    ) -> Bool {
        let windowsByID = Dictionary(
            liveWindows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = Date.now

        return state.withLock { state in
            let oldEntries = state.entries
            Self.reconcile(
                entries: &state.entries,
                windowsByID: windowsByID,
                now: now
            )

            for (window, sourcePID) in zip(resolvedWindows, sourcePIDs) {
                if Self.isOwnControlItem(window) {
                    state.entries[window.windowID] = Entry(
                        sourcePID: ProcessInfo.processInfo.processIdentifier,
                        sourceLaunchDate: NSRunningApplication.current.launchDate,
                        fingerprint: Fingerprint(window),
                        resolvedAt: now
                    )
                } else if let sourcePID, Self.processIsAlive(sourcePID) {
                    state.entries[window.windowID] = Entry(
                        sourcePID: sourcePID,
                        sourceLaunchDate: NSRunningApplication(
                            processIdentifier: sourcePID
                        )?.launchDate,
                        fingerprint: Fingerprint(window),
                        resolvedAt: now
                    )
                }
            }
            return state.entries != oldEntries
        }
    }

    private static func reconcile(
        entries: inout [CGWindowID: Entry],
        windowsByID: [CGWindowID: WindowInfo],
        now: Date
    ) {
        entries = entries.filter { windowID, entry in
            guard
                let window = windowsByID[windowID],
                window.isMenuBarItem
            else {
                return false
            }
            return entry.fingerprint == Fingerprint(window) &&
                now.timeIntervalSince(entry.resolvedAt) <=
                    maximumPositiveAge &&
                processIsAlive(
                    entry.sourcePID,
                    launchedAt: entry.sourceLaunchDate
                )
        }
    }

    private static func isOwnControlItem(_ window: WindowInfo) -> Bool {
        guard let title = window.title, ControlItem.Identifier.isRecognizedTitle(title) else {
            return false
        }
        return window.ownerPID == ProcessInfo.processInfo.processIdentifier ||
            window.owningApplication?.bundleIdentifier == "com.apple.controlcenter"
    }

    private static func isHostedByControlCenter(_ window: WindowInfo) -> Bool {
        window.owningApplication?.bundleIdentifier ==
            MenuBarItemInfo.Namespace.controlCenter.rawValue
    }

    private static func processIsAlive(
        _ pid: pid_t,
        launchedAt expectedLaunchDate: Date? = nil
    ) -> Bool {
        if kill(pid, 0) == 0 {
            if let expectedLaunchDate {
                return NSRunningApplication(
                    processIdentifier: pid
                )?.launchDate == expectedLaunchDate
            }
            return true
        }
        return errno != ESRCH
    }
}

/// Serializes source PID resolution so menu bar refreshes cannot start
/// overlapping Accessibility scans.
actor MenuBarItemSourcePIDResolver {
    struct Result {
        let changed: Bool
        let retryDelay: TimeInterval?
    }

    static let shared = MenuBarItemSourcePIDResolver()

    private let connection = MenuBarItemServiceConnection()
    private let logger = Logger(category: "SourcePIDResolver")
    private var lastUnresolvedLogDate = Date.distantPast
    private var nextAllowedAttempt = Date.distantPast
    private var unresolvedFailures = 0
    private var lastUnresolvedWindowIDs = Set<CGWindowID>()
    private var requestSelectionState =
        MenuBarItemSourcePIDRequestPolicy.State()

    func verifyServiceConnection() async -> Bool {
        await connection.sourcePIDs(for: []) == []
    }

    func resolve(
        windows: [WindowInfo],
        requiredWindowIDs: Set<CGWindowID>
    ) async -> Result {
        if #unavailable(macOS 26.0) {
            return Result(changed: false, retryDelay: nil)
        }
        let now = Date.now
        let windowsByID = Dictionary(
            windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let unresolvedWindowIDs = Set(requiredWindowIDs.filter { windowID in
            guard let window = windowsByID[windowID], window.isMenuBarItem else {
                return false
            }
            return MenuBarItemSourcePIDCache.shared.sourcePID(for: window) == nil
        })
        guard !unresolvedWindowIDs.isEmpty else {
            unresolvedFailures = 0
            lastUnresolvedWindowIDs = []
            requestSelectionState = .init()
            return Result(changed: false, retryDelay: nil)
        }
        if unresolvedWindowIDs != lastUnresolvedWindowIDs {
            unresolvedFailures = 0
            nextAllowedAttempt = .distantPast
            lastUnresolvedWindowIDs = unresolvedWindowIDs
        }
        guard now >= nextAllowedAttempt else {
            return Result(
                changed: false,
                retryDelay: nextAllowedAttempt.timeIntervalSince(now)
            )
        }
        guard
            !windows.isEmpty
        else {
            return Result(changed: false, retryDelay: nil)
        }

        let unresolvedRequired = windows.filter {
            unresolvedWindowIDs.contains($0.windowID)
        }
        let markerSupporting = windows.filter {
            !unresolvedWindowIDs.contains($0.windowID) &&
                $0.isMenuBarItem &&
                MenuBarItemSourcePIDRequestPolicy.isBundleShapedTitle($0.title)
        }
        let markerWindowIDs = Set(markerSupporting.map(\.windowID))
        let orderedSupporting = markerSupporting + windows.filter {
            !unresolvedWindowIDs.contains($0.windowID) &&
                !requiredWindowIDs.contains($0.windowID) &&
                $0.isMenuBarItem &&
                !markerWindowIDs.contains($0.windowID)
        }
        let selectedWindowIDs =
            MenuBarItemSourcePIDRequestPolicy.selectWindowIDs(
                unresolvedRequired: unresolvedRequired.map(\.windowID),
                supporting: orderedSupporting.map(\.windowID),
                maximumCount: MenuBarItemService.maximumWindowCount,
                state: &requestSelectionState
            )
        let requestWindows = selectedWindowIDs.compactMap {
            windowsByID[$0]
        }
        guard !requestWindows.isEmpty else {
            return Result(changed: false, retryDelay: nil)
        }
        guard let sourcePIDs = await connection.sourcePIDs(
            for: requestWindows.map(MenuBarItemService.Window.init)
        )
        else {
            nextAllowedAttempt = Date.now.addingTimeInterval(30)
            logger.warning("Source PID service did not respond; retrying later")
            return Result(changed: false, retryDelay: 30)
        }
        guard sourcePIDs.count == requestWindows.count else {
            nextAllowedAttempt = Date.now.addingTimeInterval(30)
            logger.warning(
                "Source PID service returned \(sourcePIDs.count) results for \(requestWindows.count) windows"
            )
            return Result(changed: false, retryDelay: 30)
        }

        let changed = MenuBarItemSourcePIDCache.shared.merge(
            liveWindows: windows,
            resolvedWindows: requestWindows,
            sourcePIDs: sourcePIDs
        )
        let resolvedCount = sourcePIDs.compactMap(\.self).count
        if changed {
            logger.info(
                "Resolved \(resolvedCount)/\(requestWindows.count) menu bar source PIDs"
            )
        }
        let resolvedWindowIDs: Set<CGWindowID> = Set(
            windows.compactMap { window -> CGWindowID? in
                guard
                    unresolvedWindowIDs.contains(window.windowID),
                    MenuBarItemSourcePIDCache.shared.sourcePID(
                        for: window
                    ) != nil
                else {
                    return nil
                }
                return window.windowID
            }
        )
        let remainingUnresolvedWindowIDs =
            MenuBarItemSourcePIDRequestPolicy.remainingUnresolvedWindowIDs(
                required: unresolvedWindowIDs,
                resolved: resolvedWindowIDs
            )
        let unresolved: [WindowInfo] = windows.filter {
            remainingUnresolvedWindowIDs.contains($0.windowID)
        }
        if
            !unresolved.isEmpty,
            Date.now.timeIntervalSince(lastUnresolvedLogDate) >= 60
        {
            lastUnresolvedLogDate = .now
            let summary = unresolved.prefix(8).map {
                "\($0.windowID):\($0.title ?? "<nil>")"
            }.joined(separator: ", ")
            logger.warning(
                "Unresolved macOS 26 menu bar source PIDs: \(summary)"
            )
        }
        if unresolved.isEmpty {
            unresolvedFailures = 0
            lastUnresolvedWindowIDs = []
            requestSelectionState = .init()
            nextAllowedAttempt = .distantPast
            return Result(changed: changed, retryDelay: nil)
        }

        lastUnresolvedWindowIDs = Set(unresolved.map(\.windowID))
        unresolvedFailures += 1
        let retryDelay: TimeInterval = switch unresolvedFailures {
        case 1: 5
        case 2: 15
        default: 60
        }
        nextAllowedAttempt = Date.now.addingTimeInterval(retryDelay)
        return Result(changed: changed, retryDelay: retryDelay)
    }
}

/// NSXPCConnection wrapper with a bounded reply wait.
private final class MenuBarItemServiceConnection: @unchecked Sendable {
    private final class ReplyBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<
            CheckedContinuation<Data?, Never>?
        >(initialState: nil)

        func store(_ continuation: CheckedContinuation<Data?, Never>) {
            lock.withLock { $0 = continuation }
        }

        func resume(returning data: Data?) {
            let continuation = lock.withLock { $0.take() }
            continuation?.resume(returning: data)
        }
    }

    private let logger = Logger(category: "MenuBarItemService.Connection")
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    private var connectionGeneration: UInt64 = 0

    deinit {
        connectionLock.lock()
        let existing = connection
        connection = nil
        connectionLock.unlock()
        existing?.invalidate()
    }

    func sourcePIDs(for windows: [MenuBarItemService.Window]) async -> [pid_t?]? {
        let request = MenuBarItemService.Request(
            version: MenuBarItemService.protocolVersion,
            windows: windows
        )
        guard let requestData = try? JSONEncoder().encode(request) else {
            return nil
        }

        let connectionContext = serviceConnection()
        let responseData = await withCheckedContinuation { continuation in
            let replyBox = ReplyBox()
            replyBox.store(continuation)

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                replyBox.resume(returning: nil)
            }

            let proxy = connectionContext.connection
                .remoteObjectProxyWithErrorHandler { [weak self] error in
                    self?.logger.error(
                        "Menu bar item service request failed: \(error.localizedDescription)"
                    )
                    replyBox.resume(returning: nil)
                }
            guard let service = proxy as? MenuBarItemServiceProtocol else {
                logger.error("Menu bar item service proxy has an unexpected type")
                replyBox.resume(returning: nil)
                return
            }
            service.resolveSourcePIDs(requestData) { data in
                replyBox.resume(returning: data)
            }
        }

        guard let responseData else {
            invalidateConnection(generation: connectionContext.generation)
            return nil
        }
        guard
            let response = try? JSONDecoder().decode(
                MenuBarItemService.Response.self,
                from: responseData
            ),
            response.version == MenuBarItemService.protocolVersion
        else {
            invalidateConnection(generation: connectionContext.generation)
            return nil
        }
        return response.sourcePIDs
    }

    private func serviceConnection() -> (
        connection: NSXPCConnection,
        generation: UInt64
    ) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let connection {
            return (connection, connectionGeneration)
        }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let newConnection = NSXPCConnection(
            serviceName: MenuBarItemService.name
        )
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: MenuBarItemServiceProtocol.self
        )
        newConnection.interruptionHandler = { [weak self] in
            self?.discard(generation: generation)
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.discard(generation: generation)
        }
        newConnection.resume()
        connection = newConnection
        return (newConnection, generation)
    }

    private func invalidateConnection(generation: UInt64) {
        connectionLock.lock()
        guard connectionGeneration == generation else {
            connectionLock.unlock()
            return
        }
        let existing = connection
        connection = nil
        connectionGeneration &+= 1
        connectionLock.unlock()
        existing?.invalidate()
    }

    private func discard(generation: UInt64) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard connectionGeneration == generation else {
            return
        }
        connection = nil
    }
}
