import Foundation
import Darwin

@main
enum FakeOpenConnect {
    static func main() {
        guard let cookie = readLine(), cookie.hasPrefix("test-cookie-"),
              !CommandLine.arguments.contains(where: { $0.contains(cookie) }),
              CommandLine.arguments.contains("--cookie-on-stdin"),
              CommandLine.arguments.contains("--script=/opt/homebrew/etc/vpnc/vpnc-script") else { exit(90) }
        // Like OpenConnect: SIGINT/SIGTERM log off then clean up; SIGHUP cleans up without logoff.
        // "test-cookie-stuck" simulates a logoff that hangs, so only SIGHUP finishes.
        let stuck = cookie == "test-cookie-stuck"
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                if stuck && number != SIGHUP { print("mock logoff hanging"); fflush(stdout); return }
                print(number == SIGHUP ? "mock route and DNS cleanup without logoff" : "mock route and DNS cleanup")
                fflush(stdout)
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
        print("mock pid: \(getpid())")
        print("Configured as 192.0.2.2, with SSL connected")
        print("cookie=\(cookie)") // Intentionally test secret filtering.
        fflush(stdout)
        if cookie == "test-cookie-exit" { exit(7) }
        withExtendedLifetime(sources) { dispatchMain() }
    }
}
