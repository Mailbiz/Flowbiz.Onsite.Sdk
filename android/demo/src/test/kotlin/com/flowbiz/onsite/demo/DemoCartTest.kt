package com.flowbiz.onsite.demo

import com.flowbiz.onsite.RecoveryPayload
import com.flowbiz.onsite.RecoveryProduct
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Smoke test for the demo's fake-store state (pure Kotlin — no Android
 * types): the SDK payloads the demo builds must stay arithmetically
 * consistent and recovery restoration must map to catalog products.
 */
class DemoCartTest {

    @Before
    fun reset() = DemoCart.clear()

    @Test
    fun catalogSkusAreUnique() {
        val skus = DemoCatalog.products.map { it.sku }
        assertEquals(skus.size, skus.toSet().size)
    }

    @Test
    fun cartTotalsAddUp() {
        DemoCart.add(DemoCatalog.bySku("CAM-778-P-AZ")!!, 2)
        DemoCart.coupon = "BEMVINDA10"
        DemoCart.postalCode = "01310-100"
        val cart = DemoCart.toCart()
        assertEquals(379.8, cart.subtotal, 0.001)
        assertEquals(37.98, cart.discounts, 0.001)
        assertEquals(cart.subtotal - cart.discounts + cart.freight, cart.total, 0.001)
        assertEquals(2, cart.items!!.single().quantity)
        assertEquals("01310-100", cart.deliveryAddress!!.postalCode)
        assertEquals(listOf("BEMVINDA10"), cart.coupons)
    }

    @Test
    fun orderMirrorsCartAndCarriesMethods() {
        DemoCart.add(DemoCatalog.bySku("SKU-200-M")!!, 1)
        val order = DemoCart.toOrder("ord-1")
        assertEquals("ord-1", order.orderId)
        assertEquals(DemoCart.total(), order.total, 0.001)
        assertEquals("credit_card", order.paymentMethods!!.single().type)
        assertEquals("sedex", order.deliveryMethods!!.single().type)
    }

    @Test
    fun recoveryRestoreMapsCatalogProducts() {
        // Mirrors the decoded shared/recovery-links/vectors.json "basic".
        DemoCart.restore(
            RecoveryPayload(
                cartId = "cart-abc-001",
                userId = "user-123",
                products = listOf(
                    RecoveryProduct(productId = "P100", sku = "SKU-100-P", quantity = 2),
                    RecoveryProduct(productId = "P200", sku = "SKU-200-M", quantity = 1),
                    RecoveryProduct(productId = "UNKNOWN", sku = "NOPE", quantity = 9),
                ),
            )
        )
        val lines = DemoCart.lines.associate { (product, qty) -> product.sku to qty }
        assertEquals(mapOf("SKU-100-P" to 2, "SKU-200-M" to 1), lines)
        assertTrue(DemoCart.toCart().items!!.isNotEmpty())
    }
}
