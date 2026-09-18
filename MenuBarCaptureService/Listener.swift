//
//  Listener.swift
//  FloeBar
//

import CoreGraphics
import Foundation
import OSLog

private final class MenuBarCaptureServiceObject: NSObject, MenuBarCaptureServiceProtocol {
    private struct LiveWindow {
        let windowID: CGWindowID
        let bounds: CGRect
    }

    private struct CaptureResult {
        let frames: [MenuBarCaptureService.Frame]
        let didCaptureComposite: Bool
    }

    private let queue = DispatchQueue(
        label: "com.evanzhu.FloeBar.MenuBarCaptureService.capture",
        qos: .userInitiated
    )
    private let logger = os.Logger(
        subsystem: "com.evanzhu.FloeBar",
        category: "MenuBarCaptureService"
    )
    private let instanceID = UUID()
    private var successfulCaptureCount = 0
    private var isExitScheduled = false

    func captureMenuBarItems(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        queue.async {
            guard !self.isExitScheduled else {
                reply(self.recycleResponseData(for: requestData))
                return
            }
            guard let result = autoreleasepool(invoking: {
                self.handle(requestData)
            }) else {
                reply(nil)
                return
            }
            if result.didCaptureComposite {
                self.successfulCaptureCount += 1
            }
            let shouldRecycle =
                self.successfulCaptureCount >=
                MenuBarCaptureService.recycleAfterSuccessfulCaptureCount
            if shouldRecycle && !self.isExitScheduled {
                self.isExitScheduled = true
            }
            let response = MenuBarCaptureService.Response(
                version: MenuBarCaptureService.protocolVersion,
                requestID: result.requestID,
                serviceInstanceID: self.instanceID,
                didProcessRequest: true,
                recycleAfterReply: shouldRecycle,
                frames: result.frames
            )
            reply(try? JSONEncoder().encode(response))

            // The reply has been handed to NSXPC. Retire on the next main-loop
            // turn and let the client wait for connection invalidation.
            if shouldRecycle {
                DispatchQueue.main.async {
                    exit(EXIT_SUCCESS)
                }
            }
        }
    }

    private func handle(
        _ requestData: Data
    ) -> (
        requestID: UInt64,
        frames: [MenuBarCaptureService.Frame],
        didCaptureComposite: Bool
    )? {
        do {
            guard requestData.count <= MenuBarCaptureService.maximumRequestBytes else {
                logger.error("Rejected oversized capture request")
                return nil
            }
            let request = try JSONDecoder().decode(
                MenuBarCaptureService.Request.self,
                from: requestData
            )
            guard
                MenuBarCaptureService.isValidRequest(request),
                let windows = MenuBarCaptureService.validatedWindows(
                    request.windows
                )
            else {
                logger.error("Rejected invalid capture request")
                return nil
            }

            let captureResult = capture(
                windows: windows,
                expectedScale: request.expectedScale,
                optionRawValue: request.optionRawValue
            )
            return (
                requestID: request.requestID,
                frames: captureResult.frames,
                didCaptureComposite: captureResult.didCaptureComposite
            )
        } catch {
            logger.error(
                "Capture request failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func recycleResponseData(for requestData: Data) -> Data? {
        guard
            requestData.count <= MenuBarCaptureService.maximumRequestBytes,
            let request = try? JSONDecoder().decode(
                MenuBarCaptureService.Request.self,
                from: requestData
            ),
            MenuBarCaptureService.isValidRequest(request)
        else {
            return nil
        }
        let response = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: request.requestID,
            serviceInstanceID: instanceID,
            didProcessRequest: false,
            recycleAfterReply: true,
            frames: []
        )
        return try? JSONEncoder().encode(response)
    }

    private func capture(
        windows: [MenuBarCaptureService.Window],
        expectedScale: Double,
        optionRawValue: UInt32
    ) -> CaptureResult {
        guard !windows.isEmpty else {
            return CaptureResult(frames: [], didCaptureComposite: false)
        }

        let scale = CGFloat(expectedScale)
        let liveWindows = liveStatusWindows(
            requestedWindows: windows,
            expectedScale: scale
        )
        guard !liveWindows.isEmpty else {
            return CaptureResult(frames: [], didCaptureComposite: false)
        }

        let boundsUnion = liveWindows.reduce(CGRect.null) {
            $0.union($1.bounds)
        }
        guard MenuBarCaptureService.isValidCaptureBounds(
            boundsUnion,
            scale: scale
        ) else {
            return CaptureResult(frames: [], didCaptureComposite: false)
        }

        let acceptedWindowIDs = liveWindows.map(\.windowID)
        guard
            let windowArray = makeWindowArray(acceptedWindowIDs),
            let composite = CGImage(
                windowListFromArrayScreenBounds: .null,
                windowArray: windowArray,
                imageOption: CGWindowImageOption(rawValue: optionRawValue)
            )
        else {
            return CaptureResult(frames: [], didCaptureComposite: false)
        }
        guard
            composite.width > 0,
            composite.height > 0,
            composite.width <= MenuBarCaptureService.maximumDimension,
            composite.height <= MenuBarCaptureService.maximumDimension
        else {
            return CaptureResult(frames: [], didCaptureComposite: true)
        }

        let pixelScale = CGFloat(composite.width) / boundsUnion.width
        let expectedPixelHeight = boundsUnion.height * pixelScale
        guard
            MenuBarCaptureService.isValidScale(Double(pixelScale)),
            abs(CGFloat(composite.height) - expectedPixelHeight) <=
                max(2, pixelScale)
        else {
            logger.error("Rejected capture with inconsistent pixel scale")
            return CaptureResult(frames: [], didCaptureComposite: true)
        }

        var frames = [MenuBarCaptureService.Frame]()
        var batchBytes = 0
        for window in liveWindows {
            let cropRect = CGRect(
                x: (window.bounds.minX - boundsUnion.minX) * pixelScale,
                y: (window.bounds.minY - boundsUnion.minY) * pixelScale,
                width: window.bounds.width * pixelScale,
                height: window.bounds.height * pixelScale
            )
            guard
                let cropped = composite.cropping(to: cropRect),
                let encoded = MenuBarCaptureService.encodeBGRA(cropped)
            else {
                continue
            }
            let (nextBatchBytes, overflow) =
                batchBytes.addingReportingOverflow(encoded.pixels.count)
            guard
                !overflow,
                nextBatchBytes <= MenuBarCaptureService.maximumBytesPerBatch
            else {
                break
            }
            let frame = MenuBarCaptureService.Frame(
                windowID: window.windowID,
                width: cropped.width,
                height: cropped.height,
                bytesPerRow: encoded.bytesPerRow,
                pixelScale: Double(pixelScale),
                pixels: encoded.pixels
            )
            guard MenuBarCaptureService.isValidFrame(frame) else {
                continue
            }
            frames.append(frame)
            batchBytes = nextBatchBytes
        }
        return CaptureResult(frames: frames, didCaptureComposite: true)
    }

    /// Re-query WindowServer in the helper and authorize only live status-level
    /// windows whose full expected incarnation still matches.
    private func liveStatusWindows(
        requestedWindows: [MenuBarCaptureService.Window],
        expectedScale: CGFloat
    ) -> [LiveWindow] {
        let descriptions = WindowDescriptionQuery.descriptions(
            for: requestedWindows.map(\.windowID)
        )
        var windowsByID = [CGWindowID: LiveWindow]()
        for description in descriptions {
            guard
                let info = description as? [CFString: CFTypeRef],
                let windowID = info[kCGWindowNumber] as? CGWindowID,
                let expectedWindow = requestedWindows.first(where: {
                    $0.windowID == windowID
                }),
                let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                let layer = info[kCGWindowLayer] as? Int,
                layer == Int(kCGStatusWindowLevel),
                let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
                let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary
                ),
                MenuBarCaptureService.isValidCaptureBounds(
                    bounds,
                    scale: expectedScale
                ),
                expectedWindow.matches(
                    windowID: windowID,
                    ownerPID: ownerPID,
                    title: info[kCGWindowName] as? String,
                    layer: layer,
                    bounds: bounds
                )
            else {
                continue
            }
            windowsByID[windowID] = LiveWindow(
                windowID: windowID,
                bounds: bounds
            )
        }
        return requestedWindows.compactMap { windowsByID[$0.windowID] }
    }

    private func makeWindowArray(_ windowIDs: [CGWindowID]) -> CFArray? {
        var pointers = windowIDs.map {
            UnsafeRawPointer(bitPattern: UInt($0))
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            CFArrayCreate(
                kCFAllocatorDefault,
                buffer.baseAddress,
                buffer.count,
                nil
            )
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    static let shared = Listener()

    private let service = MenuBarCaptureServiceObject()

    private override init() {
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard newConnection.effectiveUserIdentifier == geteuid() else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(
            with: MenuBarCaptureServiceProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
