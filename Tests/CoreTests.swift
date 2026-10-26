import Foundation
import Darwin

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    checks += 1
}
private func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); check(false, label) } catch { checks += 1 }
}

@main
enum Tests {
    static func main() throws {
        var config = try Config.decode(Data(contentsOf: URL(fileURLWithPath: "config.example.json")))
        config.username = "testuser"
        try config.validate()
        check(config.authgroup == "UW-General-Campus", "profile preserved")
        check(config.authenticationArguments.contains("--form-entry=main:secondary_password=push"), "automatic Duo field")
        check(config.authenticationArguments.contains("--non-inter"), "no automatic prompt/retry")
        check(config.authenticationArguments.contains("--passwd-on-stdin"), "password via stdin")
        check(!config.authenticationArguments.joined().contains("test-password"), "no password argument")
        rejects("HTTP rejected") { try Config.validateURL("http://vpn.example") }
        rejects("embedded credentials rejected") { try Config.validateURL("https://alice:password@vpn.example") }
        rejects("control chars rejected") { try Config.validateURL("https://vpn.example\n") }
        rejects("unknown config option rejected") {
            _ = try Config.decode(Data(#"{"server":"https://vpn.example","extra":true}"#.utf8))
        }
        var bad = config; bad.duo = "push; command"
        rejects("Duo restricted to push devices") { try bad.validate() }
        bad = config; bad.reconnectTimeout = 0
        rejects("timeout bounded") { try bad.validate() }
        bad = config; bad.duo = "push2"; try bad.validate()
        check(bad.keychainAccount == config.keychainAccount, "Duo setting does not change password identity")
        bad = config; bad.authgroup = "Different"
        check(bad.keychainAccount != config.keychainAccount, "Keychain group isolation")
        bad = config; bad.username = "another"
        check(bad.keychainAccount != config.keychainAccount, "Keychain account isolation")

        let output = "COOKIE='test-cookie'\nHOST='vpn.example'\nCONNECT_URL='https://vpn2.example/group'\nFINGERPRINT='pin-sha256:abcDEF123+/='\nRESOLVE='vpn2.example:192.0.2.1'\n"
        let session = try Session(output: output, config: config)
        check(session.server == "https://vpn2.example/group", "redirected gateway retained")
        check(session.resolve == "vpn2.example:192.0.2.1", "authenticated gateway IP retained")
        check(!session.tunnelArguments.joined().contains(session.cookie), "cookie absent from argv")
        check(session.tunnelArguments.contains("--cookie-on-stdin"), "cookie via stdin")
        check(session.tunnelArguments.contains("--servercert=pin-sha256:abcDEF123+/="), "certificate bound to authentication")
        check(session.tunnelArguments.contains("--script=/opt/homebrew/etc/vpnc/vpnc-script"), "fixed route script")
        rejects("no session without cookie") { _ = try Session(output: "FINGERPRINT='abc'", config: config) }
        rejects("duplicate assignments rejected") { _ = try Session(output: output + "COOKIE='second'", config: config) }
        rejects("invalid fingerprint rejected") {
            _ = try Session(output: output.replacingOccurrences(of: "pin-sha256:abcDEF123+/=", with: "--no-system-trust"), config: config)
        }
        let injection = try Session(output: output.replacingOccurrences(of: "test-cookie", with: "$(touch /tmp/NEVER_EXECUTE)"), config: config)
        check(injection.cookie == "$(touch /tmp/NEVER_EXECUTE)", "session output treated as data")
        check(!FileManager.default.fileExists(atPath: "/tmp/NEVER_EXECUTE"), "no shell evaluation")
        check(sanitized("hello topsecret", secrets: ["topsecret"]) == "hello [redacted]", "exact secret redaction")
        check(!sanitized("Set-Cookie: secret\nPassword: anything").contains("secret"), "credential lines suppressed")
        let script = authorizationScript(runner: "/path with 'quotes'/runner", socket: "/tmp/control", uid: 501)
        check(!script.contains(session.cookie), "authorization script contains no credentials")
        var appleScriptError: NSDictionary?
        check(NSAppleScript(source: script)!.compileAndReturnError(&appleScriptError), "authorization AppleScript compiles without running")
        check(shellQuote("a'b") == "'a'\\''b'", "shell quoting")
        let touchID = touchIDArguments(runner: "/path with 'quotes'/runner", socket: "/tmp/control", uid: 501)
        check(touchID.contains("-S") && !touchID.contains("-A"), "Touch ID uses PAM without askpass")
        check(touchID.contains("-k"), "Touch ID does not borrow cached sudo authentication")
        check(touchID.suffix(3) == ["/path with 'quotes'/runner", "/tmp/control", "501"], "runner arguments passed directly without shell parsing")
        check(!touchID.joined().contains(session.cookie), "biometric launch has no credentials")
        check(AuthorizationMethod.touchID.needsPasswordFallback(exitCode: 1, runnerStarted: false, cancelled: false), "failed biometrics permits password fallback")
        check(!AuthorizationMethod.touchID.needsPasswordFallback(exitCode: 0, runnerStarted: false, cancelled: false), "successful biometrics does not request password")
        check(!AuthorizationMethod.touchID.needsPasswordFallback(exitCode: 1, runnerStarted: true, cancelled: false), "no second runner after first runner starts")
        check(!AuthorizationMethod.touchID.needsPasswordFallback(exitCode: 1, runnerStarted: false, cancelled: true), "cancelling the connection suppresses fallback")
        check(!AuthorizationMethod.password.needsPasswordFallback(exitCode: 1, runnerStarted: false, cancelled: false), "password fallback cannot retry itself")

        let listener = try Listener()
        var info = stat()
        check(lstat(listener.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "socket permissions")
        check(lstat(listener.directory, &info) == 0 && info.st_mode & 0o777 == 0o700, "socket directory permissions")
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { _ = try listener.acceptRoot(); check(false, "cancelled accept returned a connection") } catch {}
            done.signal()
        }
        listener.cancel()
        check(done.wait(timeout: .now() + 2) == .success, "pending authorization cancels without blocking")
        print("Passed \(checks) core checks.")
    }
}
