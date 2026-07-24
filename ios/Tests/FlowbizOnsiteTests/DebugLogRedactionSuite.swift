// SPEC §12: `debug` logging never prints PII. Pins the invariant end-to-end
// with the debug sink captured — logs carry wire event names, counts, codes
// and reasons only, never `data` payload strings or tokens.
//
// This suite is `.serialized` and deliberately hosts *every* test that
// installs the process-global `SdkLog.sink` (the redaction pin and the
// pre-init purity pin), so no two sink installations can clobber each
// other. Other suites run in parallel and may log through an installed sink
// concurrently; the assertions here are written to be immune to that
// cross-talk (targeted absence checks, never strict emptiness).
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

/// Thread-safe capture sink for `SdkLog`.
final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ message: String) {
        lock.lock()
        stored.append(message)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite(.serialized) struct DebugLogRedactionSuite {

    @Test func trackedPiiNeverAppearsInCapturedDebugLogs() throws {
        let email = "pii-probe.email@example.com"
        let phone = "+5511987654321"
        let name = "Maria da Silva Probe"
        let token = "pii-secret-apns-token-XYZ123"

        let capture = LogCapture()
        SdkLog.sink = { capture.append($0) }
        defer { SdkLog.sink = nil }

        let harness = CoreHarness()
        let user = User(userId: "u-77", email: email, phone: phone, name: name)
        harness.core.track(.accountLogin(user: user))
        harness.core.track(.accountLogin(user: user)) // dedup-suppression log path
        harness.core.setPushToken(token)
        harness.core.setPushToken(token) // dedup-suppression log path for the token event
        harness.core.track(.productView( // serialization-failure (dropped event) log path
            product: Product(productId: "P1", variants: [ProductVariant(sku: "S1", price: .nan)])
        ))
        harness.core.setEnabled(false)
        harness.core.track(.accountSync(user: user)) // disabled-drop log path
        harness.core.setEnabled(true) // re-enable + stored-token re-emit path
        harness.core.removePushToken()
        harness.core.setPushToken(token)
        harness.core.logout() // logout removal + summary log path
        harness.core.flush()

        let messages = capture.messages
        #expect(!messages.isEmpty, "scenario must produce debug logs")
        for pii in [email, phone, name, token] {
            let leaks = messages.filter { $0.contains(pii) }
            #expect(leaks.isEmpty, "debug log leaked PII '\(pii)' in: \(leaks)")
        }
    }

    /// SPEC §3: `handlePush`/`handleLink` are pure functions — they *work*
    /// before initialize (real result, no "initialize was not called"
    /// warning), unlike the pipeline entry points. Mirrors the Android
    /// facade smoke test; the assertion targets the pure handlers' names so
    /// parallel suites logging through the sink cannot produce false
    /// failures.
    @Test func pureHandlersWorkBeforeInitializeWithoutWarnings() {
        let capture = LogCapture()
        SdkLog.sink = { capture.append($0) }
        defer { SdkLog.sink = nil }

        let push = Flowbiz.handlePush(["flowbiz": #"{"v":1,"type":"promo","title":"t"}"#])
        #expect(push?.type == "promo")
        #expect(Flowbiz.handlePush(["other": "x"]) == nil)
        #expect(Flowbiz.handleLink(nil) == nil)
        #expect(Flowbiz.handleLink(URL(string: "https://store.com/?x=1")) == nil)
        // Pure: neither handler may route through the core lookup that logs
        // "Flowbiz.<name> ignored: initialize was not called".
        let handlerWarnings = capture.messages.filter {
            $0.contains("handlePush") || $0.contains("handleLink")
        }
        #expect(handlerWarnings.isEmpty, "pure handlers logged warnings: \(handlerWarnings)")
    }
}
#endif
