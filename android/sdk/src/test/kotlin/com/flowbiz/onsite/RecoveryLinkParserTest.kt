package com.flowbiz.onsite

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import kotlin.random.Random

/**
 * `handleLink` decoding (SPEC §11) through the pure string-level parser
 * ([RecoveryLinkParser] — `android.net.Uri` does not exist on a plain JVM;
 * the facade adapter is `Uri.toString()` only). Compressed inputs come from
 * `shared/lzstring-vectors/vectors.json`, generated with the real lz-string
 * library — links built here are byte-identical to web-generated ones.
 */
class RecoveryLinkParserTest {

    private val vectors: Map<String, String> by lazy {
        val array = JSONArray(File(FixtureSupport.sharedDir("lzstring-vectors"), "vectors.json").readText())
        (0 until array.length()).associate {
            val vector = array.getJSONObject(it)
            vector.getString("name") to vector.getString("compressed")
        }
    }

    private fun link(compressed: String) = "https://store.com/recover?utm_source=flowbiz&mb_recovery=$compressed"

    // MARK: end-to-end against real web-generated compressed hashes

    @Test
    fun decodesRealCompressedBasicHash() {
        val payload = RecoveryLinkParser.parse(link(vectors.getValue("recovery_hash_basic")))
        assertNotNull(payload)
        assertEquals("cart-abc-001", payload!!.cartId)
        assertEquals("user-123", payload.userId)
        assertEquals(2, payload.products.size)
        assertEquals(RecoveryProduct("P100", "SKU-100-P", 2, null), payload.products[0])
        assertEquals(RecoveryProduct("P200", "SKU-200-M", 1, null), payload.products[1])
    }

    @Test
    fun decodesRecoveryPropertiesFromJsonStringElement() {
        val payload = RecoveryLinkParser.parse(link(vectors.getValue("recovery_hash_with_recovery_properties")))
        assertNotNull(payload)
        assertEquals("cart-77-xyz", payload!!.cartId)
        assertEquals("u-9f2c", payload.userId)
        assertEquals(
            mapOf("cor" to "Azul Marinho", "tamanho" to "P", "seller" to "loja-1"),
            payload.products[0].recoveryProperties,
        )
        assertEquals(3, payload.products[0].quantity)
        assertEquals(mapOf("cor" to "Verde", "tamanho" to "GG"), payload.products[1].recoveryProperties)
    }

    @Test
    fun decodesUnicodeProductData() {
        val payload = RecoveryLinkParser.parse(link(vectors.getValue("recovery_hash_unicode_product_data")))
        assertNotNull(payload)
        assertEquals("maria@exemplo.com.br", payload!!.userId)
        assertEquals("CAMISETA-AÇAÍ", payload.products[0].productId)
        assertEquals("Camiseta Açaí 🛒", payload.products[0].recoveryProperties!!["nome"])
        assertEquals("Tamanho médio — çãõ", payload.products[0].recoveryProperties!!["descrição"])
    }

    @Test
    fun decodesLongCart() {
        val payload = RecoveryLinkParser.parse(link(vectors.getValue("recovery_hash_long_cart_25_items")))
        assertNotNull(payload)
        assertEquals(25, payload!!.products.size)
        assertEquals("PROD-1000", payload.products[0].productId)
        assertEquals("PROD-1024", payload.products[24].productId)
        assertEquals(10, payload.products[0].recoveryProperties!!["estoque"])
    }

    /** Web `parseInt(it[0]) || 1` semantics: "0" → 1, "abc" → 1, missing fields → "". */
    @Test
    fun quantityAndFieldFallbacksMatchWebSemantics() {
        val payload = RecoveryLinkParser.parse(link(vectors.getValue("recovery_hash_quantity_edge_cases")))
        assertNotNull(payload)
        val products = payload!!.products
        assertEquals(4, products.size)
        assertEquals(1, products[0].quantity) // "0" is falsy in JS -> 1
        assertEquals(1, products[1].quantity) // "abc" -> NaN -> 1
        assertEquals(4, products[2].quantity)
        assertEquals("", products[2].productId) // missing -> ""
        assertEquals("", products[2].sku)
        assertEquals(2, products[3].quantity)
        assertNull(products[3].recoveryProperties) // "{not json" -> null
    }

    // MARK: URL-encoding tolerance

    @Test
    fun percentEncodedValueDecodes() {
        val compressed = vectors.getValue("recovery_hash_basic")
        val encoded = compressed.replace("+", "%2B").replace("\$", "%24")
        assertNotNull(RecoveryLinkParser.parse(link(encoded)))
        assertEquals(
            RecoveryLinkParser.parse(link(compressed)),
            RecoveryLinkParser.parse(link(encoded)),
        )
    }

    @Test
    fun plusTurnedIntoSpaceStillDecodes() {
        // A naive URL decoder turns '+' into ' '; the decompressor restores it.
        val mangled = vectors.getValue("recovery_hash_basic").replace('+', ' ')
        assertEquals(
            RecoveryLinkParser.parse(link(vectors.getValue("recovery_hash_basic"))),
            RecoveryLinkParser.parse(link(mangled)),
        )
    }

    @Test
    fun parameterIsFoundAmongOthersAndInFragmentFreePart() {
        val compressed = vectors.getValue("recovery_hash_basic")
        val url = "https://store.com/p?a=1&mb_recovery=$compressed&b=2#section"
        assertNotNull(RecoveryLinkParser.parse(url))
    }

    // MARK: null paths

    @Test
    fun missingParameterIsNull() {
        assertNull(RecoveryLinkParser.parse("https://store.com/recover"))
        assertNull(RecoveryLinkParser.parse("https://store.com/recover?utm_source=flowbiz"))
        assertNull(RecoveryLinkParser.parse("https://store.com/recover?mb_recovery="))
        assertNull(RecoveryLinkParser.parse(null))
    }

    @Test
    fun undecodableValueIsNull() {
        assertNull(RecoveryLinkParser.parse(link("!!!not-compressed!!!")))
    }

    /** Web validation parity: t, u and c must be present and non-empty, its non-empty. */
    @Test
    fun invalidHashShapesAreNullWholePayload() {
        for (name in listOf(
            "invalid_hash_missing_u",
            "invalid_hash_empty_c",
            "invalid_hash_empty_its",
            "invalid_hash_its_not_array",
            "invalid_hash_not_json",
        )) {
            assertNull("vector '$name' must map to null", RecoveryLinkParser.parse(link(vectors.getValue(name))))
        }
    }

    /** Never-throw fuzz over whole URLs. */
    @Test
    fun randomGarbageUrlsNeverThrow() {
        val random = Random(42)
        repeat(300) {
            val garbage = buildString {
                append("https://x.com/?mb_recovery=")
                repeat(random.nextInt(0, 60)) { append(random.nextInt(0x20, 0x2FFF).toChar()) }
            }
            RecoveryLinkParser.parse(garbage) // must not throw
            RecoveryLinkParser.parse(garbage.removePrefix("https://x.com/"))
        }
    }
}
