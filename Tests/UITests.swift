import AppKit
import Foundation
import Darwin

private func fail(_ message: String) -> Never { fputs("FAIL: \(message)\n", stderr); exit(1) }
private func pass(_ message: String) { print("PASS: \(message)") }

// Drives the real AppDelegate. Each step runs from a run-loop timer, like a menu click, never
// from a main-queue block: AppKit does not drain the main queue re-entrantly, which would hide
// exactly the quit hang this test exists to catch.
@main
enum UITests {
    nonisolated(unsafe) static var runner: Channel? // The fake runner end; silent unless closed.

    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Fail rather than hang if quitting never completes.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            fputs("FAIL: UI test timed out (quit hung?).\n", stderr)
            exit(1)
        }
        // The deadline in UI_TEST builds is 1 s.
        let steps: [(TimeInterval, @MainActor () throws -> Void)] = [
            (1.0, {
                guard delegate.verifyMenu() else { fail("menu bar UI smoke test") }
                pass("actual native status item is on screen, with Connect enabled; no authentication attempted.")
                runner = try delegate.startAttemptWithFakeRunner()
            }),
            (0.5, {
                guard delegate.hasRunner else { fail("fake runner never connected") }
                delegate.requestDisconnect()
            }),
            (1.5, {
                guard !delegate.isIdle, !delegate.connectEnabled, delegate.quitEnabled else {
                    fail("an overdue disconnect must keep Connect disabled and Quit enabled")
                }
                guard delegate.alerts.count == 1, delegate.alerts[0].contains("taking more than") else {
                    fail("an overdue disconnect must warn once; got \(delegate.alerts)")
                }
                pass("overdue disconnect warns and keeps Connect disabled; Quit stays available.")
                runner?.shutdown() // The old runner finally exits.
            }),
            (0.5, {
                guard delegate.isIdle, delegate.connectEnabled, delegate.alerts.count == 1 else {
                    fail("Connect must return, without a second alert, once the old runner exits")
                }
                pass("Connect returns once the old runner exits.")
                runner = try delegate.startAttemptWithFakeRunner()
            }),
            (0.5, {
                guard delegate.hasRunner else { fail("second fake runner never connected") }
                NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                       object: nil, queue: nil) { _ in
                    pass("Quit with a silent tunnel runner exits after the disconnect deadline.")
                }
                app.terminate(nil) // Returns only if quitting is cancelled.
                fail("quit was cancelled")
            }),
        ]
        var delay: TimeInterval = 0
        for (wait, step) in steps {
            delay += wait
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated {
                    do { try step() } catch { fail("\(error)") }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
