// SPEC §2 config sanitization: blank appId, https-only collector URL,
// heartbeat clamp.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizConfigSuite {

    @Test func blankAppIdAbortsSanitization() {
        #expect(ConfigSanitizer.sanitize(FlowbizConfig(appId: "", baseUri: "https://store.com")) == nil)
        #expect(ConfigSanitizer.sanitize(FlowbizConfig(appId: "   ", baseUri: "https://store.com")) == nil)
        #expect(ConfigSanitizer.sanitize(FlowbizConfig(appId: "\t\n", baseUri: "https://store.com")) == nil)
    }

    @Test func validConfigPassesThroughUnchanged() {
        let config = FlowbizConfig(
            appId: "77777",
            baseUri: "https://store.com",
            collectorUrl: "https://collector.example.com",
            debug: true,
            heartbeatInterval: 30
        )
        #expect(ConfigSanitizer.sanitize(config) == config)
    }

    @Test func defaultsAreSpecValues() {
        let config = FlowbizConfig(appId: "77777", baseUri: "https://store.com")
        #expect(config.collectorUrl == "https://collector.mailbiz.one")
        #expect(config.debug == false)
        #expect(config.heartbeatInterval == 60)
    }

    @Test func nonHttpsUrlFallsBackToDefault() {
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", baseUri: "https://store.com", collectorUrl: "http://collector.example.com")
        )
        #expect(sanitized?.collectorUrl == FlowbizConfig.defaultCollectorUrl)
    }

    @Test func httpsWithEmptyHostFallsBackToDefault() {
        // Reviewer-flagged alignment case: `https://` parses but is garbage.
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", baseUri: "https://store.com", collectorUrl: "https://")
        )
        #expect(sanitized?.collectorUrl == FlowbizConfig.defaultCollectorUrl)
    }

    @Test(arguments: ["", "not a url", "ftp://collector.example.com", "collector.example.com"])
    func garbageUrlFallsBackToDefault(url: String) {
        let sanitized = ConfigSanitizer.sanitize(FlowbizConfig(appId: "77777", baseUri: "https://store.com", collectorUrl: url))
        #expect(sanitized?.collectorUrl == FlowbizConfig.defaultCollectorUrl)
    }

    @Test func uppercaseHttpsSchemeAccepted() {
        #expect(ConfigSanitizer.isValidCollectorUrl("HTTPS://collector.example.com"))
    }

    @Test(arguments: [0.0, 5.0, 14.9, -1.0, Double.nan, -.infinity])
    func heartbeatClampedToFifteenSecondFloor(seconds: Double) {
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", baseUri: "https://store.com", heartbeatInterval: seconds)
        )
        #expect(sanitized?.heartbeatInterval == FlowbizConfig.minHeartbeatInterval)
    }

    @Test func fifteenSecondsIsNotClamped() {
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", baseUri: "https://store.com", heartbeatInterval: 15)
        )
        #expect(sanitized?.heartbeatInterval == 15)
    }

    @Test func heartbeatClampedToDefensiveCeiling() {
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", baseUri: "https://store.com", heartbeatInterval: .greatestFiniteMagnitude)
        )
        #expect(sanitized?.heartbeatInterval == FlowbizConfig.maxHeartbeatInterval)
    }

    // MARK: baseUri / recoveryUrl (spec §3)

    @Test func baseUriOriginPassesThroughAndTrailingSlashIsStripped() {
        let a = ConfigSanitizer.sanitize(FlowbizConfig(appId: "77777", baseUri: "https://store.com"))
        #expect(a?.baseUri == "https://store.com")
        let b = ConfigSanitizer.sanitize(FlowbizConfig(appId: "77777", baseUri: "https://store.com/"))
        #expect(b?.baseUri == "https://store.com")
        let c = ConfigSanitizer.sanitize(FlowbizConfig(appId: "77777", baseUri: "  https://loja.store.com.br:8443  "))
        #expect(c?.baseUri == "https://loja.store.com.br:8443")
    }

    @Test(arguments: [
        "", "store.com", "http://store.com", "https://", "https://store.com/carrinho",
        "https://store.com?x=1", "https://store.com#top", "ftp://store.com", "not a url",
    ])
    func invalidBaseUriBecomesEmptyString(baseUri: String) {
        let sanitized = ConfigSanitizer.sanitize(FlowbizConfig(appId: "77777", baseUri: baseUri))
        #expect(sanitized?.baseUri == "")
        #expect(sanitized?.baseUriOrNil == nil)
    }

    @Test func recoveryUrlKeepsPathAndQueryButDropsFragment() {
        let config = FlowbizConfig(
            appId: "77777", baseUri: "https://store.com",
            recoveryUrl: "https://store.com/carrinho?src=app#top"
        )
        #expect(ConfigSanitizer.sanitize(config)?.recoveryUrl == "https://store.com/carrinho?src=app")
    }

    @Test(arguments: ["", "http://store.com/carrinho", "/carrinho", "store.com/carrinho", "myapp://cart"])
    func invalidRecoveryUrlBecomesNil(recoveryUrl: String) {
        let config = FlowbizConfig(appId: "77777", baseUri: "https://store.com", recoveryUrl: recoveryUrl)
        #expect(ConfigSanitizer.sanitize(config)?.recoveryUrl == nil)
    }

    @Test func recoveryUrlDefaultsToNil() {
        #expect(FlowbizConfig(appId: "77777", baseUri: "https://store.com").recoveryUrl == nil)
    }
}
#endif
