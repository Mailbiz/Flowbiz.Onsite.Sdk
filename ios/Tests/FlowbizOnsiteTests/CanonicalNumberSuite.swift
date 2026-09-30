#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct CanonicalNumberSuite {

    @Test func rendersJsReferenceStrings() throws {
        let cases: [(Double, String)] = [
            (19.99, "19.99"),
            (-19.99, "-19.99"),
            (0.1, "0.1"),
            (19.0, "19"),
            (-19.0, "-19"),
            (1e7, "10000000"),
            (1e20, "100000000000000000000"),
            (1e21, "1e+21"),
            (1e-7, "1e-7"),
            (1e-6, "0.000001"),
            (1.5e-5, "0.000015"),
            (-0.0, "0"),
            (0.0, "0"),
            (123456789012345680.0, "123456789012345680"),
            (1234.5678, "1234.5678"),
        ]
        for (input, expected) in cases {
            #expect(try CanonicalJSON.doubleToken(input) == expected, "input=\(input)")
        }
    }

    @Test func extremeMagnitudesMatchJsUnlikeJdk17() throws {
        #expect(try CanonicalJSON.doubleToken(1e23) == "1e+23")
        #expect(try CanonicalJSON.doubleToken(5e-324) == "5e-324")
    }
}
#endif
