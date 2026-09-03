package com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Spec §5 resolver table. */
class UrlResolverTest {

    private val base = "https://store.com"

    @Test
    fun nullAndEmptyAreOmitted() {
        assertNull(UrlResolver.resolve(null, base))
        assertNull(UrlResolver.resolve("", base))
        assertNull(UrlResolver.resolve("   ", base))
    }

    @Test
    fun valuesWithASchemePassThrough() {
        for (value in listOf(
            "https://other.com/p", "http://legacy.com/p", "HTTPS://Store.com/x", "mailto:a@b.c",
            "myapp://cart", "https://store.com/p?utm_source=x#frag",
        )) {
            assertEquals(value, UrlResolver.resolve(value, base))
        }
    }

    @Test
    fun protocolRelativeGetsHttps() {
        assertEquals("https://cdn.store.com/a.jpg", UrlResolver.resolve("//cdn.store.com/a.jpg", base))
        assertEquals("https://cdn.store.com/a.jpg", UrlResolver.resolve("//cdn.store.com/a.jpg", null))
    }

    @Test
    fun rootedPathIsAppendedToBase() {
        assertEquals("https://store.com/checkout", UrlResolver.resolve("/checkout", base))
        assertEquals("https://store.com/p/1?ref=home#top", UrlResolver.resolve("/p/1?ref=home#top", base))
    }

    @Test
    fun barePathGetsASlash() {
        assertEquals("https://store.com/checkout", UrlResolver.resolve("checkout", base))
        assertEquals("https://store.com/p/1?x=a:b", UrlResolver.resolve("p/1?x=a:b", base))
    }

    @Test
    fun trailingSlashOnBaseIsTolerated() {
        assertEquals("https://store.com/checkout", UrlResolver.resolve("/checkout", "https://store.com/"))
    }

    @Test
    fun withoutBasePathsPassThrough() {
        assertEquals("/checkout", UrlResolver.resolve("/checkout", null))
        assertEquals("checkout", UrlResolver.resolve("checkout", ""))
    }

    @Test
    fun whitespaceIsTrimmed() {
        assertEquals("https://store.com/checkout", UrlResolver.resolve("  /checkout \n", base))
    }
}
