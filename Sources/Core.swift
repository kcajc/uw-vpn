import Foundation

struct VPNError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Config: Codable, Sendable {
    var server = "https://vpn.uwaterloo.ca"
    var authgroup = "UW-General-Campus"
    var username = ""
    var duo = "push"
    var reconnectTimeout = 3600

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/uw-vpn/config.json")
    static let openconnect = "/opt/homebrew/bin/openconnect"
    static let vpncScript = "/opt/homebrew/etc/vpnc/vpnc-script"

    static func load() throws -> Config {
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(Config()).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return try decode(Data(contentsOf: file))
    }

    static func decode(_ data: Data) throws -> Config {
        guard data.count < 16_384 else { throw VPNError("Config exceeds 16 KiB.") }
        // Reject misspelled/unknown keys rather than silently ignoring them.
        let allowed: Set<String> = ["server", "authgroup", "username", "duo", "reconnectTimeout"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else {
            throw VPNError("Unknown config key. See config.example.json.")
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        try config.validate()
        return config
    }

    func validate() throws {
        try Self.validateURL(server)
        guard !authgroup.isEmpty, !Self.hasControls(authgroup),
              !Self.hasControls(username), username.count < 256,
              duo.range(of: #"^push[0-9]*$"#, options: .regularExpression) != nil,
              (1...86_400).contains(reconnectTimeout) else {
            throw VPNError("Invalid group, username, Duo setting, or reconnectTimeout.")
        }
    }

    static func validateURL(_ value: String) throws {
        guard !hasControls(value), let url = URLComponents(string: value),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw VPNError("The VPN server must be an HTTPS URL without embedded credentials.")
        }
    }

    static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    // Scope the saved password to the exact gateway, group and account.
    var keychainAccount: String { [server, authgroup, username].map { "\($0.utf8.count):\($0)" }.joined() }

    var authenticationArguments: [String] {
        ["--protocol=anyconnect", "--authenticate", "--non-inter", "--no-external-auth",
         "--passwd-on-stdin", "--user=\(username)", "--authgroup=\(authgroup)",
         "--form-entry=main:secondary_password=\(duo)", "--server=\(server)"]
    }
}

struct Session: Codable, Sendable {
    let cookie: String
    let server: String
    let fingerprint: String
    let resolve: String?
    let reconnectTimeout: Int

    init(output: String, config: Config) throws {
        // This is data, never shell code: deliberately do not eval/source OpenConnect's output.
        var values: [String: String] = [:]
        let allowed: Set<String> = ["COOKIE", "HOST", "CONNECT_URL", "FINGERPRINT", "RESOLVE"]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard allowed.contains(key) else { continue }
            let quoted = String(line[line.index(after: equals)...])
            guard quoted.first == "'", quoted.last == "'", quoted.count >= 2,
                  values[key] == nil else { throw VPNError("Unexpected authentication output.") }
            values[key] = String(quoted.dropFirst().dropLast())
        }
        guard let cookie = values["COOKIE"], let fingerprint = values["FINGERPRINT"] else {
            throw VPNError("OpenConnect returned no authenticated session.")
        }
        self.cookie = cookie
        self.server = values["CONNECT_URL"] ?? values["HOST"].map {
            $0.hasPrefix("https://") ? $0 : "https://\($0)"
        } ?? config.server
        self.fingerprint = fingerprint
        self.resolve = values["RESOLVE"]
        self.reconnectTimeout = config.reconnectTimeout
        try validate()
    }

    func validate() throws {
        try Config.validateURL(server)
        guard !cookie.isEmpty, cookie.utf8.count < 32_768, !Config.hasControls(cookie),
              fingerprint.range(of: #"^(pin-sha256:[A-Za-z0-9+/=]+|sha256:[A-Fa-f0-9:]+|[A-Fa-f0-9]{40,64})$"#,
                                options: .regularExpression) != nil,
              (1...86_400).contains(reconnectTimeout),
              resolve.map({ !$0.isEmpty && $0.count < 1024 && !Config.hasControls($0) }) ?? true else {
            throw VPNError("Invalid authenticated session metadata.")
        }
    }

    var tunnelArguments: [String] {
        var args = ["--protocol=anyconnect", "--non-inter", "--no-passwd", "--cookie-on-stdin",
                    "--reconnect-timeout=\(reconnectTimeout)", "--servercert=\(fingerprint)",
                    "--script=\(Config.vpncScript)", "--server=\(server)"]
        if let resolve { args.append("--resolve=\(resolve)") }
        return args
    }
}

struct Message: Codable, Sendable {
    let kind: String
    var text: String? = nil
    var session: Session? = nil
    var code: Int32? = nil
}

func sanitized(_ text: String, secrets: [String] = []) -> String {
    var result = text
    for secret in secrets where !secret.isEmpty {
        result = result.replacingOccurrences(of: secret, with: "[redacted]")
    }
    return result.split(separator: "\n").map { line in
        let lower = line.lowercased()
        if ["cookie", "password", "authorization:", "token="].contains(where: lower.contains) {
            return "[credential-related diagnostic omitted]"
        }
        return String(line.prefix(2000))
    }.joined(separator: "\n")
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum AuthorizationMethod {
    case touchID, password

    func needsPasswordFallback(exitCode: Int32, runnerStarted: Bool, cancelled: Bool) -> Bool {
        self == .touchID && exitCode != 0 && !runnerStarted && !cancelled
    }
}

func touchIDArguments(runner: String, socket: String, uid: UInt32) -> [String] {
    // -S permits a GUI process without a terminal, while still using pam_tid.
    // stdin is /dev/null: password authentication cannot happen on this path.
    // Do not use -A: Apple's pam_tid explicitly skips Touch ID in askpass mode.
    // -k ignores cached sudo credentials for this invocation.
    ["-k", "-S", "-p", "", "--", runner, socket, String(uid)]
}

func authorizationScript(runner: String, socket: String, uid: UInt32) -> String {
    let command = "exec \(shellQuote(runner)) \(shellQuote(socket)) \(uid)"
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(escaped)\" with administrator privileges\n"
}
