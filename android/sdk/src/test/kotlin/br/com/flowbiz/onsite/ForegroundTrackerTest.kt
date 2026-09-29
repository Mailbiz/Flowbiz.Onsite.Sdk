package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Test

/** Through the JVM seams: no real `Activity` exists on a plain JVM. */
class ForegroundTrackerTest {

    private class Edges {
        var foreground = 0
        var background = 0

        fun tracker() = Flowbiz.ForegroundTracker({ foreground += 1 }, { background += 1 })
    }

    @Test
    fun firstActivityStartFiresForegroundOnce() {
        val edges = Edges()
        val tracker = edges.tracker()
        tracker.activityStarted()
        assertEquals(1, edges.foreground)
        assertEquals(0, edges.background)
    }

    @Test
    fun rotationFiresNoBackgroundOrForegroundEdge() {
        val edges = Edges()
        val tracker = edges.tracker()
        tracker.activityStarted()
        assertEquals(1, edges.foreground)
        tracker.activityStopped(isChangingConfigurations = true)
        tracker.activityStarted()
        assertEquals("rotation must not fire a foreground edge", 1, edges.foreground)
        assertEquals("rotation must not fire a background edge", 0, edges.background)
    }

    @Test
    fun repeatedRotationsFireNoEdgesAndRealBackgroundStillDoes() {
        val edges = Edges()
        val tracker = edges.tracker()
        tracker.activityStarted()
        repeat(5) {
            tracker.activityStopped(isChangingConfigurations = true)
            tracker.activityStarted()
        }
        assertEquals(1, edges.foreground)
        assertEquals(0, edges.background)
        tracker.activityStopped(isChangingConfigurations = false)
        assertEquals(1, edges.background)
        tracker.activityStarted()
        assertEquals(2, edges.foreground)
    }

    @Test
    fun activityToActivityNavigationOverlapFiresNoEdges() {
        val edges = Edges()
        val tracker = edges.tracker()
        tracker.activityStarted() // A
        tracker.activityStarted() // B starts before A stops (normal navigation overlap)
        tracker.activityStopped(isChangingConfigurations = false) // A stops, count stays ≥ 1
        assertEquals(1, edges.foreground)
        assertEquals(0, edges.background)
    }

    @Test
    fun rotationWithSecondActivityStartedFiresNoEdges() {
        val edges = Edges()
        val tracker = edges.tracker()
        tracker.activityStarted() // A
        tracker.activityStarted() // B (second started activity, e.g. multi-window)
        // A rotates while B stays started.
        tracker.activityStopped(isChangingConfigurations = true)
        tracker.activityStarted() // A's replacement
        assertEquals(1, edges.foreground)
        assertEquals(0, edges.background)
        tracker.activityStopped(isChangingConfigurations = false)
        assertEquals(0, edges.background)
        tracker.activityStopped(isChangingConfigurations = false)
        assertEquals(1, edges.background)
    }

    @Test
    fun backgroundThenForegroundFiresBothEdges() {
        val edges = Edges()
        val tracker = edges.tracker()
        tracker.activityStarted()
        tracker.activityStopped(isChangingConfigurations = false)
        assertEquals(1, edges.background)
        tracker.activityStarted()
        assertEquals(2, edges.foreground)
    }

    @Test
    fun spuriousStopBeforeAnyStartFiresNothing() {
        val edges = Edges()
        val tracker = edges.tracker()
        tracker.activityStopped(isChangingConfigurations = false)
        assertEquals(0, edges.foreground)
        assertEquals(0, edges.background)
    }
}
