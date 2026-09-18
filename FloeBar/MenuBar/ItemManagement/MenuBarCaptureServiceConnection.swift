//
//  MenuBarCaptureServiceConnection.swift
//  FloeBar
//

import CoreGraphics
import Foundation

/// Serial, bounded access to the recyclable offscreen capture helper.
actor MenuBarCaptureServiceConnection {
    static let shared = MenuBarCaptureServiceConnection()

    private struct ValidatedResponse {
        let response: MenuBarCaptureService.Response
        let frames: [MenuBarCaptureService.Frame]
    }

    private struct RequestWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var completed = false

        func install(_ continuation: CheckedContinuation<Data?, Never>) {
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func complete(with data: Data?) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: data)
        }
    }

    private let logger = Logger(category: "MenuBarCaptureService.Connection")
    private var connection: NSXPCConnection?
    private var connectionGeneration: UInt64 = 0
    private var serviceInstanceID: UUID?
    private var requestID: UInt64 = 0
    private var connectionEndWaiters = [
        UInt64: [CheckedContinuation<Void, Never>]
    ]()

    // Actors are reentrant across awaits, so an explicit gate keeps requests
    // serialized for the helper and makes retry/recycle ordering deterministic.
    private var isRequestInFlight = false
    private var requestWaiters = [RequestWaiter]()

    func verifyServiceConnection() async -> Bool {
        guard await acquireRequestSlot() else {
            return false
        }
        defer { releaseRequestSlot() }

        let request = MenuBarCaptureService.Request(
            version: MenuBarCaptureService.protocolVersion,
            requestID: nextRequestID(),
            windows: [],
            optionRawValue: 0,
            expectedScale: 1
        )
        guard let result = await send(request) else {
            return false
        }
        serviceInstanceID = result.response.serviceInstanceID
        return result.frames.isEmpty &&
            MenuBarCaptureService.responseDisposition(
                result.response,
                expectedServiceInstanceID: nil
            ) == .accept
    }

    func capture(
        windows: [MenuBarCaptureService.Window],
        expectedScale: CGFloat,
        option: CGWindowImageOption
    ) async -> [MenuBarCaptureService.Frame] {
        let chunks = MenuBarCaptureService.requestChunks(windows)
        guard
            !chunks.isEmpty,
            MenuBarCaptureService.isValidScale(Double(expectedScale))
        else {
            return []
        }

        guard await acquireRequestSlot() else {
            return []
        }
        defer { releaseRequestSlot() }
        guard !Task.isCancelled else {
            return []
        }

        var frames = [MenuBarCaptureService.Frame]()
        for chunk in chunks {
            guard !Task.isCancelled else {
                return []
            }
            if let chunkFrames = await captureChunk(
                chunk,
                expectedScale: expectedScale,
                option: option
            ) {
                frames += chunkFrames
            }
        }
        let orderedWindowIDs = chunks.flatMap {
            $0.map(\.windowID)
        }
        return MenuBarCaptureService.mergedUniqueFrames(
            frames,
            orderedWindowIDs: orderedWindowIDs
        )
    }

    private func captureChunk(
        _ windows: [MenuBarCaptureService.Window],
        expectedScale: CGFloat,
        option: CGWindowImageOption
    ) async -> [MenuBarCaptureService.Frame]? {
        var failedAttempts = 0
        var recycleAttempts = 0
        while failedAttempts < 2, recycleAttempts < 3 {
            let request = MenuBarCaptureService.Request(
                version: MenuBarCaptureService.protocolVersion,
                requestID: nextRequestID(),
                windows: windows,
                optionRawValue: option.rawValue,
                expectedScale: Double(expectedScale)
            )
            guard let result = await send(request) else {
                guard !Task.isCancelled else {
                    return nil
                }
                failedAttempts += 1
                await invalidateConnectionAndWait()
                guard failedAttempts < 2 else {
                    break
                }
                logger.warning("Capture helper request failed; retrying once")
                continue
            }

            let disposition = MenuBarCaptureService.responseDisposition(
                result.response,
                expectedServiceInstanceID: serviceInstanceID
            )
            guard disposition != .reject else {
                failedAttempts += 1
                await invalidateConnectionAndWait()
                continue
            }
            serviceInstanceID = result.response.serviceInstanceID
            if disposition == .acceptAndRecycle {
                retireConnection()
                return Task.isCancelled ? nil : result.frames
            }
            if disposition == .retryAfterRecycle {
                await connectToReplacementService(
                    retiringInstanceID: result.response.serviceInstanceID
                )
            }
            if disposition == .accept {
                return Task.isCancelled ? nil : result.frames
            }
            recycleAttempts += 1
        }
        return nil
    }

    private func connectToReplacementService(
        retiringInstanceID: UUID
    ) async {
        await invalidateConnectionAndWait()

        for _ in 0 ..< 3 where !Task.isCancelled {
            let request = MenuBarCaptureService.Request(
                version: MenuBarCaptureService.protocolVersion,
                requestID: nextRequestID(),
                windows: [],
                optionRawValue: 0,
                expectedScale: 1
            )
            if
                let result = await send(request),
                result.response.serviceInstanceID != retiringInstanceID,
                MenuBarCaptureService.responseDisposition(
                    result.response,
                    expectedServiceInstanceID: nil
                ) == .accept
            {
                serviceInstanceID = result.response.serviceInstanceID
                return
            }
            await invalidateConnectionAndWait()
        }
        logger.warning("Capture helper replacement did not become ready")
    }

    private func acquireRequestSlot() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        if !isRequestInFlight {
            isRequestInFlight = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                requestWaiters.append(RequestWaiter(
                    id: waiterID,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task {
                await self.cancelRequestWaiter(waiterID)
            }
        }
    }

    private func releaseRequestSlot() {
        if requestWaiters.isEmpty {
            isRequestInFlight = false
        } else {
            requestWaiters.removeFirst().continuation.resume(
                returning: true
            )
        }
    }

    private func cancelRequestWaiter(_ waiterID: UUID) {
        guard let index = requestWaiters.firstIndex(where: {
            $0.id == waiterID
        }) else {
            return
        }
        requestWaiters.remove(at: index).continuation.resume(
            returning: false
        )
    }

    private func nextRequestID() -> UInt64 {
        requestID &+= 1
        return requestID
    }

    private func send(
        _ request: MenuBarCaptureService.Request
    ) async -> ValidatedResponse? {
        guard
            MenuBarCaptureService.isValidRequest(request),
            let requestData = try? JSONEncoder().encode(request),
            requestData.count <= MenuBarCaptureService.maximumRequestBytes
        else {
            logger.error("Refused to send an invalid capture request")
            return nil
        }

        let replyBox = ReplyBox()
        let responseData = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                replyBox.install(continuation)
                guard !Task.isCancelled else {
                    replyBox.complete(with: nil)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + 5
                ) {
                    replyBox.complete(with: nil)
                }

                let proxy = serviceConnection()
                    .remoteObjectProxyWithErrorHandler { error in
                        self.logger.error(
                            "Capture helper request failed: \(error.localizedDescription)"
                        )
                        replyBox.complete(with: nil)
                    }
                guard let service = proxy as? MenuBarCaptureServiceProtocol else {
                    logger.error("Capture helper proxy has an unexpected type")
                    replyBox.complete(with: nil)
                    return
                }
                service.captureMenuBarItems(requestData) { data in
                    replyBox.complete(with: data)
                }
            }
        } onCancel: {
            replyBox.complete(with: nil)
        }

        guard
            let responseData,
            responseData.count <=
                MenuBarCaptureService.maximumBytesPerBatch * 2 +
                MenuBarCaptureService.maximumRequestBytes,
            let response = try? JSONDecoder().decode(
                MenuBarCaptureService.Response.self,
                from: responseData
            ),
            let frames = MenuBarCaptureService.validatedFrames(
                in: response,
                for: request
            )
        else {
            return nil
        }
        return ValidatedResponse(response: response, frames: frames)
    }

    private func serviceConnection() -> NSXPCConnection {
        if let connection {
            return connection
        }

        connectionGeneration &+= 1
        let generation = connectionGeneration
        let newConnection = NSXPCConnection(
            serviceName: MenuBarCaptureService.name
        )
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: MenuBarCaptureServiceProtocol.self
        )
        newConnection.interruptionHandler = { [weak self] in
            Task {
                await self?.connectionDidEnd(generation: generation)
            }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task {
                await self?.connectionDidEnd(generation: generation)
            }
        }
        newConnection.resume()
        connection = newConnection
        serviceInstanceID = nil
        return newConnection
    }

    private func connectionDidEnd(generation: UInt64) {
        guard connectionGeneration == generation else {
            resumeConnectionEndWaiters(generation: generation)
            return
        }
        connection = nil
        serviceInstanceID = nil
        resumeConnectionEndWaiters(generation: generation)
    }

    private func invalidateConnectionAndWait() async {
        guard let oldConnection = connection else {
            serviceInstanceID = nil
            return
        }
        let generation = connectionGeneration
        connection = nil
        serviceInstanceID = nil

        await withCheckedContinuation { continuation in
            connectionEndWaiters[generation, default: []].append(continuation)
            oldConnection.invalidate()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.connectionDidEnd(generation: generation)
            }
        }
    }

    private func retireConnection() {
        let oldConnection = connection
        connection = nil
        serviceInstanceID = nil
        oldConnection?.invalidate()
    }

    private func resumeConnectionEndWaiters(generation: UInt64) {
        let waiters = connectionEndWaiters.removeValue(
            forKey: generation
        ) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
