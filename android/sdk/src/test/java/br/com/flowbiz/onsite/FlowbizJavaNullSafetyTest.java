package br.com.flowbiz.onsite;

import org.junit.Test;

/**
 * SPEC §3 never-throw, proven from real Java source: Java host apps have no
 * compile-time null checking, so {@code Flowbiz.track(null)} and
 * {@code Flowbiz.initialize(null, ...)} are legal call sites. With non-null
 * Kotlin signatures the compiler emits an
 * {@code Intrinsics.checkNotNullParameter} preamble that throws an NPE
 * <em>before</em> the facade's catch-all — the facade therefore declares
 * these parameters nullable and no-ops on null. This test compiles as Java
 * on purpose: it exercises exactly the call shape a Java integrator can
 * produce.
 *
 * Safe on a plain JVM: every null path no-ops before touching any Android
 * API, and none of these calls installs the singleton core (so the shared
 * {@link Flowbiz} state is untouched for other tests).
 */
public class FlowbizJavaNullSafetyTest {

    @Test
    public void trackWithNullEventIsANoOpNotAnNpe() {
        Flowbiz.track(null);
        // Reaching this line is the assertion: no NullPointerException escaped.
    }

    @Test
    public void initializeWithNullArgumentsIsANoOpNotAnNpe() {
        Flowbiz.initialize(null, new FlowbizConfig("77777", "https://store.com"));
        Flowbiz.initialize(null, null);
        // No core was installed by the null calls: track stays a silent no-op.
        Flowbiz.track(null);
        Flowbiz.flush();
    }
}
