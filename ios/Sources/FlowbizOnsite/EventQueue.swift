import Foundation

// At-least-once: removed lines stay in the file until compaction; `hash` is the collector's idempotency key.
final class EventQueue {

    static let defaultCapacity = 1000
    static let compactStaleThreshold = 64

    private let fileURL: URL
    private let tmpURL: URL
    private let capacity: Int
    private var pending: [String] = []

    private var staleLines = 0

    // A failed append may leave a torn tail that would fuse with the next line: rewrite until compacted.
    private var fileDirty = false

    init(fileURL: URL, capacity: Int = EventQueue.defaultCapacity) {
        self.fileURL = fileURL
        self.tmpURL = URL(fileURLWithPath: fileURL.path + ".tmp")
        self.capacity = capacity
        load()
    }

    var size: Int { pending.count }

    func peek(_ max: Int) -> [String] {
        guard max > 0, !pending.isEmpty else { return [] }
        return Array(pending.prefix(max))
    }

    func append(_ entry: String) {
        guard !entry.contains("\n"), !entry.contains("\r"),
              !entry.trimmingCharacters(in: .whitespaces).isEmpty else {
            SdkLog.debug("queue rejected malformed entry")
            return
        }
        if pending.count >= capacity {
            pending.removeFirst()
            staleLines += 1
            SdkLog.debug("queue at capacity \(capacity), dropped oldest event")
        }
        pending.append(entry)
        if fileDirty {
            compact()
        } else if !appendToFile(entry) {
            fileDirty = true
            compact()
        }
        compactIfNeeded()
    }

    func removeOldest(_ count: Int) {
        let removable = min(count, pending.count)
        if removable > 0 {
            pending.removeFirst(removable)
            staleLines += removable
        }
        compactIfNeeded()
    }

    private func load() {
        let manager = FileManager.default
        // A leftover tmp is a compaction that crashed before replace; the original is authoritative.
        if manager.fileExists(atPath: tmpURL.path) {
            try? manager.removeItem(at: tmpURL)
        }
        guard manager.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            SdkLog.debug("queue load failed, starting empty")
            return
        }
        let content = String(decoding: data, as: UTF8.self)
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            if isParseable(line) {
                pending.append(line)
            } else {
                staleLines += 1
            }
        }
        if pending.count > capacity {
            staleLines += pending.count - capacity
            pending.removeFirst(pending.count - capacity)
        }
        if staleLines > 0 { compact() }
    }

    private func appendToFile(_ entry: String) -> Bool {
        ensureDirectory()
        // OutputStream, not FileHandle: legacy FileHandle writes raise uncatchable ObjC exceptions.
        guard let stream = OutputStream(url: fileURL, append: true) else {
            SdkLog.debug("queue append open failed")
            return false
        }
        stream.open()
        defer { stream.close() }
        guard stream.streamStatus == .open else {
            SdkLog.debug("queue append open failed")
            return false
        }
        let bytes = Array((entry + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return stream.write(base + written, maxLength: bytes.count - written)
            }
            if count <= 0 {
                SdkLog.debug("queue append write failed")
                return false
            }
            written += count
        }
        return true
    }

    private func compactIfNeeded() {
        if staleLines >= Self.compactStaleThreshold || (staleLines > 0 && pending.isEmpty) {
            compact()
        }
    }

    private func compact() {
        do {
            ensureDirectory()
            let content = pending.map { $0 + "\n" }.joined()
            try Data(content.utf8).write(to: tmpURL, options: [])
            let manager = FileManager.default
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: tmpURL)
            } else {
                try manager.moveItem(at: tmpURL, to: fileURL)
            }
            staleLines = 0
            fileDirty = false
        } catch {
            SdkLog.debug("queue compaction failed")
        }
    }

    private func ensureDirectory() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func isParseable(_ line: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any]
    }

    static func defaultFileURL(appId: String) -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            var directory = base
                .appendingPathComponent("flowbiz_onsite", isDirectory: true)
                .appendingPathComponent(appId, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            return directory.appendingPathComponent("queue.jsonl")
        } catch {
            SdkLog.debug("queue directory unavailable")
            return nil
        }
    }
}
