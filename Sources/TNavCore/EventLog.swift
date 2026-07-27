import Foundation

/// Append-only diagnostic log with a size cap.
///
/// Its main job is self-documenting the unknown: Phase 0 only observed
/// `notification_type == "idle_prompt"`, so any other value gets recorded here and the real
/// string reveals itself during normal use instead of being guessed at.
public enum EventLog {
    public static let maxBytes = 256_000

    public static func append(_ message: String, to url: URL = Paths.eventLog) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }

        trimIfNeeded(url: url)
    }

    private static func trimIfNeeded(url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes,
              let contents = try? Data(contentsOf: url)
        else { return }
        let keep = contents.suffix(maxBytes / 2)
        // Start the trimmed file at a line boundary so the first entry isn't a fragment.
        if let newlineIndex = keep.firstIndex(of: 0x0A) {
            try? keep[(newlineIndex + 1)...].write(to: url, options: .atomic)
        } else {
            try? keep.write(to: url, options: .atomic)
        }
    }
}
