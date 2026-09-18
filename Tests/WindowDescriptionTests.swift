import Cocoa

// Dependencies outside the query path are not used by these tests.
enum Bridging {
    static func isWindowOnActiveSpace(_ id: CGWindowID) -> Bool { false }
}
enum Predicates {
    static func wallpaperWindow(for display: CGDirectDisplayID) -> (WindowInfo) -> Bool { { _ in false } }
    static func menuBarWindow(for display: CGDirectDisplayID) -> (WindowInfo) -> Bool { { _ in false } }
}

@main
enum WindowDescriptionTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 160, height: 80),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        guard let id = CGWindowID(exactly: window.windowNumber), id != 0 else {
            fatalError("A GUI session is required for window query integration tests")
        }
        let queried = WindowInfo.createWindows(from: [id])
        precondition(queried.count == 1 && queried[0].windowID == id, "Batch query lost a live window")
        precondition(queried[0].ownerPID == getpid(), "Window owner changed")
        precondition(WindowInfo(windowID: id)?.windowID == id, "Single query lost a live window")
        precondition(WindowInfo.createWindows(from: []).isEmpty)
        precondition(WindowDescriptionQuery.descriptions(for: [id]).count == 1, "XPC shared query failed")
        print("PASS: real WindowServer batch and single-window descriptions")
    }
}
