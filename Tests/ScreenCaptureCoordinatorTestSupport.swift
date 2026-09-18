import CoreGraphics

enum Bridging {
    static func getWindowFrame(for windowID: CGWindowID) -> CGRect? {
        nil
    }
}

struct MenuBarItem {
    struct Info {
        enum Namespace {
            case ice
        }

        let namespace: Namespace
    }

    let info: Info
    let title: String?

    static func getMenuBarItems(
        onScreenOnly: Bool,
        activeSpaceOnly: Bool
    ) -> [MenuBarItem] {
        []
    }
}
