#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct EventQueueSuite {

    private let file = temporaryQueueFile()

    private func entry(_ n: Int) -> String {
        "{\"event\":\"e\(n)\",\"hash\":\"h\(n)\"}"
    }

    private func fileText() throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    @Test func appendPeekRoundTripPreservesOrder() {
        let queue = EventQueue(fileURL: file)
        (1...5).forEach { queue.append(entry($0)) }
        #expect(queue.size == 5)
        #expect(queue.peek(10) == (1...5).map { entry($0) })
        #expect(queue.size == 5)
        #expect(queue.peek(2) == [entry(1), entry(2)])
    }

    @Test func queueSurvivesReload() {
        let queue = EventQueue(fileURL: file)
        (1...3).forEach { queue.append(entry($0)) }
        let reloaded = EventQueue(fileURL: file)
        #expect(reloaded.peek(10) == (1...3).map { entry($0) })
    }

    @Test func removeOldestConsumesFromTheHead() {
        let queue = EventQueue(fileURL: file)
        (1...4).forEach { queue.append(entry($0)) }
        queue.removeOldest(2)
        #expect(queue.peek(10) == [entry(3), entry(4)])
    }

    @Test func truncatedAndGarbageLinesAreSkippedNotFatal() throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let content = entry(1) + "\n"
            + "{\"event\":\"trunca" + "\n"
            + "not json at all\n"
            + "\n"
            + entry(2) + "\n"
            + "{\"event\":\"e3\",\"ha"
        try Data(content.utf8).write(to: file)
        let queue = EventQueue(fileURL: file)
        #expect(queue.peek(10) == [entry(1), entry(2)])
        #expect(try fileText() == entry(1) + "\n" + entry(2) + "\n")
    }

    @Test func unreadableStateStartsEmpty() throws {
        // A directory where the file should be → read fails.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let queue = EventQueue(fileURL: file)
        #expect(queue.size == 0)
    }

    @Test func capacityDropsOldestOnAppend() {
        let queue = EventQueue(fileURL: file, capacity: 5)
        (1...8).forEach { queue.append(entry($0)) }
        #expect(queue.size == 5)
        #expect(queue.peek(10) == (4...8).map { entry($0) })
    }

    @Test func overCapacityFileIsTrimmedToNewestAtLoad() {
        let queue = EventQueue(fileURL: file, capacity: 10)
        (1...10).forEach { queue.append(entry($0)) }
        let smaller = EventQueue(fileURL: file, capacity: 4)
        #expect(smaller.peek(10) == (7...10).map { entry($0) })
    }

    @Test func compactionTriggersAtStaleThresholdAndPreservesOrder() throws {
        let queue = EventQueue(fileURL: file)
        let total = EventQueue.compactStaleThreshold + 6
        (1...total).forEach { queue.append(entry($0)) }
        queue.removeOldest(EventQueue.compactStaleThreshold)
        let expected = ((EventQueue.compactStaleThreshold + 1)...total).map { entry($0) }
        #expect(queue.peek(100) == expected)
        #expect(try fileText() == expected.map { $0 + "\n" }.joined())
    }

    @Test func belowThresholdConsumedLinesStayInFileUntilCompaction() throws {
        let queue = EventQueue(fileURL: file)
        (1...6).forEach { queue.append(entry($0)) }
        queue.removeOldest(2)
        let lines = try fileText().split(separator: "\n")
        #expect(lines.count == 6)
        #expect(queue.peek(10) == [entry(3), entry(4), entry(5), entry(6)])
    }

    @Test func drainingToEmptyTruncatesTheFile() throws {
        let queue = EventQueue(fileURL: file)
        (1...3).forEach { queue.append(entry($0)) }
        queue.removeOldest(3)
        #expect(queue.size == 0)
        #expect(try fileText().isEmpty)
    }

    @Test func leftoverTmpFromCrashedCompactionIsIgnoredAndOriginalIntact() throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data((entry(1) + "\n" + entry(2) + "\n").utf8).write(to: file)
        let tmp = URL(fileURLWithPath: file.path + ".tmp")
        try Data((entry(99) + "\n").utf8).write(to: tmp)
        let queue = EventQueue(fileURL: file)
        #expect(queue.peek(10) == [entry(1), entry(2)])
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        #expect(try fileText() == entry(1) + "\n" + entry(2) + "\n")
    }

    @Test func entriesWithRawNewlinesAreRejected() {
        let queue = EventQueue(fileURL: file)
        queue.append("{\"a\":1}\n{\"b\":2}")
        queue.append("   ")
        #expect(queue.size == 0)
        queue.append(entry(1))
        #expect(queue.peek(10) == [entry(1)])
    }

    @Test func appendCreatesMissingDirectories() {
        let queue = EventQueue(fileURL: file)
        queue.append(entry(1))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(EventQueue(fileURL: file).peek(10) == [entry(1)])
    }

    @Test func failedAppendForcesRewriteSoATornTailCannotMergeWithTheNextAppend() throws {
        let queue = EventQueue(fileURL: file)
        queue.append(entry(1))
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent()
        // Read-only directory too: it blocks the healing compaction's tmp file.
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        queue.append(entry(2))
        queue.append(entry(3))
        #expect(queue.size == 3)
        #expect(try fileText() == entry(1) + "\n")

        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        queue.append(entry(4))
        #expect(EventQueue(fileURL: file).peek(10) == (1...4).map { entry($0) })
    }

    @Test func defaultQueueDirectoryIsExcludedFromBackup() throws {
        let appId = "backup-test-\(UUID().uuidString)"
        let url = try #require(EventQueue.defaultFileURL(appId: appId))
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(url.lastPathComponent == "queue.jsonl")
        #expect(directory.lastPathComponent == appId)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func entriesOlderThanSevenDaysAreDroppedOnLoad() throws {
        let now: Int64 = 1_700_000_000_000
        func aged(_ name: String, _ ageMillis: Int64) -> String {
            #"{"event":"\#(name)","timings":{"created_at":"\#(EnvelopeBuilder.isoMillis(now - ageMillis))"}}"#
        }
        let stale = aged("stale", EventQueue.maxAgeMillis + 1)
        let kept = [
            aged("at-the-limit", EventQueue.maxAgeMillis),
            aged("fresh", minuteMs),
            aged("clock-moved-back", -24 * 60 * minuteMs),
            entry(1), // no created_at to judge by
            #"{"event":"unreadable","timings":{"created_at":"yesterday"}}"#,
        ]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(([stale] + kept + [stale]).map { $0 + "\n" }.joined().utf8).write(to: file)

        let queue = EventQueue(fileURL: file, nowMillis: { now })
        #expect(queue.peek(10) == kept)
        #expect(try fileText() == kept.map { $0 + "\n" }.joined())
    }

    @Test func ageIsJudgedOnLoadOnlyNeverOnAppend() {
        let now: Int64 = 1_700_000_000_000
        let queue = EventQueue(fileURL: file, nowMillis: { now })
        let old = #"{"event":"old","timings":{"created_at":"\#(EnvelopeBuilder.isoMillis(now - 30 * 24 * 60 * minuteMs))"}}"#
        queue.append(old)
        #expect(queue.peek(10) == [old])
    }
}
#endif
