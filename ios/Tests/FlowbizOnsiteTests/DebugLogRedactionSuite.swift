// `debug` logging never prints PII: logs carry wire event names, counts,
// codes and reasons only, never `data` payload strings or tokens.
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

    /// UTM lines are fixed reasons and counts: never the link (its `_mb_cr_`
    /// carries the user id), a key or a value.
    @Test func utmLogsNeverCarryALinkAKeyOrAValue() {
        let link = "https://store.com/carrinho?_mb_cr_=eyJ0IjoiNzc3NzciLCJ1IjoiUTd4In0&utm_source=Q7xsrc" +
            "&utm_campaign=Q7x%20c&utm_flow_params=Q7xs|Q7xv|Q7xi"
        let capture = LogCapture()
        SdkLog.sink = { capture.append($0) }
        defer { SdkLog.sink = nil }

        let h = CoreHarness()
        _ = Flowbiz.handleLink(link, core: h.core)
        h.clock.advance(UtmStore.ttlMillis)
        h.core.onForeground()
        h.store[StorageKeys.utmData] = #"[["utm_source","Q7xsrc"]"#
        h.store[StorageKeys.utmExpiresAtWallMs] = h.clock.wall + 1
        _ = Flowbiz.handleLink(link, core: h.core)

        let shapes = ["utm context: # captured, # active", "stored utm discarded: expired", "stored utm discarded: corrupt"]
        let utmLines = capture.messages.filter { $0.contains("utm") }
        for line in ["utm context: 5 captured, 5 active", "stored utm discarded: expired", "stored utm discarded: corrupt"] {
            #expect(utmLines.contains(line), "missing '\(line)' in \(utmLines)")
        }
        for line in utmLines {
            #expect(shapes.contains(line.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)), "\(line)")
        }
        #expect(!capture.messages.contains { $0.contains("Q7x") || $0.contains("eyJ0") || $0.contains("utm_") })
    }

    /// Only the handlers' own warnings count: parallel suites share the sink.
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

    /// Through the seam with no core: the one real `initialize` below may
    /// already have installed the global one.
    @Test func beforeInitializeALinkIsOnlyDecoded() throws {
        let capture = LogCapture()
        SdkLog.sink = { capture.append($0) }
        defer { SdkLog.sink = nil }

        let link = try UtmLinkParserSuite.extractVector("messagebuilder_journey_cart_recovery").url
        #expect(Flowbiz.handleLink(link, core: nil)?.cartId == "cart-abc-001")
        #expect(Flowbiz.handlePushOpened(nil) == nil)
        #expect(!capture.messages.contains { $0.contains("handleLink") || $0.contains("handlePushOpened") })
    }

    /// The tests' only real `initialize` (first config wins forever). The sink
    /// starts nil and the capture replaces `Flowbiz.debugSink`: pre-installing
    /// `SdkLog.sink` would catch the warnings whatever the ordering.
    @Test func initializeLogsConfigSanitizerWarningsToSink() {
        #expect(SdkLog.sink == nil, "precondition: no other test may have installed a sink yet")
        let capture = LogCapture()
        let originalDebugSink = Flowbiz.debugSink
        Flowbiz.debugSink = { capture.append($0) }
        defer {
            Flowbiz.debugSink = originalDebugSink
            SdkLog.sink = nil
        }
        Flowbiz.initialize(FlowbizConfig(appId: "77777", baseUri: "not a url", debug: true))
        let messages = capture.messages
        #expect(messages.contains { $0.contains("invalid baseUri") }, "messages: \(messages)")
    }
}
#endif
