//
//  ScreenCapture.swift
//  FloeBar
//

import CoreGraphics
import os.lock
import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {
    private final class LegacyCaptureGate: @unchecked Sendable {
        private let deadlines = OSAllocatedUnfairLock(
            initialState: [String: ContinuousClock.Instant]()
        )

        func claim(_ key: String, minimumInterval: Duration) -> Bool {
            let now = ContinuousClock.now
            return deadlines.withLock { deadlines in
                if let deadline = deadlines[key], deadline > now {
                    return false
                }
                deadlines[key] = now + minimumInterval
                return true
            }
        }
    }

    private actor ShareableContentCache {
        private struct RecentFailure: Error {}

        private var cached: (
            content: SCShareableContent,
            date: ContinuousClock.Instant
        )?
        private var inFlight: Task<SCShareableContent, any Error>?
        private var retryAfter: ContinuousClock.Instant?

        func content() async throws -> SCShareableContent {
            let now = ContinuousClock.now
            if let cached, ContinuousClock.now - cached.date < .seconds(1) {
                return cached.content
            }
            if let retryAfter, retryAfter > now {
                throw RecentFailure()
            }
            if let inFlight {
                return try await inFlight.value
            }
            let task = Task<SCShareableContent, any Error> {
                try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            }
            inFlight = task
            defer { inFlight = nil }
            do {
                let content = try await task.value
                cached = (content, .now)
                retryAfter = nil
                return content
            } catch {
                retryAfter = .now + .seconds(15)
                throw error
            }
        }
    }

    private static let shareableContentCache = ShareableContentCache()
    private static let legacyCaptureGate = LegacyCaptureGate()

    /// ScreenCaptureKit has no cancellation handle for an outstanding
    /// screenshot completion callback. Caller timeouts release waiters, while a
    /// larger hard timeout permits one abandoned capture to remain outstanding.
    /// Two hard-expired captures fail fast until a late completion frees space.
    actor CaptureCoordinator {
        struct Key: Equatable {
            let windowIDs: [CGWindowID]
            let bounds: CGRect?
            let options: UInt32
        }

        #if SCREEN_CAPTURE_COORDINATOR_TESTS
        struct TestState: Equatable {
            let activeKey: Key?
            let activeExpired: Bool
            let activeHardAbandonExpired: Bool
            let hasOrphan: Bool
            let isFailingFast: Bool
            let pendingKey: Key?
        }
        #endif

        typealias Operation = @Sendable () async -> CGImage?
        typealias Sleep = @Sendable (Duration) async throws -> Void

        private struct Request {
            let id: UUID
            let key: Key
            let operation: Operation
            var waiters: [UUID: CheckedContinuation<CGImage?, Never>]
            var expired = false
            var hardAbandonExpired = false
        }

        private let timeout: Duration
        private let hardAbandonTimeout: Duration
        private let sleep: Sleep
        private var activeRequest: Request?
        private var orphanedRequestID: UUID?
        private var pendingRequest: Request?
        private var timeoutTasks = [UUID: Task<Void, Never>]()
        private var hardAbandonTasks = [UUID: Task<Void, Never>]()

        private var isFailingFast: Bool {
            guard let activeRequest else {
                return false
            }
            return orphanedRequestID != nil
                && activeRequest.expired
                && activeRequest.hardAbandonExpired
        }

        init(
            timeout: Duration = .seconds(3),
            hardAbandonTimeout: Duration = .seconds(20),
            sleep: @escaping Sleep = { duration in
                try await Task.sleep(for: duration)
            }
        ) {
            precondition(hardAbandonTimeout > timeout)
            self.timeout = timeout
            self.hardAbandonTimeout = hardAbandonTimeout
            self.sleep = sleep
        }

        func hasActiveWaiters(for key: Key) -> Bool {
            guard let activeRequest, activeRequest.key == key else {
                return false
            }
            return !activeRequest.expired && !activeRequest.waiters.isEmpty
        }

        #if SCREEN_CAPTURE_COORDINATOR_TESTS
        func testState() -> TestState {
            TestState(
                activeKey: activeRequest?.key,
                activeExpired: activeRequest?.expired ?? false,
                activeHardAbandonExpired: activeRequest?.hardAbandonExpired ?? false,
                hasOrphan: orphanedRequestID != nil,
                isFailingFast: isFailingFast,
                pendingKey: pendingRequest?.key
            )
        }
        #endif

        func image(
            for key: Key,
            operation: @escaping Operation
        ) async -> CGImage? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled, !isFailingFast else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if
                        var current = activeRequest,
                        current.key == key,
                        !current.expired
                    {
                        current.waiters[waiterID] = continuation
                        activeRequest = current
                        return
                    }
                    if var pending = pendingRequest, pending.key == key {
                        pending.waiters[waiterID] = continuation
                        pendingRequest = pending
                        return
                    }

                    let request = Request(
                        id: UUID(),
                        key: key,
                        operation: operation,
                        waiters: [waiterID: continuation]
                    )
                    if activeRequest == nil {
                        start(request)
                    } else {
                        replacePendingRequest(with: request)
                    }
                }
            } onCancel: {
                Task { await self.cancel(waiterID) }
            }
        }

        private func cancel(_ waiterID: UUID) {
            if let waiter = activeRequest?.waiters.removeValue(forKey: waiterID) {
                waiter.resume(returning: nil)
                return
            }
            guard let waiter = pendingRequest?.waiters.removeValue(forKey: waiterID) else {
                return
            }
            waiter.resume(returning: nil)
            if pendingRequest?.waiters.isEmpty == true {
                let requestID = pendingRequest?.id
                pendingRequest = nil
                if let requestID {
                    cancelTimeout(for: requestID)
                }
            }
        }

        private func replacePendingRequest(with request: Request) {
            if let pending = pendingRequest {
                pendingRequest = nil
                cancelTimeout(for: pending.id)
                resume(pending.waiters, returning: nil)
            }
            pendingRequest = request
            scheduleTimeout(for: request.id)
        }

        private func start(_ request: Request) {
            precondition(activeRequest == nil)
            activeRequest = request
            if timeoutTasks[request.id] == nil {
                scheduleTimeout(for: request.id)
            }
            scheduleHardAbandon(for: request.id)
            Task {
                let image = await request.operation()
                finish(request.id, image: image)
            }
        }

        private func scheduleTimeout(for requestID: UUID) {
            let timeout = timeout
            let sleep = sleep
            timeoutTasks[requestID] = Task {
                do {
                    try await sleep(timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                expire(requestID)
            }
        }

        private func scheduleHardAbandon(for requestID: UUID) {
            let hardAbandonTimeout = hardAbandonTimeout
            let sleep = sleep
            hardAbandonTasks[requestID] = Task {
                do {
                    try await sleep(hardAbandonTimeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                hardAbandon(requestID)
            }
        }

        private func cancelTimeout(for requestID: UUID) {
            timeoutTasks.removeValue(forKey: requestID)?.cancel()
        }

        private func cancelHardAbandon(for requestID: UUID) {
            hardAbandonTasks.removeValue(forKey: requestID)?.cancel()
        }

        private func expire(_ requestID: UUID) {
            timeoutTasks[requestID] = nil
            if var active = activeRequest, active.id == requestID {
                guard !active.expired else {
                    return
                }
                let waiters = active.waiters
                active.waiters.removeAll()
                active.expired = true
                activeRequest = active
                resume(waiters, returning: nil)
                abandonActiveIfPossible()
                return
            }
            guard let pending = pendingRequest, pending.id == requestID else {
                return
            }
            pendingRequest = nil
            resume(pending.waiters, returning: nil)
        }

        private func hardAbandon(_ requestID: UUID) {
            hardAbandonTasks[requestID] = nil
            guard var active = activeRequest, active.id == requestID else {
                return
            }
            active.hardAbandonExpired = true
            activeRequest = active
            abandonActiveIfPossible()
        }

        private func abandonActiveIfPossible() {
            guard
                let active = activeRequest,
                active.expired,
                active.hardAbandonExpired
            else {
                return
            }
            guard orphanedRequestID == nil else {
                releasePendingRequest()
                return
            }
            precondition(active.waiters.isEmpty)
            activeRequest = nil
            orphanedRequestID = active.id
            cancelTimeout(for: active.id)
            cancelHardAbandon(for: active.id)
            startPendingRequest()
        }

        private func finish(_ requestID: UUID, image: CGImage?) {
            if orphanedRequestID == requestID {
                orphanedRequestID = nil
                abandonActiveIfPossible()
                return
            }
            guard let active = activeRequest, active.id == requestID else {
                return
            }
            activeRequest = nil
            cancelTimeout(for: requestID)
            cancelHardAbandon(for: requestID)
            resume(active.waiters, returning: image)
            startPendingRequest()
        }

        private func startPendingRequest() {
            guard activeRequest == nil, let pending = pendingRequest else {
                return
            }
            pendingRequest = nil
            start(pending)
        }

        private func releasePendingRequest() {
            guard let pending = pendingRequest else {
                return
            }
            pendingRequest = nil
            cancelTimeout(for: pending.id)
            resume(pending.waiters, returning: nil)
        }

        private func resume(
            _ waiters: [UUID: CheckedContinuation<CGImage?, Never>],
            returning image: CGImage?
        ) {
            for waiter in waiters.values {
                waiter.resume(returning: image)
            }
        }
    }

    private static let captureCoordinator = CaptureCoordinator()

    /// Limits use of the legacy window capture API on macOS 26, where
    /// repeated calls can grow WindowServer-side resources.
    static func claimLegacyCapture(
        for key: String,
        minimumInterval: Duration = .seconds(15)
    ) -> Bool {
        if #unavailable(macOS 26.0) {
            return true
        }
        return legacyCaptureGate.claim(
            key,
            minimumInterval: minimumInterval
        )
    }

    /// Returns a Boolean value that indicates whether the app has been granted screen capture permissions.
    static func checkPermissions() -> Bool {
        for item in MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true) {
            // Don't check items owned by Ice.
            if item.info.namespace == .ice {
                continue
            }
            return item.title != nil
        }
        // CGPreflightScreenCaptureAccess() only returns an initial value for whether the app
        // has permissions, but we can use it as a fallback.
        return CGPreflightScreenCaptureAccess()
    }

    /// Requests screen capture permissions.
    static func requestPermissions() {
        if #available(macOS 15.0, *) {
            // CGRequestScreenCaptureAccess() is broken on macOS 15. SCShareableContent requires
            // screen capture permissions, and triggers a request if the user doesn't have them.
            SCShareableContent.getWithCompletionHandler { _, _ in }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Captures a composite image of an array of windows.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture. Pass `nil` to capture the minimum rectangle that encloses the windows.
    ///   - option: Options that specify the image to be captured.
    static func captureWindows(_ windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        guard !windowIDs.isEmpty else {
            return nil
        }
        let bounds = screenBounds ?? windowIDs.reduce(CGRect.null) { result, windowID in
            guard let frame = Bridging.getWindowFrame(for: windowID) else {
                return result
            }
            return result.union(frame)
        }
        guard
            !bounds.isNull,
            !bounds.isEmpty,
            bounds.origin.x.isFinite,
            bounds.origin.y.isFinite,
            bounds.width.isFinite,
            bounds.height.isFinite,
            bounds.width * 2 <= 16_384,
            bounds.height * 2 <= 16_384
        else {
            return nil
        }
        let pointer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: windowIDs.count)
        defer {
            pointer.deallocate()
        }
        for (index, windowID) in windowIDs.enumerated() {
            pointer[index] = UnsafeRawPointer(bitPattern: UInt(windowID))
        }
        guard let windowArray = CFArrayCreate(kCFAllocatorDefault, pointer, windowIDs.count, nil) else {
            return nil
        }
        // ScreenCaptureKit doesn't support capturing composite images of offscreen menu bar items,
        // but this should be replaced once it does.
        return CGImage(
            windowListFromArrayScreenBounds: screenBounds ?? .null,
            windowArray: windowArray,
            imageOption: option
        )
    }

    /// Captures an image of a window.
    ///
    /// - Parameters:
    ///   - windowID: The identifier of the window to capture.
    ///   - screenBounds: The bounds to capture. Pass `nil` to capture the minimum rectangle that encloses the window.
    ///   - option: Options that specify the image to be captured.
    static func captureWindow(_ windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        captureWindows([windowID], screenBounds: screenBounds, option: option)
    }

    /// Captures on-screen windows with ScreenCaptureKit. Offscreen status
    /// items must continue using ``captureWindows``.
    static func captureWindowsOnScreen(
        _ windowIDs: [CGWindowID],
        screenBounds: CGRect? = nil,
        option: CGWindowImageOption = []
    ) async -> CGImage? {
        guard !Task.isCancelled, !windowIDs.isEmpty else {
            return nil
        }
        let key = CaptureCoordinator.Key(
            windowIDs: windowIDs.sorted(),
            bounds: screenBounds,
            options: option.rawValue
        )
        let image = await captureCoordinator.image(for: key) {
            await captureWindowsOnScreenUncoalesced(
                windowIDs,
                screenBounds: screenBounds,
                option: option,
                key: key
            )
        }
        return Task.isCancelled ? nil : image
    }

    private static func captureWindowsOnScreenUncoalesced(
        _ windowIDs: [CGWindowID],
        screenBounds: CGRect?,
        option: CGWindowImageOption,
        key: CaptureCoordinator.Key
    ) async -> CGImage? {
        let content: SCShareableContent
        do {
            content = try await shareableContentCache.content()
        } catch {
            return nil
        }
        guard await captureCoordinator.hasActiveWaiters(for: key) else {
            return nil
        }

        let windowsByID = Dictionary(
            content.windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let windows = windowIDs.compactMap { windowsByID[$0] }
        guard windows.count == windowIDs.count else {
            return nil
        }

        let windowBounds = windows.reduce(CGRect.null) {
            $0.union($1.frame)
        }
        let bounds = if let screenBounds, !screenBounds.isNull {
            screenBounds
        } else {
            windowBounds
        }
        guard
            !bounds.isNull,
            !bounds.isEmpty,
            bounds.width.isFinite,
            bounds.height.isFinite
        else {
            return nil
        }

        guard let display = content.displays.max(by: { lhs, rhs in
            Self.intersectionArea(lhs.frame, bounds) <
                Self.intersectionArea(rhs.frame, bounds)
        }), Self.intersectionArea(display.frame, bounds) > 0 else {
            return nil
        }

        let filter = SCContentFilter(display: display, including: windows)
        let scale: CGFloat = option.contains(.nominalResolution)
            ? 1
            : CGFloat(filter.pointPixelScale)
        let pixelWidth = bounds.width * scale
        let pixelHeight = bounds.height * scale
        guard
            pixelWidth > 0, pixelHeight > 0,
            pixelWidth <= 16_384, pixelHeight <= 16_384
        else {
            return nil
        }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadowsDisplay = option.contains(.boundsIgnoreFraming)
        configuration.sourceRect = CGRect(
            x: bounds.minX - display.frame.minX,
            y: bounds.minY - display.frame.minY,
            width: bounds.width,
            height: bounds.height
        )
        configuration.width = Int(pixelWidth.rounded())
        configuration.height = Int(pixelHeight.rounded())

        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Captures one on-screen window with ScreenCaptureKit.
    static func captureWindowOnScreen(
        _ windowID: CGWindowID,
        screenBounds: CGRect? = nil,
        option: CGWindowImageOption = []
    ) async -> CGImage? {
        await captureWindowsOnScreen(
            [windowID],
            screenBounds: screenBounds,
            option: option
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }
        return intersection.width * intersection.height
    }
}
