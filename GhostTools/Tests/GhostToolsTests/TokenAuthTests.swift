import XCTest
@testable import GhostTools

final class TokenAuthTests: XCTestCase {

    func testValidateTokenWithNoHeader() async {
        let isValid = await TokenAuth.shared.validateToken(nil)
        XCTAssertFalse(isValid, "Nil auth header should be invalid")
    }

    func testValidateTokenWithEmptyHeader() async {
        let isValid = await TokenAuth.shared.validateToken("")
        XCTAssertFalse(isValid, "Empty auth header should be invalid")
    }

    func testValidateTokenWithNonBearerHeader() async {
        let isValid = await TokenAuth.shared.validateToken("Basic abc123")
        XCTAssertFalse(isValid, "Non-Bearer auth header should be invalid")
    }

    func testValidateTokenWithEmptyBearer() async {
        let isValid = await TokenAuth.shared.validateToken("Bearer ")
        XCTAssertFalse(isValid, "Empty Bearer token should be invalid")
    }
}
