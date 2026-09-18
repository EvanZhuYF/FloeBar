import CoreGraphics
import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(
            domain: "MenuBarItemServiceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@main
private enum MenuBarItemServiceTests {
    static func main() throws {
        let window = MenuBarItemService.Window(
            windowID: 42,
            ownerPID: 100,
            minX: -4096,
            minY: 0,
            width: 38,
            height: 30,
            layer: 25,
            title: "Item-0",
            ownerName: "Control Center",
            isOnScreen: false
        )
        let request = MenuBarItemService.Request(
            version: MenuBarItemService.protocolVersion,
            windows: [window]
        )
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(
            MenuBarItemService.Request.self,
            from: requestData
        )
        try check(decodedRequest.version == 1, "Protocol version must round-trip")
        try check(decodedRequest.windows == [window], "Window payload must round-trip")

        let response = MenuBarItemService.Response(
            version: MenuBarItemService.protocolVersion,
            sourcePIDs: [1234, nil]
        )
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(
            MenuBarItemService.Response.self,
            from: responseData
        )
        try check(decodedResponse.sourcePIDs == [1234, nil], "Optional PIDs must round-trip")
        try check(MenuBarItemService.maximumWindowCount == 256, "Request size must remain bounded")

        print("PASS: menu bar item service protocol")
    }
}
