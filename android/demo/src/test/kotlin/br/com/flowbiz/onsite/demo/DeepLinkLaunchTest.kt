package br.com.flowbiz.onsite.demo

import android.content.Intent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The demo's launch-link rule (pure Kotlin; `Intent` flags are compile-time
 * constants): `onCreate` hands its intent's link to `Flowbiz.handleLink`
 * only on a fresh launch, so a rotation or a relaunch from Recents never
 * re-captures an old link's UTMs over newer ones (SPEC §11.1).
 */
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
