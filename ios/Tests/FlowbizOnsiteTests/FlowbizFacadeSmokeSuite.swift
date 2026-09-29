// Only no-op paths: a real `initialize` on the shared singleton would leak
// UserDefaults suites / queue files onto the test machine and poison other
// suites (first config wins forever). The production wiring rides on the
// demo app; its behavior is pinned at the `FlowbizCore` level.
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
        Flowbiz.track(.pageView(path: "after-blank-init"))
        Flowbiz.flush()
    }
}
#endif
