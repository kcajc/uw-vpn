import Foundation
import Darwin

@main
enum FakeOpenConnect {
    static func main() {
        guard let cookie = readLine(), cookie.hasPrefix("test-cookie-"),
              !CommandLine.arguments.contains(where: { $0.contains(cookie) }),
              CommandLine.arguments.contains("--cookie-on-stdin"),
              CommandLine.arguments.contains("--script=/opt/homebrew/etc/vpnc/vpnc-script") else { exit(90) }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            print("mock route and DNS cleanup")
            fflush(stdout)
            exit(0)
        }
        source.resume()
        print("mock pid: \(getpid())")
        print("Configured as 192.0.2.2, with SSL connected")
        print("cookie=\(cookie)") // Intentionally test secret filtering.
        fflush(stdout)
        if cookie == "test-cookie-exit" { exit(7) }
        withExtendedLifetime(source) { dispatchMain() }
    }
}
