import Foundation

@main
enum MenuBarItemServiceConnectionTests {
    static func main() {
        let connection = NSXPCConnection(serviceName: MenuBarItemService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: MenuBarItemServiceProtocol.self)
        connection.resume()
        let request = MenuBarItemService.Request(version: MenuBarItemService.protocolVersion, windows: [])
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            fputs("FAIL: XPC discovery/connection: \(error)\n", stderr)
            exit(1)
        } as! MenuBarItemServiceProtocol
        proxy.resolveSourcePIDs(try! JSONEncoder().encode(request)) { data in
            guard let data,
                  let reply = try? JSONDecoder().decode(MenuBarItemService.Response.self, from: data),
                  reply.version == MenuBarItemService.protocolVersion,
                  reply.sourcePIDs.isEmpty else {
                fputs("FAIL: invalid XPC reply\n", stderr)
                exit(1)
            }
            print("PASS: embedded XPC discovery and round trip")
            exit(0)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("FAIL: XPC request timed out\n", stderr)
            exit(1)
        }
        RunLoop.current.run()
    }
}
