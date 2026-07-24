package com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [Flowbiz.ForegroundTracker] edge detection, exercised through the JVM
 * seams ([Flowbiz.ForegroundTracker.activityStarted] /
 * [Flowbiz.ForegroundTracker.activityStopped]) because no real `Activity`
 * exists on a plain JVM.
 *
 * The critical case is the configuration change (rotation): the activity is
 * stopped and destroyed *before* its replacement starts, so the started
 * count hits 0 mid-rotation — without the `isChangingConfigurations` skip,
 * every rotation would fire a background+foreground pair (resetting the
 * heartbeat cadence and the flush backoff).
 */
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
        tracker.activityStarted() // cold start → foreground edge
        assertEquals(1, edges.foreground)
        // Rotation: old activity stops (config change) BEFORE the new one starts.
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
        // A real background (home press) after rotations still fires.
        tracker.activityStopped(isChangingConfigurations = false)
        assertEquals(1, edges.background)
        // And the next start is a real foreground edge again.
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
