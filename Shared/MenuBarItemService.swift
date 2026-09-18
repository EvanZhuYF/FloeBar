//
//  MenuBarItemService.swift
//  FloeBar
//

import CoreGraphics
import Foundation

/// Shared XPC vocabulary for resolving the application that created each
/// menu bar item window on macOS 26.
enum MenuBarItemService {
    static let name = "com.evanzhu.FloeBar.MenuBarItemService"
    static let protocolVersion = 1
    static let maximumWindowCount = 256

    struct Window: Codable, Hashable {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let minX: Double
        let minY: Double
        let width: Double
        let height: Double
        let layer: Int
        let title: String?
        let ownerName: String?
        let isOnScreen: Bool

        var frame: CGRect {
            CGRect(x: minX, y: minY, width: width, height: height)
        }
    }

    struct Request: Codable {
        let version: Int
        let windows: [Window]
    }

    struct Response: Codable {
        let version: Int
        let sourcePIDs: [pid_t?]
    }
}

/// The service exposes one bounded, read-only operation. Data is encoded
/// explicitly so the XPC object graph cannot instantiate arbitrary classes.
@objc(FloeBarMenuBarItemServiceProtocol)
protocol MenuBarItemServiceProtocol {
    func resolveSourcePIDs(_ requestData: Data, withReply reply: @escaping (Data?) -> Void)
}
