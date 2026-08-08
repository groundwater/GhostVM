@testable import ghostbox
import XCTest

final class ArgsTests: XCTestCase {
    func testNoArgumentsReturnsHelp() {
        guard case .success(let options) = parseArguments([]), case .help(let topic) = options.action else {
            return XCTFail("Expected help")
        }
        XCTAssertEqual(topic, [])
    }

    func testHelpAndVersionFlags() {
        for flag in ["--help", "-h", "help"] {
            guard case .success(let options) = parseArguments([flag]), case .help(let topic) = options.action else {
                return XCTFail("Expected help for \(flag)")
            }
            XCTAssertEqual(topic, [])
        }
        for flag in ["--version", "-v"] {
            guard case .success(let options) = parseArguments([flag]), case .version = options.action else {
                return XCTFail("Expected version for \(flag)")
            }
        }
    }

    func testParsesQualifiedHelpTopics() {
        let cases: [([String], [String])] = [
            (["cn:help"], ["cn"]),
            (["containerization:help"], ["cn"]),
            (["cr:help"], ["cr"]),
            (["container:help"], ["cr"]),
            (["cn:image-store:help"], ["cn", "image-store"]),
            (["containerization:image-store:help"], ["cn", "image-store"]),
            (["cn:image-store:pull", "--help"], ["cn:image-store:pull"]),
            (["cn:image-store:pull", "@image-store/default", "--help"], ["cn:image-store:pull"]),
        ]
        for (arguments, expectedTopic) in cases {
            guard case .success(let options) = parseArguments(arguments),
                  case .help(let topic) = options.action else {
                return XCTFail("Expected help for \(arguments)")
            }
            XCTAssertEqual(topic, expectedTopic)
        }
    }

    func testHelpFlagMustBeFinal() {
        guard case .failure(.invalidDirect(let message)) = parseArguments([
            "cn:image-store:pull", "--help", "alpine",
        ]) else {
            return XCTFail("Expected invalid help placement")
        }
        XCTAssertTrue(message.contains("final argument"))
    }

    func testParsesDNSCreateWithFrameworkDefaults() throws {
        let invocation = try directInvocation(["cn:dns:create", "default"])
        XCTAssertEqual(invocation.method, .dnsCreate)
        XCTAssertEqual(invocation.parameters["name"], .string("default"))
        XCTAssertNil(invocation.parameters["nameservers"])
        XCTAssertNil(invocation.parameters["domain"])
        XCTAssertEqual(invocation.parameters["searchDomains"], .array([]))
        XCTAssertEqual(invocation.parameters["options"], .array([]))
    }

    func testParsesConfiguredDNSCreate() throws {
        let invocation = try directInvocation([
            "cn:dns:create", "dev",
            "--nameserver", "1.1.1.1",
            "--nameserver", "2606:4700:4700::1111",
            "--domain", "example.test",
            "--search-domain", "svc.example.test",
            "--option", "ndots:2",
        ])
        XCTAssertEqual(invocation.parameters["nameservers"], .array([.string("1.1.1.1"), .string("2606:4700:4700::1111")]))
        XCTAssertEqual(invocation.parameters["domain"], .string("example.test"))
        XCTAssertEqual(invocation.parameters["searchDomains"], .array([.string("svc.example.test")]))
        XCTAssertEqual(invocation.parameters["options"], .array([.string("ndots:2")]))
    }

    func testDNSCreatePreservesEmptyInitializerValues() throws {
        let invocation = try directInvocation([
            "cn:dns:create", "empty", "--nameserver", "", "--domain", "",
            "--search-domain", "", "--option", "",
        ])
        XCTAssertEqual(invocation.parameters["nameservers"], .array([.string("")]))
        XCTAssertEqual(invocation.parameters["domain"], .string(""))
        XCTAssertEqual(invocation.parameters["searchDomains"], .array([.string("")]))
        XCTAssertEqual(invocation.parameters["options"], .array([.string("")]))
    }

    func testPreservesAllThirteenEstablishedCommandMappings() throws {
        let commands: [([String], GhostboxDirectMethod, [String: GhostboxJSONValue])] = [
            (["cn:dns:create", "dev"], .dnsCreate, ["name": .string("dev"), "searchDomains": .array([]), "options": .array([])]),
            (["cn:dns:default-nameservers"], .dnsDefaultNameservers, [:]),
            (["cn:dns:validate", "@dns/dev"], .dnsValidate, ["reference": .string("@dns/dev")]),
            (["cn:dns:resolv-conf", "@dns/dev"], .dnsResolvConf, ["reference": .string("@dns/dev")]),
            (["cn:dns:nameservers", "@dns/dev"], .dnsNameservers, ["reference": .string("@dns/dev")]),
            (["cn:dns:domain", "@dns/dev"], .dnsDomain, ["reference": .string("@dns/dev")]),
            (["cn:dns:search-domains", "@dns/dev"], .dnsSearchDomains, ["reference": .string("@dns/dev")]),
            (["cn:dns:options", "@dns/dev"], .dnsOptions, ["reference": .string("@dns/dev")]),
            (["cn:process-config:default-path"], .processConfigDefaultPath, [:]),
            (["cn:container:default-masked-paths"], .containerDefaultMaskedPaths, [:]),
            (["cn:container:default-readonly-paths"], .containerDefaultReadonlyPaths, [:]),
            (["cn:container:default-copy-chunk-size"], .containerDefaultCopyChunkSize, [:]),
            (["cn:container:max-id-length"], .containerMaxIDLength, [:]),
        ]

        XCTAssertEqual(commands.count, 13)
        for (arguments, method, parameters) in commands {
            let invocation = try directInvocation(arguments)
            XCTAssertEqual(invocation.method, method, "Unexpected method for \(arguments)")
            XCTAssertEqual(invocation.parameters, parameters, "Unexpected parameters for \(arguments)")
        }
    }

    func testAcceptsCatalogCommand() throws {
        let invocation = try directInvocation(["cn:image-store:list", "@image-store/default"])
        XCTAssertEqual(invocation.method.rawValue, "imageStore.list")
        XCTAssertEqual(invocation.parameters, ["imageStore": .string("@image-store/default")])
    }

    func testParsesDefaultHostKernelExtension() throws {
        let invocation = try directInvocation(["cn:kernel:default"])
        XCTAssertEqual(invocation.method, .kernelDefault)
        XCTAssertEqual(invocation.parameters, [:])
    }

    func testParsesInstallRecommendedHostKernelExtension() throws {
        let invocation = try directInvocation(["cn:kernel:install-recommended"])
        XCTAssertEqual(invocation.method, .kernelInstallRecommended)
        XCTAssertEqual(invocation.parameters, [:])
    }

    func testCatalogMapsReferencesOptionsAndPositionalsToParameters() throws {
        let invocation = try directInvocation([
            "cn:image-store:pull", "@image-store/default", "alpine",
            "--insecure=false", "--authentication", "@authentication/default",
        ])
        XCTAssertEqual(invocation.method.rawValue, "imageStore.pull")
        XCTAssertEqual(invocation.parameters, [
            "imageStore": .string("@image-store/default"),
            "reference": .string("alpine"),
            "insecure": .boolean(false),
            "authentication": .string("@authentication/default"),
            "maxConcurrentDownloads": .integer(3),
        ])
    }

    func testRejectsInvalidDNSReference() {
        guard case .failure(.invalidDirect) = parseArguments(["cn:dns:validate", "@hosts/dev"]) else {
            return XCTFail("Expected wrong-kind reference rejection")
        }
    }

    func testParsesIOProxyCreationAndCloseCommands() throws {
        let commands: [([String], GhostboxDirectMethod, [String: GhostboxJSONValue])] = [
            (["cn:reader-stream:create", "input"], .readerStreamCreateProxy, ["readerStream": .string("input")]),
            (["cn:reader-stream:close", "@reader-stream/input"], .readerStreamCloseProxy, ["readerStream": .string("@reader-stream/input")]),
            (["cn:writer:create", "output"], .writerCreateProxy, ["writer": .string("output")]),
            (["cn:writer:close", "@writer/output"], .writerCloseProxy, ["writer": .string("@writer/output")]),
            (["cn:terminal:create", "shell"], .terminalCreateProxy, [
                "terminal": .string("shell"), "width": .unsignedInteger(80), "height": .unsignedInteger(24),
            ]),
            (["cn:terminal:create", "wide", "--width=132", "--height=43"], .terminalCreateProxy, [
                "terminal": .string("wide"), "width": .unsignedInteger(132), "height": .unsignedInteger(43),
            ]),
            (["cn:terminal:wait-attached", "@terminal/shell"], .terminalWaitAttachedProxy, [
                "terminal": .string("@terminal/shell"),
            ]),
            (["cn:terminal:close", "@terminal/shell"], .terminalCloseProxy, ["terminal": .string("@terminal/shell")]),
        ]
        for (arguments, method, parameters) in commands {
            let invocation = try directInvocation(arguments)
            XCTAssertEqual(invocation.method, method)
            XCTAssertEqual(invocation.parameters, parameters)
        }
    }

    func testParsesResourceCleanupExtensions() throws {
        let commands: [([String], GhostboxDirectMethod, [String: GhostboxJSONValue])] = [
            (["cn:dns:delete", "@dns/dev"], .dnsDelete, ["dns": .string("@dns/dev")]),
            (["cn:process-config:delete", "@process-config/dev"], .processConfigDelete, [
                "processConfig": .string("@process-config/dev"),
            ]),
            (["cn:network:delete", "@network/dev"], .networkDelete, ["network": .string("@network/dev")]),
            (["cn:manager:close", "@manager/dev"], .managerClose, ["manager": .string("@manager/dev")]),
        ]
        for (arguments, method, parameters) in commands {
            let invocation = try directInvocation(arguments)
            XCTAssertEqual(invocation.method, method)
            XCTAssertEqual(invocation.parameters, parameters)
        }
    }

    func testParsesIOProxyAttachments() {
        let commands: [([String], GhostboxDirectMethod, GhostboxIOStream)] = [
            (["cn:reader-stream:attach", "@reader-stream/input"], .readerStreamAttachProxy, .input),
            (["cn:writer:attach", "@writer/output"], .writerAttachProxy, .output),
            (["cn:terminal:attach", "@terminal/shell"], .terminalAttachProxy, .terminal),
        ]
        for (arguments, method, stream) in commands {
            guard case .success(let options) = parseArguments(arguments),
                  case .attach(let invocation, let parsedStream) = options.action else {
                return XCTFail("Expected attachment for \(arguments)")
            }
            XCTAssertEqual(invocation.method, method)
            XCTAssertEqual(parsedStream, stream)
        }

        guard case .success(let options) = parseArguments([
            "cn:terminal:attach", "@terminal/shell", "--resize-target", "@container/job",
        ]), case .attach(let invocation, .terminal) = options.action else {
            return XCTFail("Expected terminal attachment with resize target")
        }
        XCTAssertEqual(invocation.parameters, [
            "terminal": .string("@terminal/shell"),
            "resizeTarget": .string("@container/job"),
        ])
    }

    func testRejectsMalformedIOProxyCommands() {
        let commands = [
            ["cn:reader-stream:create", "bad/name"],
            ["cn:writer:attach", "@reader-stream/wrong"],
            ["cn:terminal:create", "shell", "--width=0"],
            ["cn:terminal:unknown", "@terminal/shell"],
            ["cn:terminal:wait-attached", "@terminal/shell", "extra"],
            ["cn:writer:attach", "@writer/output", "extra"],
            ["cn:terminal:attach", "@terminal/shell", "--resize-target", "@writer/wrong"],
        ]
        for arguments in commands {
            guard case .failure(.invalidDirect) = parseArguments(arguments) else {
                return XCTFail("Expected rejection for \(arguments)")
            }
        }
    }

    func testIOProxyHelp() throws {
        for resource in ["reader-stream", "writer", "terminal"] {
            guard case .success(let help) = renderGhostboxHelp(["cn:\(resource):help"]) else {
                return XCTFail("Expected help for \(resource)")
            }
            XCTAssertTrue(help.contains("ghostbox cn:\(resource):attach"))
            XCTAssertTrue(help.contains("ghostbox cn:\(resource):close"))
            if resource == "terminal" {
                XCTAssertTrue(help.contains("ghostbox cn:terminal:wait-attached"))
            }
        }
    }

    func testParsesGuestShareMountAndCleanup() throws {
        let create = try directInvocation([
            "cn:mount:guest-share", "source",
            "--source", "/Users/guest/project",
            "--destination", "/workspace",
            "--read-only=true",
            "--cache-ttl=0",
            "--option", "nodev",
        ])
        XCTAssertEqual(create.method, .mountGuestShare)
        XCTAssertEqual(create.parameters, [
            "mount": .string("source"),
            "source": .string("/Users/guest/project"),
            "destination": .string("/workspace"),
            "readOnly": .boolean(true),
            "cacheTTL": .unsignedInteger(0),
            "option": .array([.string("nodev")]),
            "runtimeOption": .array([]),
        ])

        let delete = try directInvocation(["cn:mount:delete", "@mount/source"])
        XCTAssertEqual(delete.method, .mountDelete)
        XCTAssertEqual(delete.parameters, ["mount": .string("@mount/source")])
    }

    func testParsesPersistentVolumeLifecycle() throws {
        let create = try directInvocation(["cr:volume:create", "data", "--size", "67108864"])
        XCTAssertEqual(create.method, .volumeCreate)
        XCTAssertEqual(create.parameters, [
            "volume": .string("data"),
            "size": .unsignedInteger(67_108_864),
        ])

        XCTAssertEqual(try directInvocation(["cr:volume:list"]).method, .volumeList)
        XCTAssertEqual(try directInvocation(["cr:volume:inspect", "@volume/data"]).method, .volumeInspect)

        let mount = try directInvocation([
            "cr:volume:mount", "@volume/data", "data-mount",
            "--destination=/var/lib/data", "--read-only",
        ])
        XCTAssertEqual(mount.method, .volumeMount)
        XCTAssertEqual(mount.parameters, [
            "volume": .string("@volume/data"),
            "mount": .string("data-mount"),
            "destination": .string("/var/lib/data"),
            "readOnly": .boolean(true),
        ])

        XCTAssertEqual(try directInvocation(["cr:volume:delete", "@volume/data"]).method, .volumeDelete)
    }

    func testRejectsMalformedPersistentVolumes() {
        let commands = [
            ["cr:volume:create", "../data"],
            ["cr:volume:create", "data", "--size", "many"],
            ["cr:volume:mount", "@volume/data", "data", "--destination", "/"],
            ["cr:volume:inspect", "@volume/data", "extra"],
        ]
        for command in commands {
            guard case .failure(.invalidDirect) = parseArguments(command) else {
                return XCTFail("Expected rejection for \(command)")
            }
        }
    }

    func testCleanupParsingDoesNotClaimResourceNames() throws {
        let create = try directInvocation([
            "cn:mount:guest-share", "delete",
            "--source", "/tmp",
            "--destination", "/workspace",
        ])
        XCTAssertEqual(create.method, .mountGuestShare)
        XCTAssertEqual(create.parameters["mount"], .string("delete"))
    }

    func testContainerForwardHelpDoesNotRequireReference() {
        guard case .success(let help) = renderGhostboxHelp(["cn:container:forward"]) else {
            return XCTFail("Expected container forward help")
        }
        XCTAssertTrue(help.contains("ghostbox cn:container:forward @container/NAME"))
        XCTAssertTrue(help.contains("GhostVM guest extension"))
    }

    func testParsesContainerPortForwarding() {
        guard case .success(let options) = parseArguments([
            "cn:container:forward", "@container/web",
            "-P", "8080:80/tcp",
            "--publish=127.0.0.1:8443:443",
        ]), case .forward(let container, let ports) = options.action else {
            return XCTFail("Expected port forwarding")
        }
        XCTAssertEqual(container, "@container/web")
        XCTAssertEqual(ports, [
            PublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80),
            PublishedPort(hostAddress: "127.0.0.1", hostPort: 8443, containerPort: 443),
        ])
    }

    func testRejectsMalformedGuestShareAndPortForwarding() {
        let commands = [
            ["cn:mount:guest-share", "source", "--source", "relative", "--destination", "/workspace"],
            ["cn:mount:guest-share", "source", "--source", "/tmp", "--destination", "/"],
            ["cn:mount:guest-share", "source", "--source", "/tmp", "--destination", "/workspace", "--cache-ttl", "301"],
            ["cn:container:forward", "@container/web", "-p", "8080:80/udp"],
            ["cn:container:forward", "@container/web"],
        ]
        for command in commands {
            guard case .failure(.invalidDirect) = parseArguments(command) else {
                return XCTFail("Expected rejection for \(command)")
            }
        }
    }

    func testRejectsOldUnqualifiedCommandGrammar() {
        let commands = [
            ["dns", "create", "dev"],
            ["dns", "@dns/dev", "validate"],
            ["image-store", "@image-store/default", "pull", "alpine"],
            ["container", "@container/web", "forward", "-p", "8080:80"],
            ["volume", "@volume/data", "inspect"],
        ]
        for command in commands {
            guard case .failure(.invalidDirect) = parseArguments(command) else {
                return XCTFail("Expected old unqualified grammar rejection for \(command)")
            }
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

    private enum TestError: Error {
        case notDirect
    }
}
