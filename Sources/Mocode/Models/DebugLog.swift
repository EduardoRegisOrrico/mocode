import Foundation

actor DebugLog {
    static let shared = DebugLog()

    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated static var fileName: String { "mocode-debug.log" }

    nonisolated static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        NSLog("%@", line)

        guard let url = Self.logURL else { return }
        let data = Data((line + "\n").utf8)

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                NSLog("[DEBUG_LOG] append failed: %@", error.localizedDescription)
            }
        } else {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[DEBUG_LOG] create failed: %@", error.localizedDescription)
            }
        }
    }

    func reset() {
        guard let url = Self.logURL else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            NSLog("[DEBUG_LOG] reset failed: %@", error.localizedDescription)
        }
    }
}
