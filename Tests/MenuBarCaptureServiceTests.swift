import CoreGraphics
import Foundation

private func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw NSError(
            domain: "MenuBarCaptureServiceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@main
private enum MenuBarCaptureServiceTests {
    static func main() throws {
        try requestRoundTrip()
        try requestValidation()
        try connectionPolicyValidation()
        try frameValidation()
        try responseValidation()
        try imageReconstruction()
        print("PASS: menu bar capture service protocol")
    }

    private static func requestRoundTrip() throws {
        let request = MenuBarCaptureService.Request(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 42,
            windows: [window(windowID: 11), window(windowID: 22)],
            optionRawValue: (
                CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
            ).rawValue,
            expectedScale: 2
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            MenuBarCaptureService.Request.self,
            from: data
        )
        try check(decoded == request, "Capture request must round-trip")
        try check(
            decoded.version == 2,
            "Capture protocol changes must use version 2"
        )
        try check(
            data.count <= MenuBarCaptureService.maximumRequestBytes,
            "Normal request must fit the wire limit"
        )
    }

    private static func requestValidation() throws {
        try check(
            MenuBarCaptureService.validatedWindows([
                window(windowID: 1),
                window(windowID: 1),
                window(windowID: 2),
            ]) == [window(windowID: 1), window(windowID: 2)],
            "Window validation must drop duplicate IDs"
        )
        let overflow = (1 ... 65).map {
            window(windowID: CGWindowID($0))
        }
        try check(
            MenuBarCaptureService.validatedWindows(overflow) == nil,
            "More than 64 input windows must be rejected"
        )
        try check(
            MenuBarCaptureService.isValidScale(0.5) &&
                MenuBarCaptureService.isValidScale(4),
            "Scale endpoints must be accepted"
        )
        try check(
            !MenuBarCaptureService.isValidScale(0.49) &&
                !MenuBarCaptureService.isValidScale(4.01) &&
                !MenuBarCaptureService.isValidScale(.infinity) &&
                !MenuBarCaptureService.isValidScale(.nan),
            "Invalid scales must be rejected"
        )
        try check(
            MenuBarCaptureService.recycleAfterSuccessfulCaptureCount == 64,
            "The helper recycle budget must remain bounded"
        )
        try check(
            MenuBarCaptureService.isValidCaptureBounds(
                CGRect(x: 0, y: 0, width: 2_000, height: 40),
                scale: 2
            ),
            "A normal wide menu bar batch must fit the capture budget"
        )
        try check(
            !MenuBarCaptureService.isValidCaptureBounds(
                CGRect(x: 0, y: 0, width: 8_000, height: 8_000),
                scale: 2
            ),
            "A large-area capture must be rejected before allocation"
        )

        let invalidOptions = MenuBarCaptureService.Request(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 1,
            windows: [],
            optionRawValue: UInt32.max,
            expectedScale: 2
        )
        try check(
            !MenuBarCaptureService.isValidRequest(invalidOptions),
            "Unknown image options must be rejected"
        )
        let expected = window(windowID: 5, title: "Item-0", x: -42.25)
        try check(
            expected.matches(
                windowID: 5,
                ownerPID: 100,
                title: "Item-0",
                layer: Int(kCGStatusWindowLevel),
                bounds: CGRect(x: -42.25, y: 0, width: 24, height: 24)
            ),
            "An exact quantized incarnation must match"
        )
        try check(
            !expected.matches(
                windowID: 5,
                ownerPID: 100,
                title: "Item-1",
                layer: Int(kCGStatusWindowLevel),
                bounds: CGRect(x: -42.25, y: 0, width: 24, height: 24)
            ),
            "A changed semantic title must reject a recycled window"
        )
    }

    private static func connectionPolicyValidation() throws {
        let windows = (1 ... 65).map {
            window(windowID: CGWindowID($0))
        } + [window(windowID: 1)]
        let chunks = MenuBarCaptureService.requestChunks(windows)
        try check(
            chunks.map(\.count) == [64, 1],
            "Capture policy must deduplicate then chunk all 65 windows"
        )
        try check(
            chunks[1].first?.windowID == 65,
            "The first window after the 64-window boundary must be retained"
        )

        let merged = MenuBarCaptureService.mergedUniqueFrames(
            [
                frame(windowID: 2),
                frame(windowID: 1),
                frame(windowID: 2),
            ],
            orderedWindowIDs: [1, 2]
        )
        try check(
            merged.map(\.windowID) == [1, 2],
            "Merged chunk frames must be unique and preserve request order"
        )
    }

    private static func frameValidation() throws {
        let valid = frame(windowID: 1)
        try check(
            MenuBarCaptureService.isValidFrame(valid),
            "A complete BGRA frame must be accepted"
        )
        let short = MenuBarCaptureService.Frame(
            windowID: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixelScale: 2,
            pixels: Data(repeating: 0, count: 15)
        )
        try check(
            !MenuBarCaptureService.isValidFrame(short),
            "Short frame data must be rejected"
        )
        let trailing = MenuBarCaptureService.Frame(
            windowID: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixelScale: 2,
            pixels: Data(repeating: 0, count: 17)
        )
        try check(
            !MenuBarCaptureService.isValidFrame(trailing),
            "Trailing frame data must be rejected"
        )
        let oversized = MenuBarCaptureService.Frame(
            windowID: 1,
            width: MenuBarCaptureService.maximumDimension + 1,
            height: 1,
            bytesPerRow: 4,
            pixelScale: 2,
            pixels: Data(repeating: 0, count: 4)
        )
        try check(
            !MenuBarCaptureService.isValidFrame(oversized),
            "Oversized dimensions must be rejected"
        )
    }

    private static func responseValidation() throws {
        let request = MenuBarCaptureService.Request(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 7,
            windows: [window(windowID: 1), window(windowID: 2)],
            optionRawValue: 0,
            expectedScale: 2
        )
        let response = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 7,
            serviceInstanceID: UUID(),
            didProcessRequest: true,
            recycleAfterReply: false,
            frames: [frame(windowID: 1), frame(windowID: 2)]
        )
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(
            MenuBarCaptureService.Response.self,
            from: responseData
        )
        try check(
            decodedResponse == response,
            "Capture response lifecycle metadata must round-trip"
        )
        try check(
            MenuBarCaptureService.validatedFrames(
                in: response,
                for: request
            ) == response.frames,
            "Valid response frames must be accepted"
        )
        let stale = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 8,
            serviceInstanceID: response.serviceInstanceID,
            didProcessRequest: true,
            recycleAfterReply: false,
            frames: []
        )
        try check(
            MenuBarCaptureService.validatedFrames(
                in: stale,
                for: request
            ) == nil,
            "A stale request ID must be rejected"
        )
        let duplicate = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 7,
            serviceInstanceID: response.serviceInstanceID,
            didProcessRequest: true,
            recycleAfterReply: false,
            frames: [frame(windowID: 1), frame(windowID: 1)]
        )
        try check(
            MenuBarCaptureService.validatedFrames(
                in: duplicate,
                for: request
            ) == nil,
            "Duplicate response frames must be rejected"
        )
        let foreign = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 7,
            serviceInstanceID: response.serviceInstanceID,
            didProcessRequest: true,
            recycleAfterReply: false,
            frames: [frame(windowID: 99)]
        )
        try check(
            MenuBarCaptureService.validatedFrames(
                in: foreign,
                for: request
            ) == nil,
            "Frames for unrequested windows must be rejected"
        )

        let paddedPixels = Data(
            repeating: 0,
            count: MenuBarCaptureService.maximumBytesPerFrame
        )
        let batchRequest = MenuBarCaptureService.Request(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 9,
            windows: (1 ... 5).map {
                window(windowID: CGWindowID($0))
            },
            optionRawValue: 0,
            expectedScale: 2
        )
        let oversizedBatch = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 9,
            serviceInstanceID: response.serviceInstanceID,
            didProcessRequest: true,
            recycleAfterReply: false,
            frames: batchRequest.windowIDs.map { windowID in
                MenuBarCaptureService.Frame(
                    windowID: windowID,
                    width: 1,
                    height: 1,
                    bytesPerRow: paddedPixels.count,
                    pixelScale: 2,
                    pixels: paddedPixels
                )
            }
        )
        try check(
            MenuBarCaptureService.validatedFrames(
                in: oversizedBatch,
                for: batchRequest
            ) == nil,
            "More than 16 MB of frame data must be rejected"
        )

        let retryAfterRecycle = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: request.requestID,
            serviceInstanceID: response.serviceInstanceID,
            didProcessRequest: false,
            recycleAfterReply: true,
            frames: []
        )
        try check(
            MenuBarCaptureService.validatedFrames(
                in: retryAfterRecycle,
                for: request
            ) == [],
            "An unprocessed recycle response must be accepted for retry"
        )
        let invalidUnprocessed = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: request.requestID,
            serviceInstanceID: response.serviceInstanceID,
            didProcessRequest: false,
            recycleAfterReply: false,
            frames: []
        )
        try check(
            MenuBarCaptureService.validatedFrames(
                in: invalidUnprocessed,
                for: request
            ) == nil,
            "An unprocessed response must require helper recycling"
        )
    }

    private static func imageReconstruction() throws {
        guard let image = MenuBarCaptureService.makeImage(from: frame(windowID: 1)) else {
            throw NSError(
                domain: "MenuBarCaptureServiceTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Valid BGRA frame did not create an image"]
            )
        }
        try check(
            image.width == 2 && image.height == 2,
            "Reconstructed image dimensions must match the frame"
        )
    }

    private static func frame(
        windowID: CGWindowID
    ) -> MenuBarCaptureService.Frame {
        MenuBarCaptureService.Frame(
            windowID: windowID,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixelScale: 2,
            pixels: Data(repeating: 255, count: 16)
        )
    }

    private static func window(
        windowID: CGWindowID,
        title: String? = "Item-0",
        x: CGFloat = 0
    ) -> MenuBarCaptureService.Window {
        MenuBarCaptureService.Window(
            windowID: windowID,
            ownerPID: 100,
            title: title,
            layer: Int(kCGStatusWindowLevel),
            bounds: CGRect(x: x, y: 0, width: 24, height: 24)
        )!
    }
}
