package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Test

class CanonicalJsonNumberTest {

    @Test
    fun rendersJsReferenceStrings() {
        val cases = listOf(
            19.99 to "19.99",
            -19.99 to "-19.99",
            0.1 to "0.1",
            19.0 to "19",
            -19.0 to "-19",
            1e7 to "10000000",
            1e20 to "100000000000000000000",
            1e21 to "1e+21",
            1e-7 to "1e-7",
            1e-6 to "0.000001",
            1.5e-5 to "0.000015",
            -0.0 to "0",
            0.0 to "0",
            123456789012345680.0 to "123456789012345680",
            1234.5678 to "1234.5678",
        )
        for ((input, expected) in cases) {
            assertEquals("input=$input", expected, CanonicalJson.numberToJson(input))
        }
    }

    @Test
    fun jdk17ShortestRoundTripDivergenceFromJsIsPinned() {
        assertEquals("9.999999999999999e+22", CanonicalJson.numberToJson(1e23))
        assertEquals("4.9e-324", CanonicalJson.numberToJson(java.lang.Double.MIN_VALUE))
        assertEquals(1e23, "9.999999999999999e+22".toDouble(), 0.0)
        assertEquals(java.lang.Double.MIN_VALUE, "4.9e-324".toDouble(), 0.0)
    }
}
