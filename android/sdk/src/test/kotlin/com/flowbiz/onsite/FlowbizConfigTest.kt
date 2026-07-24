package com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** SPEC §2 config sanitization: blank appId, https-only collector URL, heartbeat clamp. */
class FlowbizConfigTest {

    @Test
    fun blankAppIdAbortsSanitization() {
        assertNull(ConfigSanitizer.sanitize(FlowbizConfig(appId = "")))
        assertNull(ConfigSanitizer.sanitize(FlowbizConfig(appId = "   ")))
        assertNull(ConfigSanitizer.sanitize(FlowbizConfig(appId = "\t\n")))
    }

    @Test
    fun validConfigPassesThroughUnchanged() {
        val config = FlowbizConfig(
            appId = "77777",
            collectorUrl = "https://collector.example.com",
            debug = true,
            heartbeatIntervalSeconds = 30,
        )
        assertEquals(config, ConfigSanitizer.sanitize(config))
    }

    @Test
    fun defaultsAreSpecValues() {
        val config = FlowbizConfig(appId = "77777")
        assertEquals("https://collector.mailbiz.one", config.collectorUrl)
        assertFalse(config.debug)
        assertEquals(60L, config.heartbeatIntervalSeconds)
    }

    @Test
    fun nonHttpsUrlFallsBackToDefault() {
        val sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId = "77777", collectorUrl = "http://collector.example.com")
        )!!
        assertEquals(FlowbizConfig.DEFAULT_COLLECTOR_URL, sanitized.collectorUrl)
    }

    @Test
    fun httpsWithEmptyHostFallsBackToDefault() {
        // Reviewer-flagged alignment case: `https://` parses but is garbage.
        val sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId = "77777", collectorUrl = "https://")
        )!!
        assertEquals(FlowbizConfig.DEFAULT_COLLECTOR_URL, sanitized.collectorUrl)
    }

    @Test
    fun garbageUrlFallsBackToDefault() {
        for (url in listOf("", "not a url", "ftp://collector.example.com", "collector.example.com")) {
            val sanitized = ConfigSanitizer.sanitize(FlowbizConfig(appId = "77777", collectorUrl = url))!!
            assertEquals("for '$url'", FlowbizConfig.DEFAULT_COLLECTOR_URL, sanitized.collectorUrl)
        }
    }

    @Test
    fun uppercaseHttpsSchemeAccepted() {
        assertTrue(ConfigSanitizer.isValidCollectorUrl("HTTPS://collector.example.com"))
    }

    @Test
    fun heartbeatClampedToFifteenSecondFloor() {
        for (seconds in listOf(0L, 5L, 14L, -1L)) {
            val sanitized = ConfigSanitizer.sanitize(
                FlowbizConfig(appId = "77777", heartbeatIntervalSeconds = seconds)
            )!!
            assertEquals(FlowbizConfig.MIN_HEARTBEAT_SECONDS, sanitized.heartbeatIntervalSeconds)
        }
        assertEquals(
            15L,
            ConfigSanitizer.sanitize(FlowbizConfig(appId = "77777", heartbeatIntervalSeconds = 15))!!
                .heartbeatIntervalSeconds,
        )
    }

    @Test
    fun heartbeatClampedToDefensiveCeiling() {
        val sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId = "77777", heartbeatIntervalSeconds = Long.MAX_VALUE)
        )!!
        assertEquals(FlowbizConfig.MAX_HEARTBEAT_SECONDS, sanitized.heartbeatIntervalSeconds)
    }
}
