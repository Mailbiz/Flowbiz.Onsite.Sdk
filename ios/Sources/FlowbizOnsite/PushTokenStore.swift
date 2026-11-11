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
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // 0.1.x kept the token in UserDefaults. Once: a token found there later came from a restored backup.
    private func migrate() {
        if migrated { return }
        migrated = true
        if let old = legacy.string(forKey: StorageKeys.pushToken), !FileManager.default.fileExists(atPath: fileURL.path) {
            write(old)
        }
        legacy.removeValue(forKey: StorageKeys.pushToken)
    }

    private func write(_ token: String) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: fileURL, options: .atomic)
        } catch {
            SdkLog.debug("push token write failed")
        }
    }
}
