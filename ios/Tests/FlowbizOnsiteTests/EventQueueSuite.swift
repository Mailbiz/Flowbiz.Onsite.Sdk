// SPEC §9 durable queue: JSONL round-trip, truncation tolerance, drop-oldest
// cap, compaction (threshold + atomic replace), order preservation.
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

    // MARK: Round-trip & order

    @Test func appendPeekRoundTripPreservesOrder() {
        let queue = EventQueue(fileURL: file)
        (1...5).forEach { queue.append(entry($0)) }
        #expect(queue.size == 5)
        #expect(queue.peek(10) == (1...5).map { entry($0) })
        // peek does not consume
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

    // MARK: Corruption tolerance (SPEC §3/§9)

    @Test func truncatedAndGarbageLinesAreSkippedNotFatal() throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let content = entry(1) + "\n"
            + "{\"event\":\"trunca" + "\n" // crash mid-write
            + "not json at all\n"
            + "\n"
            + entry(2) + "\n"
            + "{\"event\":\"e3\",\"ha" // truncated final line, no newline
        try Data(content.utf8).write(to: file)
        let queue = EventQueue(fileURL: file)
        #expect(queue.peek(10) == [entry(1), entry(2)])
        // Stale garbage found at load forces an immediate compaction:
        // the file now holds exactly the surviving lines.
        #expect(try fileText() == entry(1) + "\n" + entry(2) + "\n")
    }

    @Test func unreadableStateStartsEmpty() throws {
        // A directory where the file should be → reads fail, queue degrades.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let queue = EventQueue(fileURL: file)
        #expect(queue.size == 0)
    }

    // MARK: Capacity (SPEC §9: 1000 drop-oldest; capacity injected for tests)

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

    // MARK: Compaction

    @Test func compactionTriggersAtStaleThresholdAndPreservesOrder() throws {
        let queue = EventQueue(fileURL: file)
        let total = EventQueue.compactStaleThreshold + 6
        (1...total).forEach { queue.append(entry($0)) }
        queue.removeOldest(EventQueue.compactStaleThreshold)
        // Threshold reached → file rewritten to exactly the pending suffix.
        let expected = ((EventQueue.compactStaleThreshold + 1)...total).map { entry($0) }
        #expect(queue.peek(100) == expected)
        #expect(try fileText() == expected.map { $0 + "\n" }.joined())
    }

    @Test func belowThresholdConsumedLinesStayInFileUntilCompaction() throws {
        let queue = EventQueue(fileURL: file)
        (1...6).forEach { queue.append(entry($0)) }
        queue.removeOldest(2)
        // Logical removal only — durability model keeps the lines (at-least-once).
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

    // MARK: Compaction crash safety (write tmp, then atomic replace)

    @Test func leftoverTmpFromCrashedCompactionIsIgnoredAndOriginalIntact() throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data((entry(1) + "\n" + entry(2) + "\n").utf8).write(to: file)
        // Simulated crash between tmp write and replace: tmp holds a stale,
        // partial rewrite. The original must win.
        let tmp = URL(fileURLWithPath: file.path + ".tmp")
        try Data((entry(99) + "\n").utf8).write(to: tmp)
        let queue = EventQueue(fileURL: file)
        #expect(queue.peek(10) == [entry(1), entry(2)])
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        #expect(try fileText() == entry(1) + "\n" + entry(2) + "\n")
    }

    // MARK: Defensive input handling

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
}
#endif
