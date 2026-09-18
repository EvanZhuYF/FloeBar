import CoreGraphics
import Foundation

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw NSError(
            domain: "ScreenCaptureCoordinatorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private actor ManualSleeper {
    private struct Registration {
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var continuations = [Int: Registration]()
    private var registrations = [(duration: Duration, identifier: Int)]()
    private var count = 0

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations[count] = Registration(
                duration: duration,
                continuation: continuation
            )
            registrations.append((duration, count))
            count += 1
        }
    }

    func waitForCount(_ expected: Int, for duration: Duration) async throws {
        for _ in 0..<1_000 {
            if registrations.lazy.filter({ $0.duration == duration }).count >= expected {
                return
            }
            await Task.yield()
        }
        throw NSError(
            domain: "ScreenCaptureCoordinatorTests",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for \(expected) registrations at \(duration)"
            ]
        )
    }

    func registrationCount(for duration: Duration) -> Int {
        registrations.lazy.filter { $0.duration == duration }.count
    }

    func fire(_ occurrence: Int, for duration: Duration) throws {
        let matching = registrations.filter { $0.duration == duration }
        guard
            matching.indices.contains(occurrence),
            let registration = continuations.removeValue(
                forKey: matching[occurrence].identifier
            )
        else {
            throw NSError(
                domain: "ScreenCaptureCoordinatorTests",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing registration \(occurrence) at \(duration)"
                ]
            )
        }
        registration.continuation.resume()
    }

    func fireAll() {
        let current = continuations.values.map(\.continuation)
        continuations.removeAll()
        for continuation in current {
            continuation.resume()
        }
    }
}

private actor CaptureOperations {
    private var continuations = [Int: CheckedContinuation<CGImage?, Never>]()
    private(set) var starts = [Int]()
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0

    func run(_ identifier: Int) async -> CGImage? {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        starts.append(identifier)
        let image = await withCheckedContinuation { continuation in
            continuations[identifier] = continuation
        }
        activeCount -= 1
        return image
    }

    func finish(_ identifier: Int, width: Int) throws {
        guard let continuation = continuations.removeValue(forKey: identifier) else {
            throw NSError(
                domain: "ScreenCaptureCoordinatorTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Capture \(identifier) was not active"]
            )
        }
        continuation.resume(returning: Self.image(width: width))
    }

    func waitForStarts(_ expected: Int) async throws {
        for _ in 0..<1_000 {
            if starts.count >= expected {
                return
            }
            await Task.yield()
        }
        throw NSError(
            domain: "ScreenCaptureCoordinatorTests",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(expected) captures"]
        )
    }

    private static func image(width: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}

private actor Results {
    private enum Outcome {
        case image(Int)
        case none
    }

    private var outcomes = [Int: Outcome]()
    private var completionCounts = [Int: Int]()

    func record(_ identifier: Int, image: CGImage?) {
        completionCounts[identifier, default: 0] += 1
        outcomes[identifier] = image.map { .image($0.width) } ?? Outcome.none
    }

    func completionCount(for identifier: Int) -> Int {
        completionCounts[identifier, default: 0]
    }

    func wait(for identifier: Int) async throws -> Int? {
        for _ in 0..<1_000 {
            if let outcome = outcomes[identifier] {
                switch outcome {
                case let .image(width):
                    return width
                case .none:
                    return nil
                }
            }
            await Task.yield()
        }
        throw NSError(
            domain: "ScreenCaptureCoordinatorTests",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for result \(identifier)"]
        )
    }
}

@main
private enum ScreenCaptureCoordinatorTests {
    typealias Coordinator = ScreenCapture.CaptureCoordinator

    static func main() async throws {
        try await latestPendingRequestWins()
        try await cancellationAndTimeoutInterleavings()
        try await hardAbandonBoundsHungCaptures()
        print("PASS: screen capture coordinator interleavings")
    }

    private static func key(_ identifier: UInt32) -> Coordinator.Key {
        Coordinator.Key(windowIDs: [identifier], bounds: nil, options: 0)
    }

    @discardableResult
    private static func submit(
        _ identifier: Int,
        key: Coordinator.Key,
        coordinator: Coordinator,
        operations: CaptureOperations,
        results: Results
    ) -> Task<Void, Never> {
        Task {
            let image = await coordinator.image(for: key) {
                await operations.run(identifier)
            }
            await results.record(identifier, image: image)
        }
    }

    private static func latestPendingRequestWins() async throws {
        let callerTimeout = Duration.seconds(60)
        let hardAbandonTimeout = Duration.seconds(120)
        let sleeper = ManualSleeper()
        let operations = CaptureOperations()
        let results = Results()
        let coordinator = Coordinator(
            timeout: callerTimeout,
            hardAbandonTimeout: hardAbandonTimeout
        ) { duration in
            try await sleeper.sleep(for: duration)
        }

        submit(1, key: key(1), coordinator: coordinator, operations: operations, results: results)
        try await operations.waitForStarts(1)
        try await sleeper.waitForCount(1, for: callerTimeout)
        try await sleeper.waitForCount(1, for: hardAbandonTimeout)

        var latest = 2
        submit(latest, key: key(UInt32(latest)), coordinator: coordinator, operations: operations, results: results)
        try await sleeper.waitForCount(2, for: callerTimeout)

        for identifier in 3...20 {
            submit(identifier, key: key(UInt32(identifier)), coordinator: coordinator, operations: operations, results: results)
            try await sleeper.waitForCount(identifier, for: callerTimeout)
            try expect(
                await results.wait(for: latest) == nil,
                "Replacing the pending key must release request \(latest)"
            )
            latest = identifier
        }

        let startsBeforeFinish = await operations.starts
        let maximumBeforeFinish = await operations.maximumActiveCount
        try expect(startsBeforeFinish == [1], "Pending captures must not overlap an active capture")
        try expect(maximumBeforeFinish == 1, "Only one underlying capture may run")

        try await operations.finish(1, width: 11)
        try await operations.waitForStarts(2)
        try expect(await results.wait(for: 1) == 11, "The active request must receive its image")
        let startsAfterFinish = await operations.starts
        try expect(
            startsAfterFinish == [1, latest],
            "Only the latest pending key must start after the active capture"
        )
        let maximumAfterFinish = await operations.maximumActiveCount
        try expect(maximumAfterFinish == 1, "Replacement must preserve serialized captures")

        try await operations.finish(latest, width: 22)
        try expect(await results.wait(for: latest) == 22, "The latest pending request must receive its image")
        await sleeper.fireAll()
    }

    private static func cancellationAndTimeoutInterleavings() async throws {
        let callerTimeout = Duration.seconds(60)
        let hardAbandonTimeout = Duration.seconds(120)
        let sleeper = ManualSleeper()
        let operations = CaptureOperations()
        let results = Results()
        let coordinator = Coordinator(
            timeout: callerTimeout,
            hardAbandonTimeout: hardAbandonTimeout
        ) { duration in
            try await sleeper.sleep(for: duration)
        }

        submit(1, key: key(1), coordinator: coordinator, operations: operations, results: results)
        try await operations.waitForStarts(1)
        try await sleeper.waitForCount(1, for: callerTimeout)
        try await sleeper.waitForCount(1, for: hardAbandonTimeout)
        let coalesced = submit(2, key: key(1), coordinator: coordinator, operations: operations, results: results)
        coalesced.cancel()
        try expect(await results.wait(for: 2) == nil, "Cancellation must release only its coalesced waiter")
        try await operations.finish(1, width: 10)
        try expect(await results.wait(for: 1) == 10, "Another coalesced waiter must remain active")

        submit(3, key: key(3), coordinator: coordinator, operations: operations, results: results)
        try await operations.waitForStarts(2)
        try await sleeper.waitForCount(2, for: callerTimeout)
        try await sleeper.waitForCount(2, for: hardAbandonTimeout)
        let pending = submit(4, key: key(4), coordinator: coordinator, operations: operations, results: results)
        try await sleeper.waitForCount(3, for: callerTimeout)
        pending.cancel()
        try expect(await results.wait(for: 4) == nil, "Cancelling the last pending waiter must remove its request")
        try await operations.finish(3, width: 30)
        try expect(await results.wait(for: 3) == 30, "The active request must survive pending cancellation")
        let startsAfterCancellation = await operations.starts
        try expect(startsAfterCancellation == [1, 3], "A cancelled pending request must never start")

        submit(5, key: key(5), coordinator: coordinator, operations: operations, results: results)
        try await operations.waitForStarts(3)
        try await sleeper.waitForCount(4, for: callerTimeout)
        try await sleeper.waitForCount(3, for: hardAbandonTimeout)
        submit(6, key: key(6), coordinator: coordinator, operations: operations, results: results)
        try await sleeper.waitForCount(5, for: callerTimeout)

        try await sleeper.fire(3, for: callerTimeout)
        try expect(await results.wait(for: 5) == nil, "An active timeout must release its waiter")
        let startsAfterTimeout = await operations.starts
        try expect(startsAfterTimeout == [1, 3, 5], "Timeout must not free an unfinished underlying slot")

        submit(7, key: key(7), coordinator: coordinator, operations: operations, results: results)
        try await sleeper.waitForCount(6, for: callerTimeout)
        try expect(await results.wait(for: 6) == nil, "A newer pending key must release the replaced waiter")
        let maximumWhileHung = await operations.maximumActiveCount
        try expect(maximumWhileHung == 1, "A timed-out hung capture must prevent overlap")

        try await operations.finish(5, width: 50)
        try await operations.waitForStarts(4)
        let startsAfterHungFinish = await operations.starts
        let maximumAfterHungFinish = await operations.maximumActiveCount
        try expect(startsAfterHungFinish == [1, 3, 5, 7], "Latest pending capture must start when the hung capture returns")
        try expect(maximumAfterHungFinish == 1, "Timeout replacement must remain serialized")

        try await sleeper.waitForCount(4, for: hardAbandonTimeout)
        try await sleeper.fire(5, for: callerTimeout)
        try expect(await results.wait(for: 7) == nil, "A pending request's timeout must follow that request after it starts")
        try await operations.finish(7, width: 70)

        submit(8, key: key(8), coordinator: coordinator, operations: operations, results: results)
        try await operations.waitForStarts(5)
        try await sleeper.waitForCount(7, for: callerTimeout)
        try await sleeper.waitForCount(5, for: hardAbandonTimeout)
        try await operations.finish(8, width: 80)
        try expect(await results.wait(for: 8) == 80, "A post-timeout capture must complete normally")
        let finalMaximum = await operations.maximumActiveCount
        try expect(finalMaximum == 1, "Underlying capture concurrency must stay bounded")
        await sleeper.fireAll()
    }

    private static func hardAbandonBoundsHungCaptures() async throws {
        try await failFastRecovers(completingOrphanFirst: true)
        try await failFastRecovers(completingOrphanFirst: false)
    }

    private static func failFastRecovers(
        completingOrphanFirst: Bool
    ) async throws {
        let callerTimeout = Duration.seconds(1)
        let hardAbandonTimeout = Duration.seconds(2)
        let sleeper = ManualSleeper()
        let operations = CaptureOperations()
        let results = Results()
        let coordinator = Coordinator(
            timeout: callerTimeout,
            hardAbandonTimeout: hardAbandonTimeout
        ) { duration in
            try await sleeper.sleep(for: duration)
        }

        submit(1, key: key(1), coordinator: coordinator, operations: operations, results: results)
        try await operations.waitForStarts(1)
        try await sleeper.waitForCount(1, for: callerTimeout)
        try await sleeper.waitForCount(1, for: hardAbandonTimeout)

        submit(2, key: key(2), coordinator: coordinator, operations: operations, results: results)
        try await sleeper.waitForCount(2, for: callerTimeout)
        try await sleeper.fire(0, for: callerTimeout)
        try expect(await results.wait(for: 1) == nil, "The first hung caller must time out")

        try await sleeper.fire(0, for: hardAbandonTimeout)
        try await operations.waitForStarts(2)
        try await sleeper.waitForCount(2, for: hardAbandonTimeout)
        try await waitForState(
            coordinator,
            activeKey: key(2),
            activeExpired: false,
            activeHardAbandonExpired: false,
            hasOrphan: true,
            isFailingFast: false,
            pendingKey: nil
        )
        try expect(
            await operations.maximumActiveCount == 2,
            "A replacement may overlap exactly one orphan"
        )

        submit(3, key: key(3), coordinator: coordinator, operations: operations, results: results)
        try await sleeper.waitForCount(3, for: callerTimeout)
        try await sleeper.fire(1, for: callerTimeout)
        try expect(await results.wait(for: 2) == nil, "The second hung caller must time out")
        try await sleeper.fire(1, for: hardAbandonTimeout)
        try expect(
            await results.wait(for: 3) == nil,
            "The second hard timeout must release the pending request immediately"
        )
        try await waitForState(
            coordinator,
            activeKey: key(2),
            activeExpired: true,
            activeHardAbandonExpired: true,
            hasOrphan: true,
            isFailingFast: true,
            pendingKey: nil
        )
        let startsWhileBothHung = await operations.starts
        try expect(
            startsWhileBothHung == [1, 2],
            "A second hang must stay active while the orphan slot is occupied"
        )
        let callerRegistrations = await sleeper.registrationCount(for: callerTimeout)
        let hardAbandonRegistrations = await sleeper.registrationCount(for: hardAbandonTimeout)

        submit(4, key: key(4), coordinator: coordinator, operations: operations, results: results)
        try expect(
            await results.wait(for: 4) == nil,
            "The open circuit must fail future requests immediately"
        )
        try expect(
            await sleeper.registrationCount(for: callerTimeout) == callerRegistrations,
            "Fail-fast requests must not schedule caller timeouts"
        )
        try expect(
            await sleeper.registrationCount(for: hardAbandonTimeout) == hardAbandonRegistrations,
            "Fail-fast requests must not schedule hard timeouts"
        )
        try expect(
            await operations.starts == [1, 2],
            "Fail-fast requests must not start another underlying capture"
        )

        let completedHungCapture = completingOrphanFirst ? 1 : 2
        let remainingHungCapture = completingOrphanFirst ? 2 : 1
        try await operations.finish(
            completedHungCapture,
            width: completedHungCapture * 10
        )
        try await waitForState(
            coordinator,
            activeKey: nil,
            activeExpired: false,
            activeHardAbandonExpired: false,
            hasOrphan: true,
            isFailingFast: false,
            pendingKey: nil
        )
        try expect(
            await results.completionCount(for: completedHungCapture) == 1,
            "A late hung result must not resume its timed-out caller again"
        )

        submit(5, key: key(5), coordinator: coordinator, operations: operations, results: results)
        try await operations.waitForStarts(3)
        try await sleeper.waitForCount(4, for: callerTimeout)
        try await sleeper.waitForCount(3, for: hardAbandonTimeout)
        try expect(
            await operations.maximumActiveCount == 2,
            "Recovered captures must keep underlying concurrency at two"
        )

        try await operations.finish(5, width: 55)
        try expect(await results.wait(for: 5) == 55, "The recovered request must complete normally")
        try await operations.finish(
            remainingHungCapture,
            width: remainingHungCapture * 10
        )
        try expect(
            await results.completionCount(for: remainingHungCapture) == 1,
            "The remaining late result must not double-resume its caller"
        )
        await sleeper.fireAll()
    }

    private static func waitForState(
        _ coordinator: Coordinator,
        activeKey: Coordinator.Key?,
        activeExpired: Bool,
        activeHardAbandonExpired: Bool,
        hasOrphan: Bool,
        isFailingFast: Bool,
        pendingKey: Coordinator.Key?
    ) async throws {
        let expected = Coordinator.TestState(
            activeKey: activeKey,
            activeExpired: activeExpired,
            activeHardAbandonExpired: activeHardAbandonExpired,
            hasOrphan: hasOrphan,
            isFailingFast: isFailingFast,
            pendingKey: pendingKey
        )
        for _ in 0..<1_000 {
            if await coordinator.testState() == expected {
                return
            }
            await Task.yield()
        }
        let actual = await coordinator.testState()
        throw NSError(
            domain: "ScreenCaptureCoordinatorTests",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for state \(expected); found \(actual)"
            ]
        )
    }
}
