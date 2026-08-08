import Containerization
import XCTest

final class GhostboxContainerAPICommandsTests: XCTestCase {
    func testMemorySizeLifecycleAndDuplicateName() async throws {
        let session = GhostboxSession()
        let commands = GhostboxContainerMemorySizeCommands()

        let created = try await commands.handle(
            method: .init(rawValue: "crMemorySize.create"),
            parameters: ["memorySize": .string("limit"), "value": .string("512mb")],
            session: session
        )
        XCTAssertEqual(created, .reference("@memory-size/limit"))
        let formatted = try await commands.handle(
            method: .init(rawValue: "crMemorySize.formatted"),
            parameters: ["memorySize": .string("@memory-size/limit")],
            session: session
        )
        XCTAssertEqual(formatted, .string("512mb"))
        let bytes = try await commands.handle(
            method: .init(rawValue: "crMemorySize.toUInt64"),
            parameters: [
                "memorySize": .string("@memory-size/limit"),
                "unit": .string("bytes"),
            ],
            session: session
        )
        XCTAssertEqual(bytes, .unsignedInteger(536_870_912))

        do {
            _ = try await commands.handle(
                method: .init(rawValue: "crMemorySize.create"),
                parameters: ["memorySize": .string("limit"), "value": .string("1gb")],
                session: session
            )
            XCTFail("Expected duplicate creation to fail")
        } catch let error as DirectDispatchError {
            XCTAssertEqual(error.code, .alreadyExists)
        }
    }

    func testResourceLabelsAndParserUtilities() async throws {
        let session = GhostboxSession()
        let labels = GhostboxContainerResourceLabelsCommands()
        let parser = GhostboxContainerParserCommands()

        let created = try await labels.handle(
            method: .init(rawValue: "crResourceLabels.create"),
            parameters: [
                "resourceLabels": .string("web"),
                "label": .array([.string("app=ghost"), .string("tier=frontend")]),
            ],
            session: session
        )
        XCTAssertEqual(created, .reference("@resource-labels/web"))
        let dictionary = try await labels.handle(
            method: .init(rawValue: "crResourceLabels.dictionary"),
            parameters: ["resourceLabels": .string("@resource-labels/web")],
            session: session
        )
        XCTAssertEqual(dictionary, .object(["app": .string("ghost"), "tier": .string("frontend")]))
        let missing = try await labels.handle(
            method: .init(rawValue: "crResourceLabels.value"),
            parameters: ["resourceLabels": .string("@resource-labels/web"), "key": .string("missing")],
            session: session
        )
        XCTAssertEqual(missing, .null)
        let memory = try await parser.handle(
            method: .init(rawValue: "crParser.memoryAsMiB"),
            parameters: ["memory": .string("2gb")],
            session: session
        )
        XCTAssertEqual(memory, .integer(2_048))
        let parsedLabels = try await parser.handle(
            method: .init(rawValue: "crParser.labels"),
            parameters: ["label": .array([.string("one=1"), .string("two=2")])],
            session: session
        )
        XCTAssertEqual(parsedLabels, .object(["one": .string("1"), "two": .string("2")]))
        let parsedBool = try await parser.handle(
            method: .init(rawValue: "crParser.parseBool"),
            parameters: ["value": .string("invalid")],
            session: session
        )
        XCTAssertEqual(parsedBool, .null)
    }

    func testPersistentVolumeMountUsesContainerCachingPolicy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostbox-volume-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GhostboxVolumeStore(rootURL: root)

        let metadata = try await store.create(name: "data", sizeInBytes: GhostboxVolumeStore.minimumSize)
        XCTAssertEqual(metadata.name, "data")
        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.name), ["data"])
        let inspected = try await store.inspect(name: "data")
        XCTAssertEqual(inspected.sizeInBytes, GhostboxVolumeStore.minimumSize)

        let mount = try await store.makeMount(
            volumeName: "data",
            mountReference: "@mount/data",
            destination: "/var/lib/data",
            readOnly: true
        )
        XCTAssertEqual(mount.options, ["ro"])
        guard case .virtioblk(let options) = mount.runtimeOptions else {
            return XCTFail("Expected a virtio block mount")
        }
        XCTAssertEqual(Set(options), [
            "vzDiskImageCachingMode=cached",
            "vzDiskImageSynchronizationMode=fsync",
        ])
        let redactedSource = await store.redactedSource(for: "@mount/data")
        XCTAssertEqual(redactedSource, "@volume/data")

        do {
            try await store.delete(name: "data")
            XCTFail("Expected a leased volume to reject deletion")
        } catch let error as DirectDispatchError {
            XCTAssertEqual(error.code, .failedPrecondition)
        }
        await store.releaseMount("@mount/data")
        try await store.delete(name: "data")
        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty)
    }
}
