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
    private static let keys: Set<String> = ["server", "authgroup", "username", "duo", "reconnectTimeout"]

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
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw VPNError("Config is not valid JSON" + (detail.map { ": \($0)" } ?? "."))
        }
        guard let present = (object as? [String: Any])?.keys else {
            throw VPNError("Config must be a JSON object. See config.example.json.")
        }
        // Reject misspelled/unknown keys rather than silently ignoring them.
        if let unknown = present.filter({ !keys.contains($0) }).sorted().first {
            throw VPNError("Unknown config key \"\(unknown)\". See config.example.json.")
        }
        let config: Config
        do { config = try JSONDecoder().decode(Config.self, from: data) }
        catch let DecodingError.keyNotFound(key, _) {
            throw VPNError("Config is missing \"\(key.stringValue)\". See config.example.json.")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context),
                let DecodingError.dataCorrupted(context) {
            let key = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw VPNError("Config value \"\(key)\" has the wrong type. See config.example.json.")
        }
        try config.validate()
        return config
    }

    func validate() throws {
        try Self.validateURL(server)
        guard !authgroup.isEmpty, authgroup.count < 256, !Self.hasControls(authgroup) else {
            throw VPNError("\"authgroup\" must be a non-empty single line.")
        }
        guard username.count < 256, !Self.hasControls(username) else {
            throw VPNError("\"username\" must be a single line under 256 characters.")
        }
        guard duo.range(of: #"^push[0-9]*$"#, options: .regularExpression) != nil else {
            throw VPNError("\"duo\" must be push, push2, push3, and so on.")
        }
        guard (1...86_400).contains(reconnectTimeout) else {
            throw VPNError("\"reconnectTimeout\" must be between 1 and 86400 seconds.")
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

/// One newline-delimited JSON object on the control socket, e.g. {"kind":"log","text":"..."}.
enum Message: Sendable {
    case ready               // runner → app: connected and waiting for a session
    case start(Session)      // app → runner
    case stop                // app → runner
    case log(String)         // runner → app, already sanitized
    case connected           // runner → app
    case reconnecting        // runner → app
    case failed(String)      // runner → app: the runner is about to exit with this error
    case exited(Int32)       // runner → app: OpenConnect finished; the runner exits next
}

extension Message: Codable {
    private enum CodingKeys: String, CodingKey { case kind, text, session, code }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "ready": self = .ready
        case "start": self = .start(try values.decode(Session.self, forKey: .session))
        case "stop": self = .stop
        case "log": self = .log(try values.decode(String.self, forKey: .text))
        case "connected": self = .connected
        case "reconnecting": self = .reconnecting
        case "failed": self = .failed(try values.decode(String.self, forKey: .text))
        case "exited": self = .exited(try values.decode(Int32.self, forKey: .code))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                                                   debugDescription: "Unknown control message \"\(kind)\".")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready: try values.encode("ready", forKey: .kind)
        case .start(let session):
            try values.encode("start", forKey: .kind)
            try values.encode(session, forKey: .session)
        case .stop: try values.encode("stop", forKey: .kind)
        case .log(let text):
            try values.encode("log", forKey: .kind)
            try values.encode(text, forKey: .text)
        case .connected: try values.encode("connected", forKey: .kind)
        case .reconnecting: try values.encode("reconnecting", forKey: .kind)
        case .failed(let text):
            try values.encode("failed", forKey: .kind)
            try values.encode(text, forKey: .text)
        case .exited(let code):
            try values.encode("exited", forKey: .kind)
            try values.encode(code, forKey: .code)
        }
    }
}

// Keeps a label such as "Cookie:" or "password=" readable and drops everything after it.
private let credentialPattern =
    #"(?i)((?:cookie|authorization|passw(?:or)?d|token|secret)[A-Za-z0-9_-]*\s*[:=]\s*)\S.*"#

/// Redacts text produced by OpenConnect, sudo or the runner before it is shown or stored.
/// Do not pass the app's own messages through this: they hold no secrets, and redaction would
/// only hide them.
func sanitized(_ text: String, secrets: [String] = []) -> String {
    var result = text
    for secret in secrets where !secret.isEmpty {
        result = result.replacingOccurrences(of: secret, with: "[redacted]")
    }
    return result.split(separator: "\n").map { line in
        String(String(line).replacingOccurrences(of: credentialPattern, with: "$1[redacted]",
                                                 options: .regularExpression).prefix(2000))
    }.joined(separator: "\n")
}

/// The runner's exit status for its own errors. sudo exits 1 when it refuses to authorize, so the
/// runner never uses 1: the app can tell a failed Touch ID attempt from a runner that ran and failed.
let runnerFailureStatus: Int32 = 70 // EX_SOFTWARE

enum AuthorizationMethod {
    case touchID, password

    func needsPasswordFallback(status: Int32, exited: Bool, runnerStarted: Bool, cancelled: Bool) -> Bool {
        self == .touchID && exited && status == 1 && !runnerStarted && !cancelled
    }
}

func touchIDArguments(runner: String, socket: String, uid: UInt32) -> [String] {
    // -S permits a GUI process without a terminal, while still using pam_tid.
    // stdin is /dev/null: password authentication cannot happen on this path.
    // Do not use -A: Apple's pam_tid explicitly skips Touch ID in askpass mode.
    // -k ignores cached sudo credentials for this invocation.
    ["-k", "-S", "-p", "", "--", runner, socket, String(uid)]
}

// The fallback runs the same command through the standard macOS administrator dialog. The paths
// arrive as osascript arguments and AppleScript quotes them; they are never spliced into source.
let authorizationScript = [
    "on run argv",
    #"do shell script "exec " & quoted form of item 1 of argv & " " & quoted form of item 2 of argv"#
        + #" & " " & quoted form of item 3 of argv"#
        + #" with prompt "UW VPN needs administrator access to start the VPN tunnel.""#
        + " with administrator privileges",
    "end run",
]

func authorizationArguments(runner: String, socket: String, uid: UInt32) -> [String] {
    authorizationScript.flatMap { ["-e", $0] } + [runner, socket, String(uid)]
}
