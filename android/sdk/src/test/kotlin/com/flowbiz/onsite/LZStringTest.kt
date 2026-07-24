package com.flowbiz.onsite

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.random.Random

/**
 * The LZ-string decompressor port, pinned against the real JS library
 * (SPEC §11/§14): `shared/lzstring-vectors/vectors.json` was generated with
 * lz-string 1.4.4 under node — including the garbage cases, whose expected
 * outputs (`""` vs null) are the library's actual behavior.
 */
class LZStringTest {

    private fun vectors(): JSONArray =
        JSONArray(File(FixtureSupport.sharedDir("lzstring-vectors"), "vectors.json").readText())

    @Test
    fun allSharedVectorsDecodeIdenticallyToTheReferenceLibrary() {
        val vectors = vectors()
        assertTrue("vector file must not be empty", vectors.length() >= 12)
        for (i in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(i)
            val name = vector.getString("name")
            val actual = LZString.decompressFromEncodedURIComponent(vector.getString("compressed"))
            if (vector.optBoolean("expect_null", false)) {
                assertNull("vector '$name' must decode to null", actual)
            } else {
                assertEquals("vector '$name'", vector.getString("expected_decompressed"), actual)
            }
        }
    }

    @Test
    fun nullAndEmptyInputAreNull() {
        assertNull(LZString.decompressFromEncodedURIComponent(null))
        assertNull(LZString.decompressFromEncodedURIComponent(""))
    }

    /** Never-throw fuzz: random garbage must produce a value or null, not a crash. */
    @Test
    fun randomGarbageNeverThrows() {
        val random = Random(20260724)
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-\$"
        repeat(500) {
            val length = random.nextInt(0, 120)
            val garbage = buildString {
                repeat(length) {
                    when (random.nextInt(4)) {
                        0 -> append(alphabet[random.nextInt(alphabet.length)])
                        1 -> append(random.nextInt(32, 127).toChar())
                        2 -> append(random.nextInt(0x20, 0xFFFF).toChar())
                        else -> append(' ')
                    }
                }
            }
            LZString.decompressFromEncodedURIComponent(garbage) // must not throw
        }
    }
}
