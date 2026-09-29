package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FlowbizConfigTest {

    @Test
    fun blankAppIdAbortsSanitization() {
        assertNull(ConfigSanitizer.sanitize(FlowbizConfig(appId = "", baseUri = "https://store.com")))
        assertNull(ConfigSanitizer.sanitize(FlowbizConfig(appId = "   ", baseUri = "https://store.com")))
        assertNull(ConfigSanitizer.sanitize(FlowbizConfig(appId = "\t\n", baseUri = "https://store.com")))
    }

    @Test
    fun validConfigPassesThroughUnchanged() {
        val config = FlowbizConfig(
            appId = "77777",
            baseUri = "https://store.com",
            collectorUrl = "https://collector.example.com",
            debug = true,
            heartbeatIntervalSeconds = 30,
        )
        assertEquals(config, ConfigSanitizer.sanitize(config))
    }

    @Test
    fun defaultsAreSpecValues() {
        val config = FlowbizConfig(appId = "77777", baseUri = "https://store.com")
        assertEquals("https://collector.mailbiz.one", config.collectorUrl)
        assertFalse(config.debug)
        assertEquals(60L, config.heartbeatIntervalSeconds)
    }

    @Test
    fun nonHttpsUrlFallsBackToDefault() {
        val sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId = "77777", baseUri = "https://store.com", collectorUrl = "http://collector.example.com")
        )!!
        assertEquals(FlowbizConfig.DEFAULT_COLLECTOR_URL, sanitized.collectorUrl)
    }

    @Test
    fun httpsWithEmptyHostFallsBackToDefault() {
        val sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId = "77777", baseUri = "https://store.com", collectorUrl = "https://")
        )!!
        assertEquals(FlowbizConfig.DEFAULT_COLLECTOR_URL, sanitized.collectorUrl)
    }

    @Test
    fun garbageUrlFallsBackToDefault() {
        for (url in listOf("", "not a url", "ftp://collector.example.com", "collector.example.com")) {
            val sanitized = ConfigSanitizer.sanitize(FlowbizConfig(appId = "77777", baseUri = "https://store.com", collectorUrl = url))!!
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
                FlowbizConfig(appId = "77777", baseUri = "https://store.com", heartbeatIntervalSeconds = seconds)
            )!!
            assertEquals(FlowbizConfig.MIN_HEARTBEAT_SECONDS, sanitized.heartbeatIntervalSeconds)
        }
        assertEquals(
            15L,
            ConfigSanitizer.sanitize(FlowbizConfig(appId = "77777", baseUri = "https://store.com", heartbeatIntervalSeconds = 15))!!
                .heartbeatIntervalSeconds,
        )
    }

    @Test
    fun heartbeatClampedToDefensiveCeiling() {
        val sanitized = ConfigSanitizer.sanitize(
            FlowbizConfig(appId = "77777", baseUri = "https://store.com", heartbeatIntervalSeconds = Long.MAX_VALUE)
        )!!
        assertEquals(FlowbizConfig.MAX_HEARTBEAT_SECONDS, sanitized.heartbeatIntervalSeconds)
    }

    @Test
    fun baseUriOriginPassesThroughAndTrailingSlashIsStripped() {
        assertEquals("https://store.com", ConfigSanitizer.sanitize(FlowbizConfig("77777", "https://store.com"))!!.baseUri)
        assertEquals("https://store.com", ConfigSanitizer.sanitize(FlowbizConfig("77777", "https://store.com/"))!!.baseUri)
        assertEquals(
            "https://loja.store.com.br:8443",
            ConfigSanitizer.sanitize(FlowbizConfig("77777", "  https://loja.store.com.br:8443  "))!!.baseUri,
        )
    }

    @Test
    fun invalidBaseUriBecomesEmptyString() {
        for (bad in listOf(
            "", "store.com", "http://store.com", "https://", "https://store.com/carrinho",
            "https://store.com?x=1", "https://store.com#top", "ftp://store.com", "not a url",
        )) {
            val sanitized = ConfigSanitizer.sanitize(FlowbizConfig("77777", bad))!!
            assertEquals("baseUri '$bad'", "", sanitized.baseUri)
            assertNull("baseUri '$bad'", sanitized.baseUriOrNull)
        }
    }

    @Test
    fun recoveryUrlKeepsPathAndQueryButDropsFragment() {
        val config = FlowbizConfig(
            appId = "77777", baseUri = "https://store.com",
            recoveryUrl = "https://store.com/carrinho?src=app#top",
        )
        assertEquals("https://store.com/carrinho?src=app", ConfigSanitizer.sanitize(config)!!.recoveryUrl)
    }

    @Test
    fun invalidRecoveryUrlBecomesNull() {
        for (bad in listOf("", "http://store.com/carrinho", "/carrinho", "store.com/carrinho", "myapp://cart")) {
            val config = FlowbizConfig(appId = "77777", baseUri = "https://store.com", recoveryUrl = bad)
            assertNull("recoveryUrl '$bad'", ConfigSanitizer.sanitize(config)!!.recoveryUrl)
        }
    }

    @Test
    fun recoveryUrlDefaultsToNull() {
        assertNull(FlowbizConfig("77777", "https://store.com").recoveryUrl)
    }

    /**
     * `initialize` installs the debug sink before sanitizing, so these warnings
     * reach the first call; that path needs a `Context`, this pins the rest.
     */
    @Test
    fun invalidBaseUriWarningReachesAnInstalledSink() {
        val captured = mutableListOf<String>()
        SdkLog.sink = { captured += it }
        try {
            ConfigSanitizer.sanitize(FlowbizConfig(appId = "77777", baseUri = "not a url"))
            assertTrue(captured.any { it.contains("invalid baseUri") })
        } finally {
            SdkLog.sink = null
        }
    }
}
