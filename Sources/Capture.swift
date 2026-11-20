import Foundation

// Drain continuously so a long server banner cannot deadlock a subprocess.
// Only a bounded prefix is kept; this object never writes logs to disk.
// data has one writer and is read only after finished.wait().
final class Capture: @unchecked Sendable {
    let pipe = Pipe()
    private let finished = DispatchGroup()
    private var data = Data()
    private static let limit = 65_536

    init() {
        finished.enter()
        let reader = pipe.fileHandleForReading.fileDescriptor
        DispatchQueue.global().async { [self] in
            while true {
                let chunk = readChunk(reader)
                if chunk.isEmpty { break }
                data.append(chunk.prefix(max(0, Self.limit - data.count)))
            }
            finished.leave()
        }
    }
    func closeWriter() { pipe.fileHandleForWriting.closeFile() }
    func result() -> String {
        finished.wait()
        return String(decoding: data, as: UTF8.self)
    }
}
