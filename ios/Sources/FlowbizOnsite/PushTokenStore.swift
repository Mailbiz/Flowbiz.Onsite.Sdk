import Foundation

// In a file excluded from backups, not in UserDefaults: a token restored on another phone is not that
// phone's, and logout() would send the removal of the old phone's token. Confined to the SDK queue.
final class PushTokenStore: @unchecked Sendable {

    // Lazy: resolving the directory may touch the disk, which must stay off the caller's thread.
    private let fileURLFactory: () -> URL
    private lazy var fileURL = fileURLFactory()
    private let legacy: any KeyValueStore
    private var migrated = false

    init(fileURL: @escaping () -> URL, legacy: any KeyValueStore) {
        self.fileURLFactory = fileURL
        self.legacy = legacy
    }

    var token: String? {
        migrate()
        guard let token = try? String(contentsOf: fileURL, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    func set(_ token: String) {
        migrate()
        write(token)
    }

    func clear() {
        migrate()
        // Also a token the migration could not move: it must not come back at the next start.
        legacy.removeValue(forKey: StorageKeys.pushToken)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // 0.1.x kept the token in UserDefaults. Once: a token found there later came from a restored backup.
    // A write that fails (full disk, a launch before first unlock) keeps it there for the next start.
    private func migrate() {
        if migrated { return }
        migrated = true
        if let old = legacy.string(forKey: StorageKeys.pushToken), !FileManager.default.fileExists(atPath: fileURL.path) {
            guard write(old) else { return }
        }
        legacy.removeValue(forKey: StorageKeys.pushToken)
    }

    @discardableResult
    private func write(_ token: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: fileURL, options: .atomic)
            return true
        } catch {
            SdkLog.debug("push token write failed")
            return false
        }
    }
}
