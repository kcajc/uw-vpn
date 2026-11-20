import Foundation
import Darwin

@main
enum FakeOpenConnect {
    nonisolated(unsafe) static var cleaning = false

    static func main() {
        guard let cookie = readLine(), cookie.hasPrefix("test-cookie-"),
              !CommandLine.arguments.contains(where: { $0.contains(cookie) }),
              CommandLine.arguments.contains("--cookie-on-stdin"),
              CommandLine.arguments.contains("--script=/opt/homebrew/etc/vpnc/vpnc-script") else { exit(90) }
        // Like OpenConnect, any of these starts logoff + vpnc-script cleanup. "test-cookie-slow"
        // makes that cleanup take a while; a second signal during it would cut it short, so the
        // fake reports that instead of finishing cleanly.
        let delay: TimeInterval = cookie == "test-cookie-slow" ? 1.5 : 0
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                if cleaning { print("mock cleanup interrupted by signal \(number)"); fflush(stdout); exit(3) }
                cleaning = true
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    print("mock route and DNS cleanup")
                    fflush(stdout)
                    exit(0)
                }
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
