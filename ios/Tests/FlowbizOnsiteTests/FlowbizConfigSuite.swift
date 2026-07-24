// SPEC §2 config sanitization: blank appId, https-only collector URL,
// heartbeat clamp.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizConfigSuite {

    @Test func blankAppIdAbortsSanitization() {
        #expect(ConfigSanitizer.sanitize(FlowbizConfig(appId: "")) == nil)
        #expect(ConfigSanitizer.sanitize(FlowbizConfig(appId: "   ")) == nil)
        #expect(ConfigSanitizer.sanitize(FlowbizConfig(appId: "\t\n")) == nil)
    }

    @Test func validConfigPassesThroughUnchanged() {
        let config = FlowbizConfig(
            appId: "77777",
            collectorUrl: "https://collector.example.com",
            debug: true,
            heartbeatInterval: 30
        )
        #expect(ConfigSanitizer.sanitize(config) == config)
    }

    @Test func defaultsAreSpecValues() {
        let config = FlowbizConfig(appId: "77777")
        #expect(config.collectorUrl == "https://collector.mailbiz.one")
        #expect(config.debug == false)
        #expect(config.heartbeatInterval == 60)
    }

    @Test func nonHttpsUrlFallsBackToDefault() {
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", collectorUrl: "http://collector.example.com")
        )
        #expect(sanitized?.collectorUrl == FlowbizConfig.defaultCollectorUrl)
    }

    @Test func httpsWithEmptyHostFallsBackToDefault() {
        // Reviewer-flagged alignment case: `https://` parses but is garbage.
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", collectorUrl: "https://")
        )
        #expect(sanitized?.collectorUrl == FlowbizConfig.defaultCollectorUrl)
    }

    @Test(arguments: ["", "not a url", "ftp://collector.example.com", "collector.example.com"])
    func garbageUrlFallsBackToDefault(url: String) {
        let sanitized = ConfigSanitizer.sanitize(FlowbizConfig(appId: "77777", collectorUrl: url))
        #expect(sanitized?.collectorUrl == FlowbizConfig.defaultCollectorUrl)
    }

    @Test func uppercaseHttpsSchemeAccepted() {
        #expect(ConfigSanitizer.isValidCollectorUrl("HTTPS://collector.example.com"))
    }

    @Test(arguments: [0.0, 5.0, 14.9, -1.0, Double.nan, -.infinity])
    func heartbeatClampedToFifteenSecondFloor(seconds: Double) {
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", heartbeatInterval: seconds)
        )
        #expect(sanitized?.heartbeatInterval == FlowbizConfig.minHeartbeatInterval)
    }

    @Test func fifteenSecondsIsNotClamped() {
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", heartbeatInterval: 15)
        )
        #expect(sanitized?.heartbeatInterval == 15)
    }

    @Test func heartbeatClampedToDefensiveCeiling() {
        let sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId: "77777", heartbeatInterval: .greatestFiniteMagnitude)
        )
        #expect(sanitized?.heartbeatInterval == FlowbizConfig.maxHeartbeatInterval)
    }
}
#endif
