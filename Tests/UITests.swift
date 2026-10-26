import AppKit
import Foundation
import Darwin

@main
enum UITests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            Task { @MainActor in
                guard delegate.verifyMenu() else { fputs("Menu bar UI smoke test failed.\n", stderr); exit(1) }
                print("PASS: actual native status item is on screen, with Connect enabled; no authentication attempted.")
                app.terminate(nil)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
