import Foundation
import Darwin

nonisolated(unsafe) private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    checks += 1
}
private func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); check(false, label) } catch { checks += 1 }
}
private func message(_ label: String, _ body: () throws -> Void) -> String {
    do { try body(); check(false, label); return "" } catch { checks += 1; return error.localizedDescription }
}
private func json(_ message: Message) throws -> [String: String] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any] ?? [:]
    return object.mapValues { "\($0)" }
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
        var bad = config; bad.duo = "push; command"
        rejects("Duo restricted to push devices") { try bad.validate() }
        bad = config; bad.duo = "push\n"
        rejects("Duo rejects a trailing newline") { try bad.validate() }
        bad = config; bad.reconnectTimeout = 0
        rejects("timeout bounded") { try bad.validate() }
        bad = config; bad.duo = "push2"; try bad.validate()
        check(bad.keychainAccount == config.keychainAccount, "Duo setting does not change password identity")
        bad = config; bad.authgroup = "Different"
        check(bad.keychainAccount != config.keychainAccount, "Keychain group isolation")
        bad = config; bad.username = "another"
        check(bad.keychainAccount != config.keychainAccount, "Keychain account isolation")

        // Config errors name the problem instead of "The data couldn't be read".
        let full = #""server":"https://vpn.example","authgroup":"g","username":"u","duo":"push""#
        check(message("unknown key") { _ = try Config.decode(Data(#"{\#(full),"reconnectTimeout":1,"extra":true}"#.utf8)) }
                .contains(#""extra""#), "unknown config key is named")
        check(message("missing key") { _ = try Config.decode(Data(#"{\#(full)}"#.utf8)) }
                .contains(#"missing "reconnectTimeout""#), "missing config key is named")
        check(message("wrong type") { _ = try Config.decode(Data(#"{\#(full),"reconnectTimeout":"1"}"#.utf8)) }
                .contains(#""reconnectTimeout" has the wrong type"#), "mistyped config value is named")
        check(message("bad JSON") { _ = try Config.decode(Data(#"{"server":}"#.utf8)) }
                .hasPrefix("Config is not valid JSON"), "invalid JSON is reported as such")
        check(message("bad Duo") { var c = config; c.duo = "sms"; try c.validate() }
                .contains(#""duo""#), "validation names the bad field")

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
        // OpenConnect 9.21 prints a bare RESOLVE= when it has no address to pin; that is not malformed.
        let unpinned = try Session(output: output.replacingOccurrences(of: "RESOLVE='vpn2.example:192.0.2.1'", with: "RESOLVE="),
                                   config: config)
        check(unpinned.resolve == nil && !unpinned.tunnelArguments.contains { $0.hasPrefix("--resolve") },
              "bare RESOLVE= means no pinned address")
        rejects("duplicate bare assignment rejected") { _ = try Session(output: output + "RESOLVE=\n", config: config) }
        let rejected = "COOKIE='leaky-cookie'\nFINGERPRINT='--bad'\n"
        rejects("malformed session rejected") { _ = try Session(output: rejected, config: config) }
        check(Session.cookies(in: rejected) == ["leaky-cookie"], "cookie found for redaction when the session is rejected")
        check(Session.cookies(in: "COOKIE=bare\nCOOKIE='quoted'\nCOOKIE=\n") == ["bare", "quoted"], "every cookie form found for redaction")

        // The control-socket wire format is unchanged by the Message enum.
        check(try! json(.exited(7)) == ["kind": "exited", "code": "7"], "exited wire format")
        check(try! json(.log("hi")) == ["kind": "log", "text": "hi"], "log wire format")
        check(try! json(.stop) == ["kind": "stop"], "stop wire format")
        let roundTrip = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(Message.start(session)))
        if case .start(let decoded) = roundTrip { check(decoded.cookie == session.cookie, "start round trip") }
        else { check(false, "start round trip") }
        rejects("unknown message kind rejected") { _ = try JSONDecoder().decode(Message.self, from: Data(#"{"kind":"shell"}"#.utf8)) }
        rejects("message missing its payload rejected") { _ = try JSONDecoder().decode(Message.self, from: Data(#"{"kind":"log"}"#.utf8)) }

        check(sanitized("hello topsecret", secrets: ["topsecret"]) == "hello [redacted]", "exact secret redaction")
        check(!sanitized("Set-Cookie: secret\nPassword: anything").contains("secret"), "credential lines suppressed")
        check(!sanitized("Set-Cookie: secret\nPassword: anything").contains("anything"), "credential values suppressed")
        check(sanitized("Cookie: webvpn=abc; path=/") == "Cookie: [redacted]", "credential label kept, value redacted")
        check(sanitized("GET /logout?token=abc&next=1") == "GET /logout?token=[redacted]", "query token redacted")
        check(sanitized("webvpn_cookie=abc") == "webvpn_cookie=[redacted]", "prefixed credential key redacted")
        check(sanitized("Failed to obtain WebVPN cookie") == "Failed to obtain WebVPN cookie", "cookie diagnostic kept")
        check(sanitized("sudo: a password is required") == "sudo: a password is required", "sudo diagnostic kept")
        check(sanitized("<session-token>abc123</session-token>") == "<session-token>[redacted]</session-token>",
              "credential element body redacted")
        check(!sanitized(#"<input type="password" name="password" value="p&amp;ss">"#).contains("p&amp;ss"),
              "escaped password in a form value redacted")
        check(sanitized(#"<input name="username" value="bob">"#) == #"<input name="username" value="bob">"#,
              "non-credential form value kept")
        check(sanitized("xx-abcdef-xx", secrets: ["cd", "abcdef"]) == "xx-[redacted]-xx",
              "a secret inside a longer secret cannot break the longer one's redaction")

        check(processIDs(named: ["launchd"]).contains(1), "process lookup sees root processes")
        check(processIDs(named: [ProcessInfo.processInfo.processName]).contains(getpid()), "process lookup sees this process")
        check(processIDs(named: ["no-such-process-name"]).isEmpty, "process lookup matches exact names")

        let arguments = authorizationArguments(runner: "/path with 'quotes'/runner", socket: "/tmp/control", uid: 501)
        check(!arguments.joined().contains(session.cookie), "authorization arguments contain no credentials")
        check(arguments.suffix(3) == ["/path with 'quotes'/runner", "/tmp/control", "501"], "fallback paths passed as arguments, not script source")
        check(!authorizationScript.joined().contains("/path"), "fallback script source is fixed")
        var appleScriptError: NSDictionary?
        check(NSAppleScript(source: authorizationScript.joined(separator: "\n"))!.compileAndReturnError(&appleScriptError),
              "authorization AppleScript compiles without running")
        let touchID = touchIDArguments(runner: "/path with 'quotes'/runner", socket: "/tmp/control", uid: 501)
        check(touchID.contains("-S") && !touchID.contains("-A"), "Touch ID uses PAM without askpass")
        check(touchID.contains("-k"), "Touch ID does not borrow cached sudo authentication")
        check(touchID.suffix(3) == ["/path with 'quotes'/runner", "/tmp/control", "501"], "runner arguments passed directly without shell parsing")
        check(!touchID.joined().contains(session.cookie), "biometric launch has no credentials")

        let touch = AuthorizationMethod.touchID
        check(touch.needsPasswordFallback(status: 1, exited: true, runnerStarted: false, cancelled: false), "sudo refusal permits password fallback")
        check(!touch.needsPasswordFallback(status: 0, exited: true, runnerStarted: false, cancelled: false), "successful biometrics does not request password")
        check(!touch.needsPasswordFallback(status: runnerFailureStatus, exited: true, runnerStarted: false, cancelled: false), "runner failure does not re-prompt")
        check(runnerFailureStatus != 1, "runner failures are distinguishable from sudo refusals")
        check(!touch.needsPasswordFallback(status: 1, exited: false, runnerStarted: false, cancelled: false), "signal 1 (SIGHUP) is not a sudo refusal")
        check(!touch.needsPasswordFallback(status: 1, exited: true, runnerStarted: true, cancelled: false), "no second runner after first runner starts")
        check(!touch.needsPasswordFallback(status: 1, exited: true, runnerStarted: false, cancelled: true), "cancelling the connection suppresses fallback")
        check(!AuthorizationMethod.password.needsPasswordFallback(status: 1, exited: true, runnerStarted: false, cancelled: false), "password fallback cannot retry itself")

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
