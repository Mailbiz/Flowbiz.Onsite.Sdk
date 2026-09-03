// Smoke coverage for the static `Flowbiz` facade. Only no-op paths are
// exercised — a real `initialize` on the shared singleton would leak
// UserDefaults suites / queue files onto the test machine and poison other
// suites (first config wins forever). SPEC §3: every pre-init call must be
// a silent no-op, never a throw/crash.
//
// What is deliberately **not** covered here and rides on the demo app
// (SPEC §14) instead: `initialize` production wiring (UserDefaults suite,
// queue file location, URLSessionHttpSender, UIApplication lifecycle
// observers, the initialize-while-foregrounded probe, os_log sink) and
// double-initialize. The behavioral equivalents (config sanitization,
// lifecycle edges, never-throw pipeline) are all pinned at the
// `FlowbizCore` level.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizFacadeSmokeSuite {

    @Test func preInitializeCallsAreSilentNoOpsAndNeverThrow() {
        Flowbiz.track(.pageView(path: "home"))
        Flowbiz.track(.productView(
            product: Product(productId: "P1", variants: [ProductVariant(sku: "S1", price: .nan)])
        ))
        Flowbiz.logout()
        Flowbiz.setEnabled(false)
        Flowbiz.setEnabled(true)
        Flowbiz.flush()
        // Reaching this line is the assertion: nothing threw or crashed.
    }

    @Test func initializeWithBlankAppIdIsACompleteNoOp() {
        Flowbiz.initialize(FlowbizConfig(appId: "   ", baseUri: "https://store.com"))
        // Still uninitialized: subsequent calls stay no-ops.
        Flowbiz.track(.pageView(path: "after-blank-init"))
        Flowbiz.flush()
    }
}
#endif
