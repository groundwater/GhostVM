import Foundation
import XCTest

final class GhostVMFSExtensionManagerTests: XCTestCase {
    func testRegistrationURLsOnlyReturnsMatchingAbsolutePaths() {
        let output = """
        +    org.ghostvm.ghostvm.fs(1.0)\tUUID-1\t2026-08-05 00:00:00 +0000\t/Applications/GhostVM.app/Contents/Extensions/GhostVMFS.appex
        +    org.example.other.fs(1.0)\tUUID-2\t2026-08-05 00:00:00 +0000\t/Applications/Other.app/Contents/Extensions/Other.appex
        org.ghostvm.ghostvm.fs malformed relative/path
        """

        XCTAssertEqual(
            GhostVMFSExtensionManager.registrationURLs(from: output).map(\.path),
            ["/Applications/GhostVM.app/Contents/Extensions/GhostVMFS.appex"]
        )
    }

    func testEnabledModuleIdentifiersReadsFSKitPreferenceArray() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.fskit.apfs", "org.ghostvm.ghostvm.fs"],
            format: .binary,
            options: 0
        )

        XCTAssertEqual(
            GhostVMFSExtensionManager.enabledModuleIdentifiers(from: data),
            ["com.apple.fskit.apfs", "org.ghostvm.ghostvm.fs"]
        )
    }

    func testInvalidEnabledModulesPreferenceIsEmpty() {
        XCTAssertTrue(
            GhostVMFSExtensionManager.enabledModuleIdentifiers(from: Data("invalid".utf8)).isEmpty
        )
    }

    func testGhostVMFSAdvertisesMountOperation() throws {
        let macOSDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = macOSDirectory.appendingPathComponent("GhostVMFS/Info.template.plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)
                as? [String: Any]
        )
        let attributes = try XCTUnwrap(plist["EXAppExtensionAttributes"] as? [String: Any])
        let activateSyntax = try XCTUnwrap(attributes["FSActivateOptionSyntax"] as? [String: Any])

        XCTAssertEqual(activateSyntax["shortOptions"] as? String, "g:m:o:u:")
        XCTAssertEqual(
            (attributes["FSCheckOptionSyntax"] as? [String: Any])?["shortOptions"] as? String,
            "nqy"
        )
        XCTAssertEqual(
            (attributes["FSFormatOptionSyntax"] as? [String: Any])?["shortOptions"] as? String,
            "v"
        )
    }

    func testGhostVMFSSigningIdentityMatchesBundleIdentifier() throws {
        let macOSDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = macOSDirectory.appendingPathComponent("GhostVMFS/entitlements.plist")
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: entitlementsURL),
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            entitlements["com.apple.application-identifier"] as? String,
            "3FGZQE8AW3.org.ghostvm.ghostvm.fs"
        )
        XCTAssertEqual(
            entitlements["com.apple.developer.team-identifier"] as? String,
            "3FGZQE8AW3"
        )
    }

}
