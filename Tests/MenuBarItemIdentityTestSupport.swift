import Cocoa

// Controlled OS boundaries. Item construction, identity, matching, display
// filtering, and persistence come from the production sources.
final class NSRunningApplication {
    static var bundles: [pid_t: String] = [
        10: "com.apple.controlcenter",
        100: "test.application",
        200: "other.application",
    ]
    static var launchDates: [pid_t: Date] = [
        10: Date(timeIntervalSince1970: 10),
        100: Date(timeIntervalSince1970: 100),
        200: Date(timeIntervalSince1970: 200),
    ]
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    var localizedName: String? { bundleIdentifier }
    var launchDate: Date? { Self.launchDates[processIdentifier] }

    init?(processIdentifier: pid_t) {
        guard let bundle = Self.bundles[processIdentifier] else { return nil }
        self.processIdentifier = processIdentifier
        bundleIdentifier = bundle
    }
}

struct WindowInfo: Hashable {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String?
    let layer: Int
    let ownerPID: pid_t
    let isOnScreen: Bool
    var ownerName: String? { "Fixture" }
    var owningApplication: NSRunningApplication? { .init(processIdentifier: ownerPID) }
    var isMenuBarItem: Bool { true }

    init(
        _ id: CGWindowID,
        title: String = "Icon",
        ownerPID: pid_t = 100,
        x: CGFloat = 100,
        y: CGFloat = 0,
        width: CGFloat = 24,
        height: CGFloat = 24,
        layer: Int = Int(kCGStatusWindowLevel),
        onScreen: Bool = true
    ) {
        windowID = id
        self.title = title
        self.layer = layer
        self.ownerPID = ownerPID
        frame = CGRect(x: x, y: y, width: width, height: height)
        isOnScreen = onScreen
    }

    init?(windowID: CGWindowID) { return nil }
    static func createWindows(from ids: [CGWindowID]) -> [WindowInfo] { [] }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(NSStringFromRect(frame))
        hasher.combine(title)
        hasher.combine(layer)
        hasher.combine(ownerPID)
        hasher.combine(isOnScreen)
    }
}

final class MenuBarItemSourcePIDCache {
    static let shared = MenuBarItemSourcePIDCache()
    var sources: [CGWindowID: pid_t] = [:]
    func sourcePID(for window: WindowInfo) -> pid_t? { sources[window.windowID] }
}

enum Bridging {
    struct WindowListOption: OptionSet {
        let rawValue: Int
        static let menuBarItems = Self(rawValue: 1)
        static let onScreen = Self(rawValue: 2)
        static let activeSpace = Self(rawValue: 4)
    }
    static var activeMenuBarDisplayID: CGDirectDisplayID? { nil }
    static func getWindowList(option: WindowListOption) -> [CGWindowID] { [] }
    static func isWindow(_ id: CGWindowID, onCurrentSpaceOf display: CGDirectDisplayID) -> Bool { false }
}

enum ControlItem {
    enum Identifier: String {
        case iceIcon, hidden, alwaysHidden
        init?(recognizedTitle: String) { self.init(rawValue: recognizedTitle) }
    }
}

enum Constants {
    static let bundleIdentifier = "test.floebar"
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
