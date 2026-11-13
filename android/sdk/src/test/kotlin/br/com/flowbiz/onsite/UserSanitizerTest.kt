package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// The shared account_* fixtures pin the wire; these pin what a fixture cannot say.
class UserSanitizerTest {

    @Test
    fun anEmailIsJudgedAsTheWebLooksLikeEmailDoes() {
        for (email in listOf("a@b.co", "maria+tag@sub.gmail.com", "x@xn--80ak6aa92e.xn--p1ai")) {
            assertTrue(email, UserSanitizer.looksLikeEmail(email))
        }
        // The trailing line break: JS `$` does not match before it, a Java `$` would.
        for (email in listOf("", "maria", "maria@gmail", "maria@gmail.c", "a.b@gmail", "maria@gmail.com\n", "ma ria@gmail.com")) {
            assertFalse(email, UserSanitizer.looksLikeEmail(email))
        }
    }

    @Test
    fun aUserIdThatIdentifiesNobodyIsLeftOut() {
        for (userId in listOf("0", "-1", "null", "Undefined", "none", "NaN", " 7 ", "vrn--vtexsphinx", "maria@gmail")) {
            assertNull(userId, UserSanitizer.sanitize(User(userId = userId)))
        }
        assertEquals(User(userId = "10"), UserSanitizer.sanitize(User(userId = "10")))
    }

    @Test
    fun otherEventsAndFieldsPassThroughUntouched() {
        val page = Event.PageView("/Home", "Home")
        assertEquals(page, UserSanitizer.sanitize(page))
        val user = User(userId = "U-1", name = "Maria Oliveira", phone = "+55 11", plan = "VIP", createdAt = "2024-03-15T14:22:00Z")
        assertEquals(Event.AccountSync(user.copy(userId = "u-1")), UserSanitizer.sanitize(Event.AccountSync(user)))
    }
}
