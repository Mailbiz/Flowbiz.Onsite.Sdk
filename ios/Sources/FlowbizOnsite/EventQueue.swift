import Foundation

// At-least-once: removed lines stay in the file until compaction, so a crash can re-send delivered events
// (the collector does not deduplicate on `hash`).
// Shared by two queues: the SDK's appends while the transport's peeks, sends and removes.
final class EventQueue: @unchecked Sendable {

    /// A prefix of the queue as `peek` saw it.
    struct Batch {
        let entries: [String]
        fileprivate let endSequence: Int64
    }

    static let defaultCapacity = 1000
    static let compactStaleThreshold = 64

    // Applied when the queue loads. The web out-queue has no max age; 7 days is the SDK's own rule.
    static let maxAgeMillis: Int64 = 7 * 24 * 60 * 60 * 1000

    private let fileURL: URL
    private let tmpURL: URL
    private let capacity: Int
    private let lock = NSLock()
    private var pending: [String] = []

    // Sequence number of the head: entries evicted at capacity while a batch is in flight are not removed twice.
    private var headSequence: Int64 = 0

    private var staleLines = 0

    // A failed append may leave a torn tail that would fuse with the next line: rewrite until compacted.
    private var fileDirty = false

    init(
        fileURL: URL,
        capacity: Int = EventQueue.defaultCapacity,
        nowMillis: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.fileURL = fileURL
        self.tmpURL = URL(fileURLWithPath: fileURL.path + ".tmp")
        self.capacity = capacity
        load(nowMillis: nowMillis())
    }

    var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func peek(_ max: Int) -> Batch {
        lock.lock()
        defer { lock.unlock() }
        let entries = Array(pending.prefix(Swift.max(max, 0)))
        return Batch(entries: entries, endSequence: headSequence + Int64(entries.count))
    }

    func append(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !entry.contains("\n"), !entry.contains("\r"),
              !entry.trimmingCharacters(in: .whitespaces).isEmpty else {
            SdkLog.debug("queue rejected malformed entry")
            return
        }
        if pending.count >= capacity {
            pending.removeFirst()
            headSequence += 1
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

    /// Removes what is still queued of `batch`.
    func remove(_ batch: Batch) {
        lock.lock()
        defer { lock.unlock() }
        let removable = Int(min(batch.endSequence - headSequence, Int64(pending.count)))
        if removable > 0 {
            pending.removeFirst(removable)
            headSequence += Int64(removable)
            staleLines += removable
        }
        compactIfNeeded()
    }

    private func load(nowMillis: Int64) {
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
        // An event delivered weeks late would move its cart's last update: created_at is what the backend reads.
        let oldest = nowMillis - Self.maxAgeMillis
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var expired = 0
        let content = String(decoding: data, as: UTF8.self)
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                staleLines += 1
                continue
            }
            // An entry without a readable created_at never expires.
            let createdAt = ((entry["timings"] as? [String: Any])?["created_at"] as? String).flatMap(iso.date(from:))
            if let createdAt, Int64(createdAt.timeIntervalSince1970 * 1000) < oldest {
                expired += 1
            } else {
                pending.append(line)
            }
        }
        if expired > 0 {
            staleLines += expired
            SdkLog.debug("queue dropped \(expired) events older than \(Self.maxAgeMillis / 86_400_000) days")
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
            // Apple documents this flag for backups only; nothing is assumed about a direct device transfer.
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            return directory.appendingPathComponent("queue.jsonl")
        } catch {
            SdkLog.debug("queue directory unavailable")
            return nil
        }
    }
}
