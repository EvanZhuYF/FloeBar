//
//  Listener.swift
//  FloeBar
//

import Foundation
import OSLog

private final class MenuBarItemServiceObject: NSObject, MenuBarItemServiceProtocol {
    private let queue = DispatchQueue(
        label: "com.evanzhu.FloeBar.MenuBarItemService.resolve",
        qos: .userInitiated
    )
    private let logger = os.Logger(
        subsystem: "com.evanzhu.FloeBar",
        category: "MenuBarItemService"
    )

    func resolveSourcePIDs(_ requestData: Data, withReply reply: @escaping (Data?) -> Void) {
        queue.async {
            let responseData = autoreleasepool { () -> Data? in
                do {
                    guard requestData.count <= 512 * 1024 else {
                        self.logger.error("Rejected oversized source PID request")
                        return nil
                    }
                    let request = try JSONDecoder().decode(
                        MenuBarItemService.Request.self,
                        from: requestData
                    )
                    guard
                        request.version == MenuBarItemService.protocolVersion,
                        request.windows.count <= MenuBarItemService.maximumWindowCount
                    else {
                        self.logger.error("Rejected invalid source PID request")
                        return nil
                    }
                    let response = MenuBarItemService.Response(
                        version: MenuBarItemService.protocolVersion,
                        sourcePIDs: SourcePIDResolver.shared.resolve(request.windows)
                    )
                    return try JSONEncoder().encode(response)
                } catch {
                    self.logger.error(
                        "Failed to resolve source PIDs: \(error.localizedDescription, privacy: .public)"
                    )
                    return nil
                }
            }
            reply(responseData)
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    static let shared = Listener()

    private let service = MenuBarItemServiceObject()

    private override init() {
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // The service is embedded in FloeBar and exposes one bounded,
        // read-only operation. Self-signed builds do not have a TeamIdentifier,
        // so same-team validation is unavailable.
        guard newConnection.effectiveUserIdentifier == geteuid() else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(
            with: MenuBarItemServiceProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
