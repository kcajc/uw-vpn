import Foundation
import Darwin

// A per-connection Unix socket: its private directory is 0700; the socket is 0600.
// Peer UIDs are checked at both ends. Passwords never cross this connection.
// Exactly one receive loop per channel; concurrent writes are locked. shutdown
// wakes that loop; the descriptor is closed only when its last owner releases it.
final class Channel: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()
    private let writeLock = NSLock()

    init(_ fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }
    deinit { Darwin.close(fd) }
    func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }

    func checkPeer(uid expected: uid_t) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == expected else {
            throw VPNError("Unexpected control-socket peer.")
        }
    }

    func send(_ message: Message) throws {
        var data = try JSONEncoder().encode(message)
        data.append(10)
        guard data.count <= 131_072 else { throw VPNError("Control message too large.") }
        writeLock.lock()
        defer { writeLock.unlock() }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VPNError("Control connection closed.") }
                offset += count
            }
        }
    }

    func receive() throws -> Message {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: newline) < 131_072 else {
                    throw VPNError("Control message too large.")
                }
                let line = buffer[..<newline]
                let message = try JSONDecoder().decode(Message.self, from: line)
                buffer.removeSubrange(...newline)
                return message
            }
            guard buffer.count < 131_072 else { throw VPNError("Control message too large.") }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw VPNError("Control connection closed.") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    static func connect(path: String) throws -> Channel {
        let channel = Channel(Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
        guard channel.fd >= 0 else { throw VPNError("Cannot create control socket.") }
        let result = try withAddress(path) { Darwin.connect(channel.fd, $0, $1) }
        guard result == 0 else { throw VPNError("Cannot connect to the app's control socket.") }
        return channel
    }
}

private func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw VPNError("Control-socket path is too long.")
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

final class Listener: @unchecked Sendable {
    let directory: String
    let path: String
    private let socket: Channel
    private let lock = NSLock()
    private var cancelled = false

    init() throws {
        var template = Array("/tmp/uw-vpn.XXXXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw VPNError("Cannot create private socket directory.") }
        directory = String(cString: created)
        path = directory + "/control"
        socket = Channel(Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
        guard socket.fd >= 0 else { throw VPNError("Cannot create listening socket.") }
        let result = try withAddress(path) { Darwin.bind(socket.fd, $0, $1) }
        guard result == 0, chmod(path, 0o600) == 0, listen(socket.fd, 1) == 0 else {
            throw VPNError("Cannot listen on private control socket.")
        }
    }
    deinit { unlink(path); rmdir(directory) }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        socket.shutdown()
    }

    func acceptRoot() throws -> Channel {
        // poll keeps cancellation bounded even on systems where shutdown does
        // not wake a blocking accept on a listening Unix socket.
        while true {
            lock.lock(); let cancelled = cancelled; lock.unlock()
            if cancelled { throw VPNError("Authorization was cancelled.") }
            var descriptor = pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw VPNError("Control-socket polling failed.") }
            if ready > 0 {
                guard descriptor.revents & Int16(POLLIN) != 0 else {
                    throw VPNError("Authorization was cancelled.")
                }
                break
            }
        }
        let fd = Darwin.accept(socket.fd, nil, nil)
        guard fd >= 0 else { throw VPNError("Authorization was cancelled.") }
        let channel = Channel(fd)
        #if TESTING
        try channel.checkPeer(uid: getuid())
        #else
        try channel.checkPeer(uid: 0)
        #endif
        return channel
    }
}
