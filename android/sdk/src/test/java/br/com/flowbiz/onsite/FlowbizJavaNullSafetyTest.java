package br.com.flowbiz.onsite;

import static org.junit.Assert.assertNull;

import org.junit.Test;

// Java on purpose: it keeps compiling if a parameter turns non-null, then trips Kotlin's NPE preamble.
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
