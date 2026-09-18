import CoreGraphics
import Foundation

private func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw NSError(
            domain: "MenuBarCaptureServicePolicyTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@main
private enum MenuBarCaptureServicePolicyTests {
    static func main() throws {
        try chunking()
        try responseLifecycle()
        print("PASS: menu bar capture connection policy")
    }

    private static func chunking() throws {
        let windows = (1 ... 65).map {
            window(CGWindowID($0))
        } + [window(1)]
        let chunks = MenuBarCaptureService.requestChunks(windows)
        try check(
            chunks.map(\.count) == [64, 1],
            "The connection must deduplicate then retain every chunk"
        )
        try check(
            chunks[1].first?.windowID == 65,
            "Window 65 must not be dropped at the chunk boundary"
        )
        let threeChunks = MenuBarCaptureService.requestChunks(
            (1 ... 130).map { window(CGWindowID($0)) }
        )
        try check(
            threeChunks.map(\.count) == [64, 64, 2] &&
                threeChunks.last?.last?.windowID == 130,
            "Every window must survive across multiple chunks"
        )

        let merged = MenuBarCaptureService.mergedUniqueFrames(
            [frame(2), frame(1), frame(2)],
            orderedWindowIDs: [1, 2]
        )
        try check(
            merged.map(\.windowID) == [1, 2],
            "Chunk responses must merge uniquely in request order"
        )
    }

    private static func responseLifecycle() throws {
        let instanceID = UUID()
        try check(
            disposition(
                instanceID: instanceID,
                didProcess: true,
                recycle: false
            ) == .accept,
            "A normal processed response must be accepted"
        )
        try check(
            disposition(
                instanceID: instanceID,
                didProcess: true,
                recycle: true
            ) == .acceptAndRecycle,
            "A boundary response must be accepted before recycling"
        )
        try check(
            disposition(
                instanceID: instanceID,
                didProcess: false,
                recycle: true
            ) == .retryAfterRecycle,
            "A retiring helper must preserve the request for retry"
        )
        try check(
            disposition(
                instanceID: UUID(),
                didProcess: true,
                recycle: false,
                expectedInstanceID: instanceID
            ) == .reject,
            "A response from another helper instance must be rejected"
        )
    }

    private static func disposition(
        instanceID: UUID,
        didProcess: Bool,
        recycle: Bool,
        expectedInstanceID: UUID? = nil
    ) -> MenuBarCaptureService.ResponseDisposition {
        let response = MenuBarCaptureService.Response(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 1,
            serviceInstanceID: instanceID,
            didProcessRequest: didProcess,
            recycleAfterReply: recycle,
            frames: []
        )
        return MenuBarCaptureService.responseDisposition(
            response,
            expectedServiceInstanceID: expectedInstanceID
        )
    }

    private static func window(
        _ windowID: CGWindowID
    ) -> MenuBarCaptureService.Window {
        MenuBarCaptureService.Window(
            windowID: windowID,
            ownerPID: 100,
            title: "Item-\(windowID)",
            layer: Int(kCGStatusWindowLevel),
            bounds: CGRect(x: CGFloat(windowID), y: 0, width: 24, height: 24)
        )!
    }

    private static func frame(
        _ windowID: CGWindowID
    ) -> MenuBarCaptureService.Frame {
        MenuBarCaptureService.Frame(
            windowID: windowID,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixelScale: 2,
            pixels: Data(repeating: 0, count: 4)
        )
    }
}
