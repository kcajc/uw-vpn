import AppKit
import Foundation
import Darwin

@MainActor
private final class Attempt {
    let id = UUID()
    let config: Config
    let listener: Listener
    var channel: Channel?
    var authorizer: Process?
    var authenticator: Process?
    var timeout: Timer?
    var stopping = false
    var authenticationStarted = false
    var error: String?
    init(config: Config) throws { self.config = config; listener = try Listener() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var status = "Disconnected"
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
    #endif

    private func refreshMenu() {
        let connected = status == "Connected"
        let symbol = connected
            ? "point.3.filled.connected.trianglepath.dotted"
            : "point.3.connected.trianglepath.dotted"
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: "UW VPN — \(status)")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                .applying(.preferringMonochrome()))
        image?.isTemplate = true // AppKit supplies the menu bar's contrast and highlight colors.
        item.button?.title = ""
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.contentTintColor = nil
        item.button?.toolTip = "UW VPN — \(status)"
        let menu = NSMenu()
        menu.autoenablesItems = false
        let label = menu.addItem(withTitle: "UW VPN — \(status)", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(.separator())
        add(menu, attempt == nil ? "Connect" : (connected ? "Disconnect" : "Cancel / Disconnect"),
            #selector(toggle), enabled: status != "Disconnecting…")
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

    private func log(_ text: String) {
        diagnostics.append(sanitized(text))
        if diagnostics.count > 80 { diagnostics.removeFirst(diagnostics.count - 80) }
    }

    private func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "UW VPN"
        alert.informativeText = message
        alert.runModal()
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
            status = "Authorizing…"
            diagnostics.removeAll()
            log("Authorizing a per-session tunnel runner. No persistent helper or sudoers rule.")
            refreshMenu()
            current.timeout = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.fail(current.id, "Connection timed out. No automatic login retries were made.") }
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
        let input: Pipe?
        if method == .touchID {
            log("Trying macOS sudo Touch ID authentication.")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = touchIDArguments(runner: runner, socket: current.listener.path, uid: getuid())
            process.standardInput = FileHandle.nullDevice
            input = nil
        } else {
            log("Using the standard macOS administrator dialog as fallback.")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            input = Pipe()
            process.standardInput = input
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors.pipe
        current.authorizer = process
        process.terminationHandler = { [weak self] process in
            let detail = errors.result()
            process.terminationHandler = nil
            Task { @MainActor in
                guard let self, self.attempt?.id == current.id, current.authorizer === process else { return }
                if current.stopping { self.finish(current.id) }
                else if method.needsPasswordFallback(exitCode: process.terminationStatus,
                                                     runnerStarted: current.channel != nil, cancelled: current.stopping) {
                    do { try self.authorize(current, method: .password) }
                    catch { self.fail(current.id, error.localizedDescription) }
                }
                else if process.terminationStatus != 0 {
                    self.fail(current.id, "Administrator authorization or tunnel runner failed.\n\(sanitized(detail))")
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
        if let input {
            input.fileHandleForReading.closeFile()
            try input.fileHandleForWriting.write(contentsOf:
                Data(authorizationScript(runner: runner, socket: current.listener.path, uid: getuid()).utf8))
            input.fileHandleForWriting.closeFile()
        }
    }

    private func waitForRunner(_ current: Attempt) {
        DispatchQueue.global().async { [weak self] in
            do {
                let channel = try current.listener.acceptRoot()
                awaitMain { [weak self] in
                    guard let self, self.attempt?.id == current.id else { channel.shutdown(); return }
                    current.channel = channel
                    if current.stopping { try? channel.send(Message(kind: "stop")) }
                }
                while true {
                    let message = try channel.receive()
                    awaitMain { [weak self] in self?.handle(message, id: current.id) }
                }
            } catch {
                awaitMain { [weak self] in
                    guard let self, self.attempt?.id == current.id else { return }
                    if current.channel != nil {
                        if !current.stopping { current.error = "Lost the tunnel runner. Check Diagnostics and verify VPN cleanup before reconnecting." }
                        self.finish(current.id)
                    }
                    else if !current.stopping { self.fail(current.id, error.localizedDescription) }
                }
            }
        }
    }

    private func handle(_ message: Message, id: UUID) {
        guard let current = attempt, current.id == id else { return }
        switch message.kind {
        case "ready":
            if !current.stopping { authenticate(current) }
        case "log": log(message.text ?? "")
        case "connected":
            if !current.stopping { status = "Connected"; current.timeout?.invalidate(); refreshMenu() }
        case "reconnecting":
            if !current.stopping { status = "Reconnecting…"; refreshMenu() }
        case "exited":
            if !current.stopping { current.error = "The VPN connection ended (OpenConnect exit \(message.code ?? -1)). See Diagnostics." }
            finish(id)
        default: fail(id, "Unexpected message from tunnel runner.")
        }
    }

    private func authenticate(_ current: Attempt) {
        guard !current.authenticationStarted else { return }
        current.authenticationStarted = true
        do {
            guard let password = try password(current.config) else { stop(); return }
            guard attempt?.id == current.id, !current.stopping else { return }
            status = "Approve Duo…"
            refreshMenu()
            let process = Process(), input = Pipe(), output = Capture(), errors = Capture()
            process.executableURL = URL(fileURLWithPath: Config.openconnect)
            process.arguments = current.config.authenticationArguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
            process.standardInput = input
            process.standardOutput = output.pipe
            process.standardError = errors.pipe
            current.authenticator = process
            process.terminationHandler = { [weak self] process in
                let result = output.result()
                let detail = sanitized(errors.result(), secrets: [password])
                process.terminationHandler = nil
                Task { @MainActor in
                    guard let self, self.attempt?.id == current.id, !current.stopping else { return }
                    current.authenticator = nil
                    self.log(detail)
                    do {
                        guard process.terminationStatus == 0 else {
                            throw VPNError("VPN sign-in failed. Check your password and Duo approval; see Diagnostics. No login retry was made.")
                        }
                        let session = try Session(output: result, config: current.config)
                        try current.channel?.send(Message(kind: "start", session: session))
                        self.status = "Connecting…"
                        self.refreshMenu()
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
        current.error = sanitized(message)
        stop()
    }

    private func stop() {
        guard let current = attempt, !current.stopping else { return }
        current.stopping = true
        current.timeout?.invalidate()
        current.timeout = nil
        status = "Disconnecting…"
        refreshMenu()
        if let process = current.authenticator, process.isRunning { process.interrupt() }
        if let channel = current.channel { try? channel.send(Message(kind: "stop")) }
        else {
            current.listener.cancel()
            if let process = current.authorizer, process.isRunning { process.terminate() }
            finish(current.id) // No session cookie was handed off; no tunnel can have started.
        }
    }

    private func finish(_ id: UUID) {
        guard let current = attempt, current.id == id else { return }
        current.timeout?.invalidate()
        current.timeout = nil
        current.listener.cancel()
        current.channel?.shutdown()
        if let process = current.authenticator, process.isRunning { process.interrupt() }
        current.authorizer?.terminationHandler = nil
        current.authenticator?.terminationHandler = nil
        attempt = nil
        status = "Disconnected"
        refreshMenu()
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        else if let error = current.error { log(error); alert(error) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard attempt != nil else { return .terminateNow }
        quitting = true
        DispatchQueue.main.async { self.stop() }
        return .terminateLater
    }
}

private func awaitMain(_ body: @escaping @MainActor () -> Void) {
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
