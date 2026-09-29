package br.com.flowbiz.onsite;

import static org.junit.Assert.assertNull;

import org.junit.Test;

/**
 * Java on purpose: a non-null Kotlin parameter gets an
 * {@code Intrinsics.checkNotNullParameter} preamble that throws an NPE
 * <em>before</em> the facade's catch-all. Plain-JVM safe: the null paths
 * return before any Android API and never install the singleton core.
 */
public class FlowbizJavaNullSafetyTest {

    @Test
    public void trackWithNullEventIsANoOpNotAnNpe() {
        Flowbiz.track(null);
    }

    @Test
    public void initializeWithNullArgumentsIsANoOpNotAnNpe() {
        Flowbiz.initialize(null, new FlowbizConfig("77777", "https://store.com"));
        Flowbiz.initialize(null, null);
        Flowbiz.track(null);
        Flowbiz.flush();
    }

    @Test
    public void handlePushOpenedWithNullIsNullNotAnNpe() {
        assertNull(Flowbiz.handlePushOpened(null));
    }
}
