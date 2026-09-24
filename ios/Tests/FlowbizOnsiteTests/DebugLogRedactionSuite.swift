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

    /// SPEC §12 / §11.1: UTM evaluation logs carry counts and reasons only —
    /// never the link (its `_mb_cr_` carries the user id), a UTM key=value
    /// or the `context.utm` JSON — on every path: capture, foreground,
    /// disabled capture, re-enable, a link without UTMs, and corrupt and
    /// expired stored state. Mirrors Android's
    /// `utmCaptureLogsNeverContainTheLinkOrItsValues`, log strings included
    /// (the platforms log identical messages).
    @Test func utmCaptureLogsCarryCountsOnly() {
        let probe = "utm-probe-Q7x"
        let hash = "eyJ0IjoiNzc3NzciLCJ1IjoicGlpLXVzZXItOTkifQ"
        let link = "https://probe-host.example/carrinho?_mb_cr_=\(hash)&utm_source=\(probe)" +
            "&utm_campaign=\(probe)%20c&utm_flow_params=\(probe)-s|\(probe)-v|\(probe)-i"

        let capture = LogCapture()
        SdkLog.sink = { capture.append($0) }
        defer { SdkLog.sink = nil }

        let harness = CoreHarness()
        harness.core.captureUtm(fromLink: link)
        harness.core.onForeground()
        harness.core.track(.pageView(path: "home"))
        harness.core.setEnabled(false)
        harness.core.captureUtm(fromLink: link) // disabled-skip path
        harness.core.setEnabled(true) // re-enable evaluation path
        harness.store[StorageKeys.utmData] = #"[["utm_source","\#(probe)-corrupt"]"# // corrupt
        harness.core.onBackground()
        harness.core.onForeground()
        harness.core.captureUtm(fromLink: "https://probe-host.example/produto/1?utm_source=") // nothing stored or captured
        harness.core.captureUtm(fromLink: link)
        harness.clock.advance(UtmStore.ttlMillis) // expired
        harness.core.onBackground()
        harness.core.onForeground()

        let messages = capture.messages
        // Every UTM log path above actually fired…
        for path in [
            "utm context set", "utm capture skipped", "utm capture: no campaign",
            "stored utm discarded: corrupt", "stored utm discarded: expired",
        ] {
            #expect(messages.contains { $0.contains(path) }, "missing log path '\(path)' in: \(messages)")
        }
        // …and none of them carries the link, a value or the JSON.
        for needle in [probe, hash, "probe-host", "%20", "utm_source", "utm_campaign", "utm_step_id", "{\""] {
            let leaks = messages.filter { $0.contains(needle) }
            #expect(leaks.isEmpty, "debug log leaked '\(needle)' in: \(leaks)")
        }
    }

    /// SPEC §3: `handlePush`, `handleLink` and `handlePushOpened` decode
    /// purely. They *work* before initialize (real result, no "initialize
    /// was not called" warning), unlike the pipeline entry points. A
    /// UTM-bearing recovery link (`messagebuilder_journey_cart_recovery`)
    /// goes through the core-less paths the public `handleLink` and
    /// `handlePushOpened` take before initialize (`core: nil`). It decodes,
    /// and no handler or initialize warning is logged. The assertion
    /// targets those words only, so parallel suites logging through the
    /// sink (UTM logs included) cannot produce false failures. That nothing
    /// is captured then is structural (`core?.`), not asserted here.
    /// Mirrors the Android facade smoke test.
    @Test func pureHandlersWorkBeforeInitializeWithoutWarnings() throws {
        let vectors = try #require(try UtmLinkParserSuite.vectors()["extract"] as? [[String: Any]])
        let journey = try #require(vectors.first { $0["name"] as? String == "messagebuilder_journey_cart_recovery" })
        let link = try #require(journey["url"] as? String)
        let marker = try #require(String(
            data: try JSONSerialization.data(
                withJSONObject: ["v": 1, "type": "cart_recovery", "deep_link": link] as [String: Any]
            ),
            encoding: .utf8
        ))

        let capture = LogCapture()
        SdkLog.sink = { capture.append($0) }
        defer { SdkLog.sink = nil }

        let push = Flowbiz.handlePush(["flowbiz": #"{"v":1,"type":"promo","title":"t"}"#])
        #expect(push?.type == "promo")
        #expect(Flowbiz.handlePush(["other": "x"]) == nil)
        #expect(Flowbiz.handleLink(nil) == nil)
        #expect(Flowbiz.handleLink(URL(string: "https://store.com/?x=1")) == nil)
        #expect(Flowbiz.handlePushOpened(nil) == nil)
        #expect(Flowbiz.handleLink(link, core: nil)?.cartId == "cart-abc-001")
        let recoveryPush = try #require(Flowbiz.handlePush(["flowbiz": marker]))
        #expect(Flowbiz.handlePushOpened(recoveryPush, core: nil)?.cartId == "cart-abc-001")
        // Pure: no handler may route through the core lookup that logs
        // "Flowbiz.<name> ignored: initialize was not called", nor log a
        // "not initialized" skip of its UTM capture.
        let handlerWarnings = capture.messages.filter {
            $0.contains("handlePush") || $0.contains("handleLink") || $0.contains("not initialized")
        }
        #expect(handlerWarnings.isEmpty, "pure handlers logged warnings: \(handlerWarnings)")
    }

    /// I1 regression: `ConfigSanitizer` warnings must reach the debug sink
    /// on the very first `initialize` call, not just on later ones. Starts
    /// with `SdkLog.sink == nil` — the real first-call state — and
    /// substitutes what `Flowbiz.initialize` installs *as* the debug sink
    /// (`Flowbiz.debugSink`) rather than pre-installing `SdkLog.sink`
    /// itself: pre-installing it would make the warning reach the capture
    /// regardless of ordering (it doesn't get displaced), masking the bug
    /// this pins. This is the one real `Flowbiz.initialize` call in the
    /// test suite (the facade's singleton is "first config wins forever",
    /// see `FlowbizFacadeSmokeSuite`), so it must run before any other test
    /// initializes the facade with a non-blank appId.
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
