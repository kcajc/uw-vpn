import Foundation
import Darwin

// A per-session root process, launched through sudo (Touch ID) or the macOS administrator
// dialog. It is never installed as a service and never sees the WatIAM password.
@main
enum Runner {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        var channel: Channel?
        do { try run(connecting: &channel) }
        catch {
            // Failures contain no session data. The app shows them from the socket once it is
            // connected, or from this stderr if the runner never got that far.
            let text = "Tunnel runner: \(error.localizedDescription)"
            try? channel?.send(.failed(text))
            fputs(text + "\n", stderr)
            exit(runnerFailureStatus)
        }
    }

    static func run(connecting connected: inout Channel?) throws {
        #if !TESTING
        guard geteuid() == 0 else { throw VPNError("The tunnel runner requires administrator authorization.") }
        #endif
        guard CommandLine.arguments.count == 3, let uid = UInt32(CommandLine.arguments[2]), uid != 0 else {
            throw VPNError("Expected a private socket path and the app's user ID.")
        }
        let path = CommandLine.arguments[1]
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == uid,
              info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else {
            throw VPNError("The control socket has unexpected ownership or permissions.")
        }
        let channel = try Channel.connect(path: path)
        try channel.checkPeer(uid: uid)
        connected = channel
        try channel.send(.ready)
        let session: Session
        switch try channel.receive() {
        case .stop: try channel.send(.exited(0)); return
        case .start(let value): session = value
        default: throw VPNError("Expected an authenticated session.")
        }
        try session.validate()

        // Every shutdown cause (signal, app request, lost app, OpenConnect exiting) ends the
        // receive loop below and takes the same cleanup path.
        let wake: @Sendable () -> Void = { _ = Darwin.shutdown(channel.fd, SHUT_RD) }
        // Installed before OpenConnect exists, so no signal can orphan it. A no-op handler rather
        // than SIG_IGN: ignored signals stay ignored across exec, handled ones reset to default.
        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: wake)
            source.resume()
            signalSources.append(source)
        }
        defer { signalSources.forEach { $0.cancel() } }

        let process = Process()
        #if TESTING
        guard let executable = ProcessInfo.processInfo.environment["UW_VPN_TEST_OPENCONNECT"] else {
            throw VPNError("Missing test executable.")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        #else
        process.executableURL = URL(fileURLWithPath: Config.openconnect)
        #endif
        process.arguments = session.tunnelArguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root",
                               "LANG": "C", "LC_ALL": "C"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in wake() }
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()

        let logs = DispatchGroup()
        logs.enter()
        let reader = output.fileHandleForReading.fileDescriptor
        DispatchQueue.global().async {
            var pending = Data()
            var hasConnected = false
            func emit(_ data: Data) {
                let line = sanitized(String(decoding: data, as: UTF8.self), secrets: [session.cookie])
                guard !line.isEmpty else { return }
                do {
                    try channel.send(.log(line))
                    if line.contains("Configured as ") || (hasConnected && line.contains("CSTP connected.")) {
                        hasConnected = true
                        try channel.send(.connected)
                    } else if hasConnected && line.lowercased().contains("reconnect") {
                        try channel.send(.reconnecting)
                    }
                } catch { wake() }
            }
            while true {
                let data = readChunk(reader)
                if data.isEmpty { break }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    emit(Data(pending[..<newline]))
                    pending.removeSubrange(...newline)
                }
                if pending.count > 16_384 { emit(pending); pending.removeAll() }
            }
            if !pending.isEmpty { emit(pending) }
            logs.leave()
        }
        // Cookie travels only over the private socket and this anonymous pipe.
        do {
            try input.fileHandleForWriting.write(contentsOf: Data((session.cookie + "\n").utf8))
            input.fileHandleForWriting.closeFile()
            while true { if case .stop = try channel.receive() { break } }
        } catch { /* EOF, including a crashed app, means disconnect. */ }
        // Exactly one signal, then wait however long cleanup takes: OpenConnect logs off, then runs
        // vpnc-script to restore routes and DNS. A second signal can cut short its wait for that
        // script and leave the network half restored. The app copes with a slow disconnect instead.
        if process.isRunning { process.interrupt() }
        process.waitUntilExit()
        logs.wait()
        try? channel.send(.exited(process.terminationStatus))
    }
}
