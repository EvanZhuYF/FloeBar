import Cocoa
import OSLog

struct WindowInfo {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String?
    let layer: Int
    let ownerPID: pid_t
    let ownerName: String?
    let isOnScreen: Bool

    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    var isMenuBarItem: Bool {
        layer == Int(kCGStatusWindowLevel)
    }
}

enum MenuBarItemInfo {
    enum Namespace: String {
        case controlCenter = "com.apple.controlcenter"
    }

    static func isControlCenterModuleTitle(_ title: String) -> Bool {
        false
    }
}

enum ControlItem {
    enum Identifier {
        static func isRecognizedTitle(_ title: String) -> Bool {
            false
        }
    }
}

extension Logger {
    init(category: String) {
        self.init(subsystem: "com.evanzhu.FloeBar.Tests", category: category)
    }
}
