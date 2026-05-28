import Foundation

/// File-based diagnostic logger for AudioSyncApp.
/// Writes to ~/Library/Logs/AudioSyncApp.log, overwritten on each launch.
/// Thread-safe via serial dispatch queue.
final class DiagLog {
    static let shared = DiagLog()

    private let logURL: URL
    private let queue = DispatchQueue(label: "com.audiosync.diaglog", qos: .utility)
    private var handle: FileHandle?
    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        logURL = dir.appendingPathComponent("AudioSyncApp.log")

        // Create/truncate the file
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)

        write("=== AudioSyncApp Log — \(Date()) ===")
    }

    /// Write a line to the log file. Thread-safe.
    func write(_ message: String) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            var data = message.data(using: .utf8) ?? Data()
            data.append(UInt8(0x0A))
            handle.write(data)
        }
    }

    /// Write a line synchronously (use sparingly — blocks calling thread).
    func writeSync(_ message: String) {
        queue.sync { [weak self] in
            guard let self, let handle = self.handle else { return }
            var data = message.data(using: .utf8) ?? Data()
            data.append(UInt8(0x0A))
            handle.write(data)
        }
    }

    deinit {
        handle?.closeFile()
    }
}
  // DLog: Fix delay compensation calculation
/// Convenience logging functions
func DLog(_ message: String, file: String = #file, line: Int = #line) {
    let filename = (file as NSString).lastPathComponent
    DiagLog.shared.write("[\(filename):\(line)] \(message)")
}

func DLogSync(_ message: String, file: String = #file, line: Int = #line) {
    let filename = (file as NSString).lastPathComponent
    DiagLog.shared.writeSync("[\(filename):\(line)] \(message)")
}
