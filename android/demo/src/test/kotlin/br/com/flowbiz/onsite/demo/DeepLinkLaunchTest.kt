package br.com.flowbiz.onsite.demo

import android.content.Intent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeepLinkLaunchTest {

    @Test
    fun onlyAFreshLaunchHandlesTheIntentLink() {
        assertTrue(isFreshLinkLaunch(restoring = false, intentFlags = 0))
        assertTrue(isFreshLinkLaunch(restoring = false, intentFlags = Intent.FLAG_ACTIVITY_NEW_TASK))

        assertFalse("recreation", isFreshLinkLaunch(restoring = true, intentFlags = 0))
        assertFalse(
            "relaunch from Recents",
            isFreshLinkLaunch(
                restoring = false,
                intentFlags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY,
            ),
        )
    }
}
