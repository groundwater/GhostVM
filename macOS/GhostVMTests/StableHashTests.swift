import XCTest
@testable import GhostVMKit

final class StableHashTests: XCTestCase {
    func testEmptyStringHash() {
        // DJB2 seed value
        XCTAssertEqual("".stableHash, 5381)
    }

    func testKnownInputConsistency() {
        let hash1 = "hello".stableHash
        let hash2 = "hello".stableHash
        XCTAssertEqual(hash1, hash2)
    }

    func testDifferentStringsProduceDifferentHashes() {
        XCTAssertNotEqual("hello".stableHash, "world".stableHash)
        XCTAssertNotEqual("abc".stableHash, "cba".stableHash)
        XCTAssertNotEqual("GhostVM".stableHash, "ghostvm".stableHash)
    }

    func testCrossProcessRegressionValues() {
        // Hardcoded expected values to catch accidental algorithm changes
        XCTAssertEqual("hello".stableHash, 210714636441)
        XCTAssertEqual("/path/to/vm".stableHash, 13789981918659725477)
        XCTAssertEqual("GhostVM".stableHash, 229425741865133)
    }
}
