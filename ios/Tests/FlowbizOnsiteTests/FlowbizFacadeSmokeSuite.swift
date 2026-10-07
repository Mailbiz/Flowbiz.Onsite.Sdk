#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

// No-op paths only: a real initialize would leak state into other suites (first config wins).
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
    }

    @Test func initializeWithBlankAppIdIsACompleteNoOp() {
        Flowbiz.initialize(FlowbizConfig(appId: "   ", baseUri: "https://store.com"))
        Flowbiz.track(.pageView(path: "after-blank-init"))
        Flowbiz.flush()
    }
}
#endif
