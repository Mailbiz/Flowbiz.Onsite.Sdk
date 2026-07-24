package com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SdkVersionTest {

    @Test
    fun versionIsSemver() {
        val parts = SdkVersion.CURRENT.split(".")
        assertEquals(3, parts.size)
        assertTrue(parts.all { it.toIntOrNull() != null })
    }

    @Test
    fun vendorIdentifier() {
        assertEquals("flowbiz-android-sdk", SdkVersion.VENDOR)
    }
}
