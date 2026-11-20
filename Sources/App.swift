import AppKit
import Foundation
import Darwin

enum ConnectionState: Equatable {
    case disconnected, authorizing, approvingDuo, connecting, connected, reconnecting, disconnecting

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .authorizing: "Authorizing…"
        case .approvingDuo: "Approve Duo…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .disconnecting: "Disconnecting…"
        }
    }
}

@MainActor
private final class Attempt {
    let id = UUID()
    let config: Config
    let listener: Listener
    var channel: Channel?
    var authorizer: Process?
    var authenticator: Process?
    var timer: Timer? // The connection timeout, then the disconnect deadline.
    var stopping = false
    var overdue = false // Past the disconnect deadline; still waiting for the runner to exit.
    var authenticationStarted = false
    var error: String? // The first failure wins; it is shown when the attempt finishes.
    init(config: Config) throws { self.config = config; listener = try Listener() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let connectTimeout: TimeInterval = 180
    // A normal logoff plus vpnc-script run takes a few seconds.
    #if UI_TEST
    private static let disconnectDeadline: TimeInterval = 1
    #else
    private static let disconnectDeadline: TimeInterval = 45
    #endif
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var item: NSStatusItem!
    private var state = ConnectionState.disconnected
    private var attempt: Attempt?
    private var diagnostics: [String] = []
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        _ = try? Config.load()
        refreshMenu()
    }

    #if UI_TEST
    func verifyMenu() -> Bool {
        guard let button = item.button, let frame = button.window?.frame,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }),
              item.isVisible, let menu = item.menu else { return false }
        print("Native menu: \(menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", "))")
        return menu.items.contains { $0.title == "Connect" && $0.isEnabled }
    }

    private(set) var alerts: [String] = []
    var isIdle: Bool { attempt == nil }
    var hasRunner: Bool { attempt?.channel != nil }
    var connectEnabled: Bool { item.menu?.items.first { $0.action == #selector(toggle) }?.isEnabled ?? false }
    var quitEnabled: Bool { item.menu?.items.first { $0.action == #selector(quit) }?.isEnabled ?? false }

    /// Starts an attempt without sudo and returns the "runner" end of its control socket. The test
    /// decides what the runner does; staying silent simulates a stuck OpenConnect cleanup.
    func startAttemptWithFakeRunner() throws -> Channel {
        let current = try Attempt(config: Config())
        attempt = current
        setState(.authorizing)
        waitForRunner(current)
        return try Channel.connect(path: current.listener.path)
    }
    func requestDisconnect() { stop() }
    #endif

    private func setState(_ new: ConnectionState) {
        state = new
        refreshMenu()
    }

    private func refreshMenu() {
        let connected = state == .connected
        let symbol = connected
            ? "point.3.filled.connected.trianglepath.dotted"
            : "point.3.connected.trianglepath.dotted"
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: "UW VPN — \(state.title)")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                .applying(.preferringMonochrome()))
        image?.isTemplate = true // AppKit supplies the menu bar's contrast and highlight colors.
        item.button?.title = ""
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.contentTintColor = nil
        item.button?.toolTip = "UW VPN — \(state.title)"
        let menu = NSMenu()
        menu.autoenablesItems = false
        let label = menu.addItem(withTitle: "UW VPN — \(state.title)", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(.separator())
        add(menu, attempt == nil ? "Connect" : (connected ? "Disconnect" : "Cancel / Disconnect"),
            #selector(toggle), enabled: state != .disconnecting)
        menu.addItem(.separator())
        add(menu, "Edit Config…", #selector(editConfig))
        add(menu, "Set Password…", #selector(setPassword), enabled: attempt == nil)
        add(menu, "Forget Password", #selector(forgetPassword), enabled: attempt == nil)
        add(menu, "Diagnostics…", #selector(showDiagnostics))
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit), key: "q")
        item.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     enabled: Bool = true, key: String = "") {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.isEnabled = enabled
    }

    /// Records text verbatim: the app's own messages hold no secrets. Text from OpenConnect,
    /// sudo or the runner must pass through `sanitized` before it gets here.
    private func log(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        diagnostics.append("\(Self.timestamp.string(from: Date())) \(text)")
        if diagnostics.count > 80 { diagnostics.removeFirst(diagnostics.count - 80) }
    }

    private func alert(_ message: String) {
        #if UI_TEST
        alerts.append(message) // Recorded for the test instead of blocking on a modal alert.
        #else
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "UW VPN"
        alert.informativeText = message
        alert.runModal()
        #endif
    }

    /// A one-shot main-thread timer. `allModes` lets it fire while AppKit runs a modal loop, which it
    /// does while waiting to quit: a default-mode timer would never fire there, so Quit would hang.
    /// The body runs directly on the main thread rather than hopping through the main queue, which
    /// AppKit does not drain while a quit is pending if the quit began inside a main-queue block.
    private func schedule(_ interval: TimeInterval, allModes: Bool = false,
                          _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in MainActor.assumeIsolated(body) }
        RunLoop.main.add(timer, forMode: allModes ? .common : .default)
        return timer
    }

    private func config() throws -> Config {
        let config = try Config.load()
        guard !config.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw VPNError("Set username in \(Config.file.path), then Connect. Config is reloaded on every connection.")
        }
        return config
    }

    private func password(_ config: Config, replace: Bool = false) throws -> String? {
        if !replace, let saved = try PasswordStore.read(config) { return saved }
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = "Save your WatIAM password"
        dialog.informativeText = "Account: \(config.username)\nGateway: \(config.server)\nStored in this Mac's login Keychain."
        dialog.addButton(withTitle: "Save")
        dialog.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        dialog.accessoryView = field
        dialog.window.initialFirstResponder = field
        guard dialog.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        guard !value.isEmpty, !Config.hasControls(value) else { throw VPNError("Password is empty or contains a newline/control character.") }
        try PasswordStore.save(value, config: config)
        return value
    }

    @objc private func editConfig() {
        do {
            if !FileManager.default.fileExists(atPath: Config.file.path) { _ = try Config.load() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-t", Config.file.path]
            try process.run()
        } catch {
            alert(error.localizedDescription)
        }
    }

    @objc private func setPassword() {
        do { _ = try password(config(), replace: true) }
        catch { alert(error.localizedDescription) }
    }

    @objc private func forgetPassword() {
        do { try PasswordStore.forget(config()) }
        catch { alert(error.localizedDescription) }
    }

    @objc private func showDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = "UW VPN diagnostics"
        dialog.informativeText = "Recent messages stay in memory and clear when the app quits."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = diagnostics.isEmpty ? "No connection attempted." : diagnostics.joined(separator: "\n")
        scroll.documentView = text
        dialog.accessoryView = scroll
        dialog.runModal()
    }

    @objc private func toggle() {
        if attempt != nil { stop(); return }
        do {
            let config = try config()
            guard FileManager.default.isExecutableFile(atPath: Config.openconnect),
                  FileManager.default.isExecutableFile(atPath: Config.vpncScript) else {
                throw VPNError("Install Homebrew OpenConnect and its vpnc-script first: brew install openconnect")
            }
            let current = try Attempt(config: config)
            attempt = current
            diagnostics.removeAll()
            setState(.authorizing)
            log("Authorizing a per-session tunnel runner. No persistent helper or sudoers rule.")
            // Default mode only: this must not fire behind the modal password dialog.
            current.timer = schedule(Self.connectTimeout) { [weak self] in
                self?.fail(current.id, "Connection timed out. No automatic login retries were made.")
            }
            waitForRunner(current)
            try authorize(current)
        } catch {
            if let current = attempt { fail(current.id, error.localizedDescription) }
            else { alert(error.localizedDescription) }
        }
    }

    private func authorize(_ current: Attempt, method: AuthorizationMethod = .touchID) throws {
        let runner = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/uw-vpn-runner").path
        let process = Process(), errors = Capture()
        if method == .touchID {
            log("Trying macOS sudo Touch ID authentication.")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = touchIDArguments(runner: runner, socket: current.listener.path, uid: getuid())
        } else {
            log("Using the standard macOS administrator dialog as fallback.")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = authorizationArguments(runner: runner, socket: current.listener.path, uid: getuid())
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors.pipe
        current.authorizer = process
        process.terminationHandler = { [weak self] process in
            let detail = sanitized(errors.result())
            process.terminationHandler = nil
            Task { @MainActor in
                guard let self, self.attempt?.id == current.id, current.authorizer === process else { return }
                let status = process.terminationStatus, exited = process.terminationReason == .exit
                if current.stopping { self.finish(current.id) }
                else if method.needsPasswordFallback(status: status, exited: exited,
                                                     runnerStarted: current.channel != nil, cancelled: current.stopping) {
                    self.log("sudo did not authorize the runner: \(detail.isEmpty ? "exit \(status)" : detail)")
                    do { try self.authorize(current, method: .password) }
                    catch { self.fail(current.id, error.localizedDescription) }
                }
                else if status != 0 || !exited {
                    self.fail(current.id, "Administrator authorization or tunnel runner failed.\n\(detail)")
                }
            }
        }
        do { try process.run() }
        catch {
            process.terminationHandler = nil
            errors.closeWriter()
            if method == .touchID { try authorize(current, method: .password); return }
            throw error
        }
        errors.closeWriter()
    }

    private func waitForRunner(_ current: Attempt) {
        let id = current.id, listener = current.listener
        DispatchQueue.global().async { [weak self] in
            do {
                let channel = try listener.acceptRoot()
                onMain { [weak self] in
                    guard let self, self.attempt?.id == id else { channel.shutdown(); return }
                    current.channel = channel
                }
                while true {
                    let message = try channel.receive()
                    onMain { [weak self] in self?.handle(message, id: id) }
                }
            } catch {
                onMain { [weak self] in
                    guard let self, self.attempt?.id == id else { return }
                    if current.channel != nil {
                        if !current.stopping, current.error == nil {
                            current.error = "Lost the tunnel runner. Check Diagnostics and verify VPN cleanup before reconnecting."
                        }
                        self.finish(id)
                    }
                    else if !current.stopping { self.fail(id, error.localizedDescription) }
                }
            }
        }
    }

    private func handle(_ message: Message, id: UUID) {
        guard let current = attempt, current.id == id else { return }
        switch message {
        case .ready:
            if !current.stopping { authenticate(current) }
        case .log(let text):
            log(sanitized(text))
        case .connected:
            guard !current.stopping else { return }
            current.timer?.invalidate()
            current.timer = nil
            setState(.connected)
        case .reconnecting:
            if !current.stopping { setState(.reconnecting) }
        case .failed(let text):
            // The runner exits next; the closed socket then finishes this attempt.
            let text = sanitized(text)
            log(text)
            if current.error == nil { current.error = text }
        case .exited(let code):
            if !current.stopping, current.error == nil {
                current.error = "The VPN connection ended (OpenConnect exit \(code)). See Diagnostics."
            }
            finish(id)
        case .start, .stop:
            fail(id, "Unexpected message from the tunnel runner.")
        }
    }

    private func authenticate(_ current: Attempt) {
        guard !current.authenticationStarted else { return }
        current.authenticationStarted = true
        do {
            guard let password = try password(current.config) else { stop(); return }
            guard attempt?.id == current.id, !current.stopping else { return }
            setState(.approvingDuo)
            let config = current.config
            let process = Process(), input = Pipe(), output = Capture(), errors = Capture()
            process.executableURL = URL(fileURLWithPath: Config.openconnect)
            process.arguments = config.authenticationArguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
            process.standardInput = input
            process.standardOutput = output.pipe
            process.standardError = errors.pipe
            current.authenticator = process
            process.terminationHandler = { [weak self] process in
                let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
                let stdout = output.result()
                let session = Result { try Session(output: stdout, config: config) }
                // Found even when the session is rejected, so stderr can never echo it into Diagnostics.
                let detail = sanitized(errors.result(), secrets: [password] + Session.cookies(in: stdout))
                process.terminationHandler = nil
                Task { @MainActor in
                    guard let self, self.attempt?.id == current.id, !current.stopping else { return }
                    current.authenticator = nil
                    self.log(detail)
                    do {
                        guard succeeded else {
                            throw VPNError("VPN sign-in failed. Check your password (Set Password…) and Duo approval; see Diagnostics. No login retry was made.")
                        }
                        guard let channel = current.channel else { throw VPNError("The tunnel runner is not connected.") }
                        try channel.send(.start(session.get()))
                        self.setState(.connecting)
                    } catch { self.fail(current.id, error.localizedDescription) }
                }
            }
            do { try process.run() }
            catch { output.closeWriter(); errors.closeWriter(); throw error }
            output.closeWriter()
            errors.closeWriter()
            input.fileHandleForReading.closeFile()
            try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
            input.fileHandleForWriting.closeFile()
        } catch { fail(current.id, error.localizedDescription) }
    }

    private func fail(_ id: UUID, _ message: String) {
        guard let current = attempt, current.id == id else { return }
        if current.error == nil { current.error = message }
        stop()
    }

    private func stop() {
        guard let current = attempt, !current.stopping else { return }
        current.stopping = true
        current.timer?.invalidate()
        current.timer = nil
        setState(.disconnecting)
        if let process = current.authenticator, process.isRunning { process.interrupt() }
        if let channel = current.channel {
            try? channel.send(.stop)
            current.timer = schedule(Self.disconnectDeadline, allModes: true) { [weak self] in
                guard let self, self.attempt?.id == current.id else { return }
                self.disconnectOverdue(current)
            }
        } else {
            current.listener.cancel()
            if let process = current.authorizer, process.isRunning { process.terminate() }
            finish(current.id) // No session cookie was handed off; no tunnel can have started.
        }
    }

    /// The runner has not exited in time. A pending quit stops waiting. Otherwise keep waiting, with
    /// Connect disabled but Quit available: a late vpnc-script cleanup would undo the routes and DNS
    /// of a newer session.
    private func disconnectOverdue(_ current: Attempt) {
        current.timer = nil
        let seconds = Int(Self.disconnectDeadline)
        log("The tunnel runner has not exited \(seconds) s after the disconnect request.")
        if quitting { finish(current.id); return }
        current.overdue = true
        let warning = "OpenConnect is taking more than \(seconds) seconds to disconnect. Connect becomes available again once it finishes; you can still quit. If it never finishes, restarting your Mac clears any leftover VPN network settings."
        let message = [current.error, warning].compactMap { $0 }.joined(separator: "\n\n")
        current.error = nil // Shown now; finishing later should not repeat it.
        alert(message)
    }

    private func finish(_ id: UUID) {
        guard let current = attempt, current.id == id else { return }
        if current.overdue { log("The old tunnel runner has exited; Connect is available again.") }
        current.timer?.invalidate()
        current.timer = nil
        current.listener.cancel()
        current.channel?.shutdown()
        if let process = current.authenticator, process.isRunning { process.interrupt() }
        current.authorizer?.terminationHandler = nil
        current.authenticator?.terminationHandler = nil
        attempt = nil
        setState(.disconnected)
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        else if let error = current.error { log(error); alert(error) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // An overdue disconnect has already had its deadline; there is nothing left to wait for.
        guard let current = attempt, !current.overdue else { return .terminateNow }
        quitting = true
        // Deferred so that a synchronous finish() cannot reply before .terminateLater is returned.
        // If already stopping, the pending disconnect deadline still applies.
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self.stop() } }
        return .terminateLater
    }
}

/// Schedules `body` on the main actor without blocking the calling thread.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { body() }
}

#if !UI_TEST
@main
enum Main {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
