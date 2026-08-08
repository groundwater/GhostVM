import XCTest

final class GhostboxSessionTests: XCTestCase {
    func testExplicitResourceLimitsUseVisibilityOrientedOverhead() {
        XCTAssertEqual(GhostboxResourceOverheadPolicy.cpu(requested: 1, explicit: nil), 0)
        XCTAssertEqual(
            GhostboxResourceOverheadPolicy.memory(requested: 536_870_912, explicit: nil),
            29_499_392
        )
        XCTAssertEqual(GhostboxResourceOverheadPolicy.cpu(requested: nil, explicit: nil), nil)
        XCTAssertEqual(GhostboxResourceOverheadPolicy.memory(requested: nil, explicit: nil), nil)
    }

    func testExplicitOverheadRemainsAuthoritative() {
        XCTAssertEqual(GhostboxResourceOverheadPolicy.cpu(requested: 1, explicit: 2), 2)
        XCTAssertEqual(GhostboxResourceOverheadPolicy.memory(requested: 536_870_912, explicit: 134_217_728), 134_217_728)
    }

    func testSessionProvidesTypedRuntimeContext() {
        let session = GhostboxSession(context: ["network": "shared"])

        XCTAssertEqual(session.contextValue("network", as: String.self), "shared")
        XCTAssertNil(session.contextValue("network", as: Int.self))
        XCTAssertNil(session.contextValue("missing", as: String.self))
    }

    func testExactUnregisterFreesNameWithoutRunningCleanup() async throws {
        let session = GhostboxSession()
        let first = TestValue(1)
        let cleanupCount = LockedCounter()
        let reference = try session.register(
            kind: "test",
            name: "value",
            value: first,
            equivalent: { $0 === $1 },
            cleanup: { _ in cleanupCount.increment() }
        )

        XCTAssertTrue(try session.unregister(reference, expectedKind: "test", matching: first))
        XCTAssertEqual(session.count, 0)
        XCTAssertEqual(
            try session.register(
                kind: "test",
                name: "value",
                value: TestValue(2),
                equivalent: { $0 === $1 }
            ),
            reference
        )
        await session.close()
        XCTAssertEqual(cleanupCount.value, 0)
    }

    func testUnregisterAndCleanupRunsCleanupExactlyOnce() async throws {
        let session = GhostboxSession()
        let value = TestValue(1)
        let cleanupCount = LockedCounter()
        let reference = try session.register(
            kind: "mount",
            name: "volume",
            value: value,
            equivalent: { $0 === $1 },
            cleanup: { _ in cleanupCount.increment() }
        )

        let removed = try await session.unregisterAndCleanup(reference, expectedKind: "mount", matching: value)
        XCTAssertTrue(removed)
        XCTAssertEqual(cleanupCount.value, 1)
        let removedAgain = try await session.unregisterAndCleanup(reference, expectedKind: "mount", matching: value)
        XCTAssertFalse(removedAgain)
        await session.close()
        XCTAssertEqual(cleanupCount.value, 1)
    }

    func testUnregisterCannotRemoveReplacementOrSiblingAlias() throws {
        let session = GhostboxSession()
        let value = TestValue(1)
        let other = TestValue(2)
        let aliases = try session.registerAliases(
            [(kind: "first", name: "value"), (kind: "second", name: "value")],
            value: value,
            equivalent: { $0 === $1 }
        )

        XCTAssertFalse(try session.unregister(aliases[0], expectedKind: "first", matching: other))
        XCTAssertTrue(try session.unregister(aliases[0], expectedKind: "first", matching: value))
        XCTAssertEqual(try session.value(for: aliases[1], expectedKind: "second", as: TestValue.self), value)
        XCTAssertEqual(session.count, 1)
    }

    func testAttachmentReadinessWaitsForReadyAndFailsWhenClosedFirst() async throws {
        let readiness = GhostboxAttachmentReadiness()
        let resumeCount = LockedCounter()
        let waiter = Task {
            try await readiness.wait()
            resumeCount.increment()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(resumeCount.value, 0)
        readiness.markReady()
        try await waiter.value
        XCTAssertEqual(resumeCount.value, 1)
        try await readiness.wait()

        let closed = GhostboxAttachmentReadiness()
        closed.close()
        do {
            try await closed.wait()
            XCTFail("Expected closed readiness to fail")
        } catch let error as DirectDispatchError {
            XCTAssertEqual(error.code, .failedPrecondition)
        }
    }

    func testMutableAggregateUpdatesRelatedStateThroughPublicReference() throws {
        struct Aggregate: Sendable, Equatable {
            var value: Int
            var relatedReference: String?
        }

        let session = GhostboxSession()
        let slot = GhostboxMutableSlot(Aggregate(value: 1, relatedReference: nil))
        let reference = try session.register(
            kind: "process-config",
            name: "diagnostic",
            value: slot,
            equivalent: { $0.get() == $1.get() }
        )
        let stored: GhostboxMutableSlot<Aggregate> = try session.value(
            for: reference,
            expectedKind: "process-config"
        )
        stored.update {
            $0.value = 2
            $0.relatedReference = "@terminal/diagnostic"
        }

        let updated: GhostboxMutableSlot<Aggregate> = try session.value(
            for: "@process-config/diagnostic",
            expectedKind: "process-config"
        )
        XCTAssertEqual(updated.get(), Aggregate(value: 2, relatedReference: "@terminal/diagnostic"))
        XCTAssertEqual(session.count, 1)
    }

    func testCloseDrainsActiveInvocationBeforeCleanup() async throws {
        let session = GhostboxSession()
        let cleanupCount = LockedCounter()
        try session.beginInvocation()
        _ = try session.register(
            kind: "test",
            name: "before-close",
            value: TestValue(1),
            equivalent: { $0 === $1 },
            cleanup: { _ in cleanupCount.increment() }
        )

        let closeTask = Task { await session.close() }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(cleanupCount.value, 0)
        _ = try session.register(
            kind: "test",
            name: "during-close",
            value: TestValue(2),
            equivalent: { $0 === $1 },
            cleanup: { _ in cleanupCount.increment() }
        )

        session.endInvocation()
        await closeTask.value
        XCTAssertEqual(session.count, 0)
        XCTAssertEqual(cleanupCount.value, 2)
    }

    func testCloseCancelsActiveInvocationBeforeWaitingForCleanup() async throws {
        let session = GhostboxSession()
        let cancellationCount = LockedCounter()
        let cleanupCount = LockedCounter()
        try session.beginInvocation()
        _ = try session.register(
            kind: "test",
            name: "attachment",
            value: TestValue(1),
            equivalent: { $0 === $1 },
            cancel: { _ in
                cancellationCount.increment()
                session.endInvocation()
            },
            cleanup: { _ in cleanupCount.increment() }
        )

        await session.close()

        XCTAssertEqual(cancellationCount.value, 1)
        XCTAssertEqual(cleanupCount.value, 1)
        XCTAssertEqual(session.count, 0)
    }

    func testStoredRepresentationMismatchIsNotReportedAsMissing() throws {
        let session = GhostboxSession()
        let reference = try session.register(
            kind: "test",
            name: "value",
            value: TestValue(1),
            equivalent: { $0 === $1 }
        )

        XCTAssertThrowsError(
            try session.value(
                for: reference,
                expectedKind: "test",
                as: GhostboxMutableSlot<TestValue>.self
            )
        ) { error in
            guard let error = error as? DirectDispatchError else {
                return XCTFail("Expected DirectDispatchError")
            }
            XCTAssertEqual(error.code, .failedPrecondition)
        }
    }

    func testMutableSlotSerializesConcurrentUpdates() async {
        let slot = GhostboxMutableSlot(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1_000 {
                group.addTask { slot.update { $0 += 1 } }
            }
        }

        XCTAssertEqual(slot.get(), 1_000)
    }

    func testRegisterNewDoesNotConstructDuplicateValue() throws {
        let session = GhostboxSession()
        let constructionCount = LockedCounter()
        _ = try session.registerNew(
            kind: "test",
            name: "value",
            makeValue: {
                constructionCount.increment()
                return TestValue(1)
            },
            equivalent: { $0 === $1 }
        )

        XCTAssertThrowsError(
            try session.registerNew(
                kind: "test",
                name: "value",
                makeValue: {
                    constructionCount.increment()
                    return TestValue(2)
                },
                equivalent: { $0 === $1 }
            )
        )
        XCTAssertEqual(constructionCount.value, 1)
    }

    func testTypedValueSnapshotsFilterSortAndPreserveReferences() throws {
        let session = GhostboxSession()
        _ = try session.register(kind: "container", name: "zeta", value: 2, equivalent: { $0 == $1 })
        _ = try session.register(kind: "manager", name: "ignored", value: 3, equivalent: { $0 == $1 })
        _ = try session.register(kind: "container", name: "alpha", value: 1, equivalent: { $0 == $1 })

        let snapshots: [(reference: String, value: Int)] = try session.valueSnapshots(ofKind: "container")

        XCTAssertEqual(snapshots.map(\.reference), ["@container/alpha", "@container/zeta"])
        XCTAssertEqual(snapshots.map(\.value), [1, 2])
    }

}

private final class TestValue: @unchecked Sendable, Equatable {
    let id: Int
    init(_ id: Int) { self.id = id }
    static func == (lhs: TestValue, rhs: TestValue) -> Bool { lhs === rhs }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
