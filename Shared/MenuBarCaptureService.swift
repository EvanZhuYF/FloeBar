//
//  MenuBarCaptureService.swift
//  FloeBar
//

import CoreGraphics
import Foundation

/// Shared JSON vocabulary and validation for offscreen menu bar capture.
enum MenuBarCaptureService {
    static let name = "com.evanzhu.FloeBar.MenuBarCaptureService"
    static let protocolVersion = 2

    static let maximumRequestBytes = 512 * 1024
    static let maximumWindowCount = 64
    static let maximumDimension = 16_384
    static let maximumBytesPerFrame = 4 * 1_024 * 1_024
    static let maximumBytesPerBatch = 16 * 1_024 * 1_024
    static let recycleAfterSuccessfulCaptureCount = 64
    static let minimumScale = 0.5
    static let maximumScale = 4.0

    static let bgraBitmapInfo: UInt32 =
        CGImageAlphaInfo.premultipliedFirst.rawValue |
        CGBitmapInfo.byteOrder32Little.rawValue

    private static let allowedImageOptionRawValue =
        CGWindowImageOption.boundsIgnoreFraming.rawValue |
        CGWindowImageOption.bestResolution.rawValue |
        CGWindowImageOption.nominalResolution.rawValue

    struct Window: Codable, Hashable {
        private static let unitsPerPoint = 8.0

        let windowID: CGWindowID
        let ownerPID: pid_t
        let title: String?
        let layer: Int
        let minX: Int64
        let minY: Int64
        let width: Int64
        let height: Int64

        init?(
            windowID: CGWindowID,
            ownerPID: pid_t,
            title: String?,
            layer: Int,
            bounds: CGRect
        ) {
            guard
                windowID != 0,
                ownerPID > 0,
                let minX = Self.units(bounds.minX),
                let minY = Self.units(bounds.minY),
                let width = Self.units(bounds.width),
                let height = Self.units(bounds.height),
                width > 0,
                height > 0
            else {
                return nil
            }
            self.windowID = windowID
            self.ownerPID = ownerPID
            self.title = title
            self.layer = layer
            self.minX = minX
            self.minY = minY
            self.width = width
            self.height = height
        }

        var bounds: CGRect {
            CGRect(
                x: Double(minX) / Self.unitsPerPoint,
                y: Double(minY) / Self.unitsPerPoint,
                width: Double(width) / Self.unitsPerPoint,
                height: Double(height) / Self.unitsPerPoint
            )
        }

        func matches(
            windowID: CGWindowID,
            ownerPID: pid_t,
            title: String?,
            layer: Int,
            bounds: CGRect
        ) -> Bool {
            guard let liveWindow = Self(
                windowID: windowID,
                ownerPID: ownerPID,
                title: title,
                layer: layer,
                bounds: bounds
            ) else {
                return false
            }
            return self == liveWindow
        }

        private static func units(_ value: CGFloat) -> Int64? {
            let scaled = Double(value) * unitsPerPoint
            guard
                scaled.isFinite,
                scaled >= Double(Int64.min),
                scaled <= Double(Int64.max)
            else {
                return nil
            }
            return Int64(scaled.rounded())
        }
    }

    struct Request: Codable, Equatable {
        let version: Int
        let requestID: UInt64
        let windows: [Window]
        let optionRawValue: UInt32
        let expectedScale: Double

        var windowIDs: [CGWindowID] {
            windows.map(\.windowID)
        }
    }

    struct Frame: Codable, Equatable {
        let windowID: CGWindowID
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixelScale: Double
        let pixels: Data
    }

    struct Response: Codable, Equatable {
        let version: Int
        let requestID: UInt64
        let serviceInstanceID: UUID
        let didProcessRequest: Bool
        let recycleAfterReply: Bool
        let frames: [Frame]
    }

    enum ResponseDisposition: Equatable {
        case accept
        case acceptAndRecycle
        case retryAfterRecycle
        case reject
    }

    static func validatedWindows(_ windows: [Window]) -> [Window]? {
        guard windows.count <= maximumWindowCount else {
            return nil
        }
        var seen = Set<CGWindowID>()
        return windows.filter { window in
            isValidWindow(window) && seen.insert(window.windowID).inserted
        }
    }

    static func requestChunks(_ windows: [Window]) -> [[Window]] {
        var seen = Set<CGWindowID>()
        let normalized = windows.filter {
            isValidWindow($0) && seen.insert($0.windowID).inserted
        }
        guard !normalized.isEmpty else {
            return []
        }
        return stride(
            from: 0,
            to: normalized.count,
            by: maximumWindowCount
        ).map { start in
            Array(
                normalized[
                    start ..< min(start + maximumWindowCount, normalized.count)
                ]
            )
        }
    }

    static func mergedUniqueFrames(
        _ frames: [Frame],
        orderedWindowIDs: [CGWindowID]
    ) -> [Frame] {
        var framesByID = [CGWindowID: Frame]()
        for frame in frames where framesByID[frame.windowID] == nil {
            framesByID[frame.windowID] = frame
        }
        return orderedWindowIDs.compactMap { framesByID[$0] }
    }

    static func responseDisposition(
        _ response: Response,
        expectedServiceInstanceID: UUID?
    ) -> ResponseDisposition {
        if
            let expectedServiceInstanceID,
            response.serviceInstanceID != expectedServiceInstanceID
        {
            return .reject
        }
        if !response.didProcessRequest {
            return response.recycleAfterReply ? .retryAfterRecycle : .reject
        }
        return response.recycleAfterReply ? .acceptAndRecycle : .accept
    }

    static func isValidScale(_ scale: Double) -> Bool {
        scale.isFinite && scale >= minimumScale && scale <= maximumScale
    }

    static func isValidRequest(_ request: Request) -> Bool {
        request.version == protocolVersion &&
            validatedWindows(request.windows)?.count == request.windows.count &&
            isValidScale(request.expectedScale) &&
            request.optionRawValue & ~allowedImageOptionRawValue == 0
    }

    static func isValidWindow(_ window: Window) -> Bool {
        window.windowID != 0 &&
            window.ownerPID > 0 &&
            window.layer == Int(kCGStatusWindowLevel) &&
            window.width > 0 &&
            window.height > 0 &&
            window.width <= Int64(maximumDimension * 8) &&
            window.height <= Int64(maximumDimension * 8)
    }

    static func isValidCaptureBounds(_ bounds: CGRect, scale: CGFloat) -> Bool {
        guard
            scale.isFinite,
            Double(scale) >= minimumScale,
            Double(scale) <= maximumScale,
            !bounds.isNull,
            !bounds.isInfinite,
            bounds.origin.x.isFinite,
            bounds.origin.y.isFinite,
            bounds.width.isFinite,
            bounds.height.isFinite,
            bounds.width > 0,
            bounds.height > 0
        else {
            return false
        }
        let pixelWidth = bounds.width * scale
        let pixelHeight = bounds.height * scale
        let pixelBytes = pixelWidth * pixelHeight * 4
        return pixelWidth > 0 &&
            pixelHeight > 0 &&
            pixelWidth <= CGFloat(maximumDimension) &&
            pixelHeight <= CGFloat(maximumDimension) &&
            pixelBytes.isFinite &&
            pixelBytes <= CGFloat(maximumBytesPerBatch)
    }

    static func isValidFrame(_ frame: Frame) -> Bool {
        guard
            frame.width > 0,
            frame.height > 0,
            frame.width <= maximumDimension,
            frame.height <= maximumDimension,
            isValidScale(frame.pixelScale)
        else {
            return false
        }
        let (minimumBytesPerRow, strideOverflow) =
            frame.width.multipliedReportingOverflow(by: 4)
        guard
            !strideOverflow,
            frame.bytesPerRow >= minimumBytesPerRow
        else {
            return false
        }
        let (expectedBytes, byteCountOverflow) =
            frame.bytesPerRow.multipliedReportingOverflow(by: frame.height)
        return !byteCountOverflow &&
            expectedBytes == frame.pixels.count &&
            expectedBytes <= maximumBytesPerFrame
    }

    static func validatedFrames(
        in response: Response,
        for request: Request
    ) -> [Frame]? {
        guard
            response.version == protocolVersion,
            response.requestID == request.requestID,
            response.didProcessRequest || response.recycleAfterReply,
            response.didProcessRequest || response.frames.isEmpty,
            response.frames.count <= maximumWindowCount
        else {
            return nil
        }

        let requestedWindowIDs = Set(request.windowIDs)
        var seen = Set<CGWindowID>()
        var totalBytes = 0
        for frame in response.frames {
            guard
                requestedWindowIDs.contains(frame.windowID),
                seen.insert(frame.windowID).inserted,
                isValidFrame(frame)
            else {
                return nil
            }
            let (nextTotal, overflow) =
                totalBytes.addingReportingOverflow(frame.pixels.count)
            guard !overflow, nextTotal <= maximumBytesPerBatch else {
                return nil
            }
            totalBytes = nextTotal
        }
        return response.frames
    }

    static func encodeBGRA(_ image: CGImage) -> (pixels: Data, bytesPerRow: Int)? {
        let (minimumRowBytes, rowOverflow) =
            image.width.multipliedReportingOverflow(by: 4)
        let (minimumByteCount, byteCountOverflow) =
            minimumRowBytes.multipliedReportingOverflow(by: image.height)
        guard
            !rowOverflow,
            !byteCountOverflow,
            minimumByteCount <= maximumBytesPerFrame,
            image.width > 0,
            image.height > 0,
            image.width <= maximumDimension,
            image.height <= maximumDimension,
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bgraBitmapInfo
            ),
            let dataPointer = context.data
        else {
            return nil
        }
        let (byteCount, overflow) =
            context.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard
            !overflow,
            byteCount > 0,
            byteCount <= maximumBytesPerFrame
        else {
            return nil
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return (
            Data(bytes: dataPointer, count: byteCount),
            context.bytesPerRow
        )
    }

    static func makeImage(from frame: Frame) -> CGImage? {
        guard
            isValidFrame(frame),
            let provider = CGDataProvider(data: frame.pixels as CFData)
        else {
            return nil
        }
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bgraBitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// The service accepts only explicitly encoded data, avoiding an arbitrary
/// Objective-C object graph at the XPC boundary.
@objc(FloeBarMenuBarCaptureServiceProtocol)
protocol MenuBarCaptureServiceProtocol {
    func captureMenuBarItems(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    )
}
