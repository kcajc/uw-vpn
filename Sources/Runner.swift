import Foundation
import Darwin

// A per-session root process, launched through the normal macOS authorization
// dialog. It is never installed as a service and never sees the WatIAM password.
@main
enum Runner {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do { try run() }
        catch {
            // Startup failures contain no session data. The app reads this stderr.
            fputs("UW VPN: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
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
        try channel.send(Message(kind: "ready"))
        let start = try channel.receive()
        if start.kind == "stop" { try channel.send(Message(kind: "exited", code: 0)); return }
        guard start.kind == "start", let session = start.session else {
            throw VPNError("Expected an authenticated session.")
        }
        try session.validate()

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
        process.terminationHandler = { _ in _ = Darwin.shutdown(channel.fd, SHUT_RD) }
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()

        // Root signals and a lost GUI connection both take the same cleanup path.
        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { _ = Darwin.shutdown(channel.fd, SHUT_RD) }
            source.resume()
            signalSources.append(source)
        }
        defer { signalSources.forEach { $0.cancel() } }

        let logs = DispatchGroup()
        logs.enter()
        DispatchQueue.global().async {
            var pending = Data()
            var hasConnected = false
            func emit(_ data: Data) {
                let line = sanitized(String(decoding: data, as: UTF8.self), secrets: [session.cookie])
                guard !line.isEmpty else { return }
                do {
                    try channel.send(Message(kind: "log", text: line))
                    if line.contains("Configured as ") || (hasConnected && line.contains("CSTP connected.")) {
                        hasConnected = true
                        try channel.send(Message(kind: "connected"))
                    } else if hasConnected && line.lowercased().contains("reconnect") {
                        try channel.send(Message(kind: "reconnecting"))
                    }
                } catch { _ = Darwin.shutdown(channel.fd, SHUT_RD) }
            }
            while true {
                let data = output.fileHandleForReading.availableData
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
            while try channel.receive().kind != "stop" {}
        } catch { /* EOF, including a crashed app, means disconnect. */ }
        if process.isRunning { process.interrupt() }
        process.waitUntilExit() // OpenConnect runs vpnc-script to restore routes/DNS.
        logs.wait()
        try? channel.send(Message(kind: "exited", code: process.terminationStatus))
    }
}
