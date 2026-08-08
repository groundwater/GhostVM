import XCTest

final class GuestMountRegistryTests: XCTestCase {
    func testGuestMountPolicyRejectsOuterHostPathMethods() {
        for method in ["mount.create", "mount.block", "mount.share", "mount.any", "mount.clone", "mount.futureHostPath"] {
            XCTAssertFalse(GuestMountAccessPolicy.allowsGuestInvocation(method), method)
        }
    }

    func testGuestMountPolicyAllowsPrivateShareAndReferenceConsumers() {
        for method in [
            "mount.guestShare", "mount.sharedMount", "mount.source", "mount.delete",
            "volume.create", "volume.list", "volume.inspect", "volume.mount", "volume.delete",
            "container.configuration.withMounts",
        ] {
            XCTAssertTrue(GuestMountAccessPolicy.allowsGuestInvocation(method), method)
        }
    }

    func testPrivateMountDirectoryIsUniqueTemporaryAndOwnerOnly() throws {
        let first = try PrivateGuestMountDirectory.create()
        let second = try PrivateGuestMountDirectory.create()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent(), PrivateGuestMountDirectory.rootURL)
        XCTAssertEqual(second.deletingLastPathComponent(), PrivateGuestMountDirectory.rootURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testDeleteDuringCreationPreventsRegistrationAndReleasesName() {
        var registry = GuestMountRegistry<Int>()
        let reference = "@mount/project"

        XCTAssertTrue(registry.reserve(reference))
        XCTAssertNil(registry.release(reference))
        XCTAssertEqual(registry.complete(reference, value: 1), .deleted)
        XCTAssertNil(registry[reference])
        XCTAssertTrue(registry.reserve(reference))
    }

    func testCompletedMountCanBeReleased() {
        var registry = GuestMountRegistry<Int>()
        let reference = "@mount/project"

        XCTAssertTrue(registry.reserve(reference))
        XCTAssertEqual(registry.complete(reference, value: 1), .registered)
        XCTAssertEqual(registry[reference], 1)
        XCTAssertEqual(registry.release(reference), 1)
        XCTAssertNil(registry[reference])
    }
}
