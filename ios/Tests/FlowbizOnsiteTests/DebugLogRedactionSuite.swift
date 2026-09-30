#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

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

// Every test that sets the global SdkLog.sink lives here; other suites log through it concurrently.
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
        // The repeats, the NaN price and the disabled track each hit another log path.
        harness.core.track(.accountLogin(user: user))
        harness.core.track(.accountLogin(user: user))
        harness.core.setPushToken(token)
        harness.core.setPushToken(token)
        harness.core.track(.productView(
            product: Product(productId: "P1", variants: [ProductVariant(sku: "S1", price: .nan)])
        ))
        harness.core.setEnabled(false)
        harness.core.track(.accountSync(user: user))
        harness.core.setEnabled(true)
        harness.core.removePushToken()
        harness.core.setPushToken(token)
        harness.core.logout()
        harness.core.flush()

        let messages = capture.messages
        #expect(!messages.isEmpty, "scenario must produce debug logs")
        for pii in [email, phone, name, token] {
            let leaks = messages.filter { $0.contains(pii) }
            #expect(leaks.isEmpty, "debug log leaked PII '\(pii)' in: \(leaks)")
        }
    }

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

    @Test func pureHandlersWorkBeforeInitializeWithoutWarnings() {
        let capture = LogCapture()
        SdkLog.sink = { capture.append($0) }
        defer { SdkLog.sink = nil }

        let push = Flowbiz.handlePush(["flowbiz": #"{"v":1,"type":"promo","title":"t"}"#])
        #expect(push?.type == "promo")
        #expect(Flowbiz.handlePush(["other": "x"]) == nil)
        #expect(Flowbiz.handleLink(nil) == nil)
        #expect(Flowbiz.handleLink(URL(string: "https://store.com/?x=1")) == nil)
        let handlerWarnings = capture.messages.filter {
            $0.contains("handlePush") || $0.contains("handleLink")
        }
        #expect(handlerWarnings.isEmpty, "pure handlers logged warnings: \(handlerWarnings)")
    }

    @Test func beforeInitializeALinkIsOnlyDecoded() throws {
        let capture = LogCapture()
        SdkLog.sink = { capture.append($0) }
        defer { SdkLog.sink = nil }

        let link = try UtmLinkParserSuite.extractVector("messagebuilder_journey_cart_recovery").url
        // core: nil, not the global core: the one real initialize below may already have run.
        #expect(Flowbiz.handleLink(link, core: nil)?.cartId == "cart-abc-001")
        #expect(Flowbiz.handlePushOpened(nil) == nil)
        #expect(!capture.messages.contains { $0.contains("handleLink") || $0.contains("handlePushOpened") })
    }

    // The one real initialize (first config wins); debugSink, not SdkLog.sink, pins sink-before-sanitize.
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
