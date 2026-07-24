import Foundation

/// Durable event queue (SPEC §9): JSON Lines file, one serialized envelope
/// entry per line, append-only.
///
/// ## Model
/// An in-memory array of pending lines mirrors the file; the file may
/// additionally contain **stale** lines (consumed after a successful flush,
/// dropped at the capacity cap, or unparseable garbage) that are purged only
/// at compaction. Appends are O(1) (open-append-close via `OutputStream`);
/// consumption is logical (head of the array) until compaction rewrites the
/// file.
///
/// ## Durability & crash behavior
/// - A crash mid-append costs one truncated line; unparseable/blank lines
///   are skipped (and counted stale) at load, never fatal (SPEC §3/§9).
/// - Compaction writes `queue.jsonl.tmp` then atomically replaces the
///   original (`FileManager.replaceItemAt`) — a crash between write and
///   replace leaves the original intact; the leftover tmp is deleted at next
///   load.
/// - Delivery is at-least-once: consumed-but-not-yet-compacted lines (and,
///   rarely, capacity-dropped ones) resend after a process death. `hash` is
///   the collector-side idempotency key (SPEC §9).
///
/// ## Compaction trigger
/// Compacts when the stale-line count reaches `compactStaleThreshold`, and
/// eagerly whenever the queue drains empty (a cheap truncate — the common
/// "successful flush" case, per SPEC §9), and at load when any stale line
/// was found.
///
/// ## Concurrency
/// **Thread-confined** to the SDK's serial `TaskScheduler` queue — no
/// internal locking, no file locking. Single-process access is a SPEC §9
/// assumption. Never throws: I/O failures log and degrade to memory-only
/// behavior for the session.
///
/// The backing `fileURL` is injected (tests use temp dirs);
/// `defaultFileURL(appId:)` provides the production location in Application
/// Support, excluded from iCloud backup.
final class EventQueue {

    /// SPEC §9: 1000 events, drop-oldest. Internal constant, not a knob.
    static let defaultCapacity = 1000

    /// Stale lines tolerated in the file before a rewrite is forced.
    static let compactStaleThreshold = 64

    private let fileURL: URL
    private let tmpURL: URL
    private let capacity: Int
    private var pending: [String] = []

    /// Lines present in the file but no longer pending (consumed/dropped/garbage).
    private var staleLines = 0

    /// Set when an append failed or may have written a torn tail line.
    /// While dirty, plain file appends are unsafe — a partially-written tail
    /// without its newline would merge with the next appended entry into one
    /// garbage line — so the next write goes through a full `compact()`
    /// (rewrite from `pending`) instead; a successful compaction clears it.
    private var fileDirty = false

    init(fileURL: URL, capacity: Int = EventQueue.defaultCapacity) {
        self.fileURL = fileURL
        self.tmpURL = URL(fileURLWithPath: fileURL.path + ".tmp")
        self.capacity = capacity
        load()
    }

    /// Number of pending (not yet delivered) entries.
    var size: Int { pending.count }

    /// Oldest-first snapshot of up to `max` pending entries; the queue is unchanged.
    func peek(_ max: Int) -> [String] {
        guard max > 0, !pending.isEmpty else { return [] }
        return Array(pending.prefix(max))
    }

    /// Appends one serialized envelope entry. At capacity the oldest pending
    /// entry is dropped first (SPEC §9 drop-oldest). Entries containing raw
    /// newlines are rejected (canonical JSON never has them — defensive only).
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
            // A previous append tore the tail — rewrite instead of appending.
            compact()
        } else if !appendToFile(entry) {
            fileDirty = true
            compact() // heal immediately when possible
        }
        compactIfNeeded()
    }

    /// Removes the `count` oldest pending entries (a delivered or poison batch).
    func removeOldest(_ count: Int) {
        let removable = min(count, pending.count)
        if removable > 0 {
            pending.removeFirst(removable)
            staleLines += removable
        }
        compactIfNeeded()
    }

    // MARK: - File I/O (never throws out of this class)

    private func load() {
        let manager = FileManager.default
        // A leftover tmp means a compaction crashed between write and
        // replace; the original is authoritative.
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
        // Over-capacity file (e.g. cap lowered, or drop-oldest lines
        // resurrected after a crash): drop-oldest to the cap.
        if pending.count > capacity {
            staleLines += pending.count - capacity
            pending.removeFirst(pending.count - capacity)
        }
        if staleLines > 0 { compact() }
    }

    /// Returns false on any failure — including a *partial* write, which
    /// leaves a torn tail line the caller must mark dirty.
    private func appendToFile(_ entry: String) -> Bool {
        ensureDirectory()
        // OutputStream (append mode) creates the file when missing and
        // reports failure via return codes — no uncatchable ObjC exceptions
        // (unlike legacy FileHandle writes; SPEC §3 never-crash).
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

    /// Rewrites the file to exactly the pending entries (write tmp, atomic replace).
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
            // Original file untouched on failure; stale lines are retried at
            // the next trigger and at worst resend after a restart.
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

    // MARK: - Production location

    /// Production queue location:
    /// `Application Support/flowbiz_onsite/<appId>/queue.jsonl`. Creates the
    /// directories and excludes them from iCloud backup (tracking state must
    /// not restore onto a new device). Nil when Application Support is
    /// unavailable (degrades to a memory-only queue in Slice 4).
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
