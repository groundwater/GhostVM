@testable import ghostbox
import XCTest

final class CommandCatalogTests: XCTestCase {
    func testGeneratedCatalogCountsAndUniqueness() {
        XCTAssertEqual(ghostboxCommandCatalog.count, 282)
        XCTAssertEqual(ghostboxCommandFixtures.count, 282)
        XCTAssertEqual(ghostboxCommandCatalog.filter { $0.namespace == "cn" }.count, 260)
        XCTAssertEqual(ghostboxCommandCatalog.filter { $0.namespace == "cr" }.count, 22)
        XCTAssertEqual(ghostboxCommandResources.count, 39)
        XCTAssertEqual(Set(ghostboxCommandResources).count, 39)

        let qualifiedResources = Set(ghostboxCommandCatalog.map { "\($0.namespace):\($0.resource)" })
        XCTAssertEqual(qualifiedResources.count, 39)
        XCTAssertEqual(Set(ghostboxCommandCatalog.filter { $0.namespace == "cn" }.map(\.resource)).count, 35)
        XCTAssertEqual(Set(ghostboxCommandCatalog.filter { $0.namespace == "cr" }.map(\.resource)).count, 4)

        let commandIDs = ghostboxCommandCatalog.map(\.commandID)
        let methodIDs = ghostboxCommandCatalog.map(\.methodID)
        XCTAssertEqual(Set(commandIDs).count, commandIDs.count)
        XCTAssertEqual(Set(methodIDs).count, methodIDs.count)
        XCTAssertEqual(Set(ghostboxCommandFixtures.map(\.commandID)), Set(commandIDs))
        XCTAssertEqual(Set(ghostboxCommandFixtures.map(\.methodID)), Set(methodIDs))
        let signatures = ghostboxCommandCatalog.map {
            "\($0.namespace)|\($0.resource)|\($0.shape.rawValue)|\($0.operation)"
        }
        XCTAssertEqual(Set(signatures).count, signatures.count)

        let sourceKinds = Dictionary(grouping: ghostboxCommandCatalog, by: \.sourceKind).mapValues(\.count)
        XCTAssertEqual(sourceKinds, ["direct": 277, "ghostvm-adapter": 5])
    }

    func testCatalogSourceMetadata() {
        let adapterCommands = ghostboxCommandCatalog.filter { $0.sourceKind == "ghostvm-adapter" }
        XCTAssertEqual(Set(adapterCommands.map(\.commandID)), [
            "cr:volume:create",
            "cr:volume:list",
            "cr:volume:inspect",
            "cr:volume:mount",
            "cr:volume:delete",
        ])
        for command in adapterCommands {
            XCTAssertEqual(command.namespace, "cr", command.commandID)
            XCTAssertEqual(command.swiftModule, "GhostVMContainerRuntime", command.commandID)
            XCTAssertNotNil(command.swiftSource, command.commandID)
            XCTAssertTrue(command.appleDocumentationURL.hasPrefix("macOS/GhostVMContainerRuntime/"), command.commandID)
        }
    }

    func testEveryMinimalFixtureAndFullAliasParseIdentically() throws {
        let catalogByCommandID = Dictionary(uniqueKeysWithValues: ghostboxCommandCatalog.map { ($0.commandID, $0) })
        for fixture in ghostboxCommandFixtures {
            guard let command = catalogByCommandID[fixture.commandID] else {
                return XCTFail("Missing catalog command \(fixture.commandID)")
            }
            XCTAssertEqual(fixture.argv.first, fixture.commandID)
            XCTAssertEqual(command.methodID, fixture.methodID)

            let canonical = try directInvocation(fixture.argv)
            XCTAssertEqual(canonical.method.rawValue, fixture.methodID, fixture.argv.joined(separator: " "))

            let expectedAlias = command.namespace == "cn"
                ? command.commandID.replacingOccurrences(of: "cn:", with: "containerization:", options: .anchored)
                : command.commandID.replacingOccurrences(of: "cr:", with: "container:", options: .anchored)
            XCTAssertEqual(command.aliases, [expectedAlias], command.commandID)
            for alias in command.aliases {
                let aliasArguments = [alias] + fixture.argv.dropFirst()
                let aliased = try directInvocation(aliasArguments)
                XCTAssertEqual(aliased.method.rawValue, fixture.methodID, alias)
                XCTAssertEqual(aliased.parameters, canonical.parameters, alias)
            }
        }
    }

    func testDefaultsUseCatalogTypes() throws {
        let invocation = try directInvocation(["cn:vm-config:create", "dev"])
        XCTAssertEqual(invocation.parameters["vmConfig"], .string("dev"))
        XCTAssertEqual(invocation.parameters["cpus"], .integer(4))
        XCTAssertEqual(invocation.parameters["memory"], .unsignedInteger(1_073_741_824))
        XCTAssertEqual(invocation.parameters["nestedVirtualization"], .boolean(false))

        let network = try directInvocation(["cn:network:vmnet-create", "dev"])
        XCTAssertEqual(network.parameters["mode"], .string("shared"))
    }

    func testRepeatableOptionsAndOptionEquals() throws {
        let invocation = try directInvocation([
            "cn:dns:create", "dev",
            "--nameserver=1.1.1.1",
            "--nameserver", "8.8.8.8",
            "--domain=example.test",
        ])
        XCTAssertEqual(invocation.parameters["nameservers"], .array([.string("1.1.1.1"), .string("8.8.8.8")]))
        XCTAssertEqual(invocation.parameters["domain"], .string("example.test"))
    }

    func testDoubleDashPreservesVariadicPositionalStrings() throws {
        let invocation = try directInvocation([
            "cn:process-config:create", "shell", "--", "--login", "--noprofile",
        ])
        XCTAssertEqual(invocation.parameters["argument"], .array([.string("--login"), .string("--noprofile")]))
    }

    func testJSONArgumentsBecomeObjects() throws {
        let invocation = try directInvocation([
            "cn:process-config:from-image-config", "config", #"{"user":"root","env":["A=B"]}"#,
        ])
        XCTAssertEqual(invocation.parameters["imageConfig"], .object([
            "user": .string("root"),
            "env": .array([.string("A=B")]),
        ]))
    }

    func testOCIPlatformExampleRemainsAString() throws {
        let invocation = try directInvocation([
            "cn:image:config", "@image/example", "linux/arm64",
        ])
        XCTAssertEqual(invocation.parameters["platform"], .string("linux/arm64"))
    }

    func testRejectsUnknownDuplicateAndMissingOptionValues() {
        assertInvalid(["cn:dns:create", "dev", "--unknown", "value"])
        assertInvalid(["cn:dns:create", "dev", "--domain", "one", "--domain=two"])
        assertInvalid(["cn:dns:create", "dev", "--domain"])
        assertInvalid(["cn:image-store:create", "store"])
    }

    func testRejectsMalformedNamesAndReferences() {
        assertInvalid(["cn:dns:create", "bad/name"])
        assertInvalid(["cn:dns:validate", "@hosts/dev"])
        assertInvalid(["cn:dns:validate", "@dns/dev/extra"])
        assertInvalid(["cn:dns:validate", "@dns/"])
    }

    func testRejectsNumericOverflowAndInvalidJSON() {
        assertInvalid(["cn:container:resize", "@container/dev", "65536", "1"])
        assertInvalid([
            "cn:rlimit:create", "open-files",
            "--kind", "@rlimit-kind/nofile",
            "--hard", "18446744073709551616",
            "--soft", "1",
        ])
        assertInvalid(["cn:process-config:from-image-config", "config", "[]"])
    }

    func testRootHelpContainsEverySignatureAndAppleDocumentationLink() {
        XCTAssertTrue(ghostboxHelp.contains("Containerization (cn):"))
        XCTAssertTrue(ghostboxHelp.contains("Container (cr):"))
        let normalizedHelp = helpWithoutIndentation(ghostboxHelp)
        for command in ghostboxCommandCatalog {
            XCTAssertTrue(normalizedHelp.contains(command.signature), command.methodID)
            XCTAssertTrue(ghostboxHelp.contains("Apple API: \(command.appleAPISymbol)"), command.methodID)
            XCTAssertTrue(ghostboxHelp.contains("Apple docs: \(command.appleDocumentationURL)"), command.methodID)
        }
    }

    func testNamespaceHelpFiltersCommandsAndResources() throws {
        for (namespace, otherNamespace) in [("cn", "cr"), ("cr", "cn")] {
            let help = try helpText([namespace])
            let normalizedHelp = helpWithoutIndentation(help)
            let commands = ghostboxCommandCatalog.filter { $0.namespace == namespace }
            XCTAssertEqual(Set(commands.map(\.resource)).count, namespace == "cn" ? 35 : 4)
            for command in commands {
                XCTAssertTrue(normalizedHelp.contains(command.signature), command.commandID)
            }
            for command in ghostboxCommandCatalog where command.namespace == otherNamespace {
                XCTAssertFalse(normalizedHelp.contains(command.signature), command.commandID)
            }
        }
    }

    func testEveryCommandHasDetailedScopedHelp() throws {
        for command in ghostboxCommandCatalog {
            let help = try helpText([command.commandID])
            XCTAssertTrue(helpWithoutIndentation(help).contains(command.signature), command.methodID)
            XCTAssertTrue(help.contains("Method: \(command.methodID)"), command.methodID)
            XCTAssertTrue(help.contains("Apple API: \(command.appleAPISymbol)"), command.methodID)
            XCTAssertTrue(help.contains("Apple docs: \(command.appleDocumentationURL)"), command.methodID)
            XCTAssertTrue(help.contains("\nOutput:\n"), command.methodID)
            XCTAssertTrue(help.contains("\nExample:\n  ghostbox "), command.methodID)

            for alias in command.aliases {
                XCTAssertEqual(try helpText([alias]), help, alias)
            }
        }
    }

    func testDetailedHelpExplainsArgumentsOptionsDefaultsAndOutput() throws {
        let help = try helpText(["cn:image-store:pull"])
        XCTAssertTrue(help.contains("@<image-store:id>  required, receiver"))
        XCTAssertTrue(help.contains("<reference:string>  required; string"))
        XCTAssertTrue(help.contains("--insecure  optional, default: false; type: bool; true or false"))
        XCTAssertTrue(help.contains("--max-concurrent-downloads  optional, default: 3; type: int"))
        XCTAssertTrue(help.contains("reference:image: canonical host-owned image reference"))
        XCTAssertTrue(help.contains("ghostbox cn:image-store:pull @image-store/example example"))
    }

    func testDefaultHostKernelExtensionHelp() throws {
        XCTAssertTrue(ghostboxHelp.contains("ghostbox cn:kernel:install-recommended -> @kernel/default"))
        XCTAssertTrue(ghostboxHelp.contains("ghostbox cn:kernel:default -> @kernel/default"))
        let help = try helpText(["cn:kernel:default"])
        XCTAssertTrue(help.contains("Method: kernel.default"))
        XCTAssertTrue(help.contains("KernelService.getDefaultKernel"))

        let installHelp = try helpText(["cn:kernel:install-recommended"])
        XCTAssertTrue(installHelp.contains("Method: kernel.installRecommended"))
        XCTAssertTrue(installHelp.contains("KernelService.installKernelFrom"))
    }

    func testCleanupExtensionHelp() throws {
        for topic in [
            ["cn:dns:delete"],
            ["cn:process-config:delete"],
            ["cn:network:delete"],
            ["cn:manager:close"],
        ] {
            let help = try helpText(topic)
            XCTAssertTrue(help.contains("GhostVM host extension"), topic.joined(separator: " "))
        }
    }

    func testQualifiedResourceHelpContainsOnlyThatNamespaceAndResource() throws {
        let help = try helpText(["cn:kernel-image:help"])
        let normalizedHelp = helpWithoutIndentation(help)
        for command in ghostboxCommandCatalog where command.namespace == "cn" && command.resource == "kernel-image" {
            XCTAssertTrue(normalizedHelp.contains(command.signature), command.methodID)
        }
        XCTAssertFalse(help.contains("ghostbox cn:init-image:"))
        XCTAssertFalse(help.contains("ghostbox cr:"))

        let volumeHelp = try helpText(["cr:volume:help"])
        XCTAssertTrue(volumeHelp.contains("ghostbox cr:volume:create"))
        XCTAssertFalse(volumeHelp.contains("ghostbox cn:"))
        XCTAssertFalse(volumeHelp.contains("cr:memory-size:"))
    }

    func testHelpRejectsUnknownTopics() {
        guard case .failure(.invalidDirect(let resourceMessage)) = renderGhostboxHelp(["cn:missing:help"]) else {
            return XCTFail("Expected unknown resource failure")
        }
        XCTAssertTrue(resourceMessage.contains("unknown resource"))

        guard case .failure(.invalidDirect(let operationMessage)) = renderGhostboxHelp([
            "cn:image-store:missing",
        ]) else {
            return XCTFail("Expected unknown operation failure")
        }
        XCTAssertTrue(operationMessage.contains("unknown help command"))
    }

    func testOldUnqualifiedCommandsAndHelpTopicsAreRejected() {
        for command in [
            ["dns", "create", "dev"],
            ["image-store", "@image-store/example", "list"],
            ["volume", "list"],
        ] {
            assertInvalid(command)
        }
        for topic in [
            ["image-store"],
            ["image-store", "pull"],
            ["volume", "list"],
        ] {
            guard case .failure(.invalidDirect) = renderGhostboxHelp(topic) else {
                return XCTFail("Expected old unqualified help rejection: \(topic)")
            }
        }
    }

    private func assertInvalid(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(.invalidDirect) = parseArguments(arguments) else {
            return XCTFail("Expected invalid direct invocation: \(arguments)", file: file, line: line)
        }
    }

    private func directInvocation(_ arguments: [String]) throws -> GhostboxDirectInvocation {
        switch parseArguments(arguments) {
        case .success(let options):
            guard case .direct(let invocation) = options.action else {
                throw TestError.notDirect
            }
            return invocation
        case .failure(let error):
            throw error
        }
    }

    private func helpText(_ topic: [String]) throws -> String {
        switch renderGhostboxHelp(topic) {
        case .success(let help):
            return help
        case .failure(let error):
            throw error
        }
    }

    private func helpWithoutIndentation(_ help: String) -> String {
        help.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.drop(while: { $0 == " " }))
        }.joined(separator: "\n")
    }

    private enum TestError: Error {
        case notDirect
    }
}
