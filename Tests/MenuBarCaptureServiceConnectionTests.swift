import CoreGraphics
import Foundation

@main
private enum MenuBarCaptureServiceConnectionTests {
    static func main() throws {
        let connection = NSXPCConnection(
            serviceName: MenuBarCaptureService.name
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: MenuBarCaptureServiceProtocol.self
        )
        connection.resume()

        let request = MenuBarCaptureService.Request(
            version: MenuBarCaptureService.protocolVersion,
            requestID: 0xF10E,
            windows: [],
            optionRawValue: (
                CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
            ).rawValue,
            expectedScale: 2
        )
        let requestData = try JSONEncoder().encode(request)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            fputs("FAIL: capture XPC discovery/connection: \(error)\n", stderr)
            exit(1)
        }
        guard let service = proxy as? MenuBarCaptureServiceProtocol else {
            fputs("FAIL: capture XPC proxy has an unexpected type\n", stderr)
            exit(1)
        }

        // An empty batch exercises the packaged service without invoking any
        // screen capture API or requiring Screen Recording permission.
        service.captureMenuBarItems(requestData) { data in
            guard
                let data,
                let response = try? JSONDecoder().decode(
                    MenuBarCaptureService.Response.self,
                    from: data
                ),
                response.version == MenuBarCaptureService.protocolVersion,
                response.requestID == request.requestID,
                response.didProcessRequest,
                !response.recycleAfterReply,
                response.frames.isEmpty
            else {
                fputs("FAIL: invalid capture XPC reply\n", stderr)
                exit(1)
            }
            print("PASS: embedded capture XPC permission-free round trip")
            connection.invalidate()
            exit(0)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("FAIL: capture XPC request timed out\n", stderr)
            exit(1)
        }
        RunLoop.current.run()
    }
}
