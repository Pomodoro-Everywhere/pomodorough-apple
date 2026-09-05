import Foundation
import Testing
import WasmKit
@testable import Pomodorough

@Suite("Shared core WebAssembly ABI")
struct SharedCoreWASMTests {
    private final class SequencedFreeFailures: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func validate(_: [Value]) throws {
            lock.lock()
            count += 1
            let current = count
            lock.unlock()
            throw SharedCoreError.invalidABIResult("synthetic free failure \(current)")
        }
    }

    private struct CoreVersion: Decodable, Equatable, Sendable {
        let schemaVersion: Int
        let coreVersion: String
    }

    private struct HLCHead: Decodable, Equatable, Sendable {
        let wallMs: Int64
        let counter: Int64
    }

    @Test func coreVersionDispatchesThroughBundledWebAssembly() throws {
        let core = try SharedCore.bundled()

        let version = try core.dispatch(
            "core.version",
            inputJSON: Data("{}".utf8),
            as: CoreVersion.self
        )

        #expect(version == CoreVersion(schemaVersion: 1, coreVersion: "0.11.0"))
    }

    @Test func hlcHeadDispatchesThroughBundledWebAssembly() throws {
        let core = try SharedCore.bundled()
        let input = Data(
            #"{"physicalNowMs":100,"observed":[{"wallMs":101,"counter":2},{"wallMs":101,"counter":7},{"wallMs":99,"counter":99}]}"#.utf8
        )

        let head = try core.dispatch(
            "hlc.head.v1",
            inputJSON: input,
            as: HLCHead.self
        )

        #expect(head == HLCHead(wallMs: 101, counter: 7))
    }

    @Test func reconcileAcceptsSubmillisecondServerTime() throws {
        let response = try JSONDecoder.api.decode(
            SyncResponse.self,
            from: Data(#"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[],"autoStartAcknowledgements":[],"selectedTaskAcknowledgements":[],"selectedTaskId":null,"durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000},"autoStartBreaks":false,"revision":423,"canonicalTimer":null,"history":[],"tasks":[],"serverTime":"2026-09-05T14:12:50.776530Z","serverHlcWallMs":1788617570776,"serverHlcCounter":0}"#.utf8)
        )
        let input = CoreReconcileInput(
            local: CoreReconcileLocalQueues(state: .fresh()),
            sent: CoreReconcileSentQueues(
                commands: [],
                taskOperations: [],
                durationOperations: [],
                autoStartOperations: [],
                selectedTaskOperations: []
            ),
            response: CoreReconcileCanonicalResponse(response),
            timerDependencies: []
        )

        let output = try SharedCore.bundled().reconcileRebase(input)

        #expect(output.revision == response.revision)
    }

    @Test func rejectedFreePreservesPrimaryFailureAndForcesFreshRuntime() throws {
        let failures = SequencedFreeFailures()
        let core = SharedCore(
            moduleURL: try SharedCore.bundledModuleURL(),
            freeResultValidator: failures.validate
        )

        do {
            let _: CoreVersion = try core.dispatch(
                "missing.operation",
                inputJSON: Data("{}".utf8),
                as: CoreVersion.self
            )
            Issue.record("rejected free must fail the dispatch")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("synthetic free failure 1"))
            #expect(description.contains("synthetic free failure 2"))
        }
        do {
            let _: CoreVersion = try core.dispatch(
                "core.version",
                inputJSON: Data("{}".utf8),
                as: CoreVersion.self
            )
            Issue.record("fresh runtime cleanup must still observe the injected rejection")
        } catch {
            #expect(String(describing: error).contains("synthetic free failure"))
        }
    }

    @Test func bundledWASMReportsInvalidAndDuplicateFrees() throws {
        let bytes = try Data(contentsOf: SharedCore.bundledModuleURL())
        let module = try parseWasm(bytes: Array(bytes))
        let store = Store(engine: Engine())
        let instance = try module.instantiate(store: store)
        let allocate = try #require(instance.exports[function: "pomodorough_alloc"])
        let free = try #require(instance.exports[function: "pomodorough_free_v2"])
        let allocation = try allocate([.i32(8)])
        guard allocation.count == 1, case .i32(let pointer) = allocation[0] else {
            Issue.record("allocator did not return one i32")
            return
        }

        #expect(try freeStatus(free, pointer: pointer, length: 7) == 0)
        #expect(try freeStatus(free, pointer: pointer, length: 8) == 1)
        #expect(try freeStatus(free, pointer: pointer, length: 8) == 0)
        #expect(try freeStatus(free, pointer: 0, length: 8) == 0)
    }

    @Test func selectedTaskClassifyPreservesOmissionNullAndValue() throws {
        let core = try SharedCore.bundled()

        let omitted = try core.dispatch(
            "selectedTask.classify",
            inputJSON: Data(#"{}"#.utf8),
            as: String.self
        )
        let deselected = try core.dispatch(
            "selectedTask.classify",
            inputJSON: Data(#"{"selectedTaskId":null}"#.utf8),
            as: String.self
        )
        let selected = try core.dispatch(
            "selectedTask.classify",
            inputJSON: Data(#"{"selectedTaskId":"33f9d32c-a7ee-8aa9-897a-13e19bc4e5d4"}"#.utf8),
            as: String.self
        )

        #expect(omitted == "omitted")
        #expect(deselected == "deselected")
        #expect(selected == "selected:33f9d32c-a7ee-8aa9-897a-13e19bc4e5d4")
    }

    @Test func rejectsEmptyOperationAndInputBeforeEnteringTheABI() throws {
        let core = try SharedCore.bundled()

        #expect(throws: SharedCoreError.self) {
            let _: CoreVersion = try core.dispatch(
                "",
                inputJSON: Data("{}".utf8),
                as: CoreVersion.self
            )
        }
        #expect(throws: SharedCoreError.self) {
            let _: CoreVersion = try core.dispatch(
                "core.version",
                inputJSON: Data(),
                as: CoreVersion.self
            )
        }
    }

    @Test func rejectsModuleWhoseDigestDoesNotMatchThePinnedArtifact() throws {
        let source = try SharedCore.bundledModuleURL()
        var bytes = try Data(contentsOf: source)
        bytes[bytes.index(before: bytes.endIndex)] ^= 1
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wasm")
        try bytes.write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }

        let core = SharedCore(moduleURL: target)
        #expect(throws: SharedCoreError.self) {
            let _: CoreVersion = try core.dispatch(
                "core.version",
                inputJSON: Data("{}".utf8),
                as: CoreVersion.self
            )
        }
    }

    @Test func completionValidationAcceptsFutureValidCorePolicy() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let input = CoreCompletionPlanInput.finishApplied(.init(
            source: .init(
                commandId: "finish-future",
                timerId: "timer-future",
                phase: .focus,
                occurredAt: date
            ),
            history: [],
            autoStartBreaks: true,
            localDeviceId: "device-local",
            ownership: .init(
                timerId: "timer-future",
                ownerDeviceId: "device-local"
            ),
            dayStart: Calendar.current.startOfDay(for: date),
            dayEnd: Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: Calendar.current.startOfDay(for: date)
            )!
        ))
        let futurePolicy = CoreCompletionPlanOutput(
            expired: false,
            commandEligible: false,
            reserveGeneratedBreak: false,
            selectedPhase: .longBreak,
            queueAutoBreak: true,
            generatedBreakEligible: false,
            generatedBreakPhase: nil,
            sourceAlreadyAccepted: false
        )

        #expect(try futurePolicy.validated(for: input) == futurePolicy)
    }

    @Test func completionValidationRejectsContradictoryCoreOutput() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let input = CoreCompletionPlanInput.finishApplied(.init(
            source: .init(
                commandId: "finish-invalid",
                timerId: "timer-invalid",
                phase: .focus,
                occurredAt: date
            ),
            history: [],
            autoStartBreaks: false,
            localDeviceId: "device-local",
            ownership: nil,
            dayStart: date,
            dayEnd: date.addingTimeInterval(86_400)
        ))
        let contradictory = CoreCompletionPlanOutput(
            expired: true,
            commandEligible: false,
            reserveGeneratedBreak: false,
            selectedPhase: .shortBreak,
            queueAutoBreak: false,
            generatedBreakEligible: false,
            generatedBreakPhase: nil,
            sourceAlreadyAccepted: false
        )

        #expect(throws: SharedCoreError.self) {
            try contradictory.validated(for: input)
        }
    }

    @Test func completionValidationRejectsEligibleGeneratedBreakWithoutPhase() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let input = CoreCompletionPlanInput.generatedBreak(.init(
            source: .init(commandId: "finish-invalid", timerId: "timer-invalid"),
            canonical: .init(canonicalTimer: nil, history: []),
            optimistic: .init(canonicalTimer: nil, history: []),
            sourceFinishPending: true,
            requireCanonical: false,
            dayStart: date,
            dayEnd: date.addingTimeInterval(86_400)
        ))
        let contradictory = CoreCompletionPlanOutput(
            expired: false,
            commandEligible: false,
            reserveGeneratedBreak: false,
            selectedPhase: nil,
            queueAutoBreak: false,
            generatedBreakEligible: true,
            generatedBreakPhase: nil,
            sourceAlreadyAccepted: false
        )

        #expect(throws: SharedCoreError.self) {
            try contradictory.validated(for: input)
        }
    }

    @Test func completionValidationRejectsEligibleGeneratedBreakWithoutExactSourceEvidence() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let input = CoreCompletionPlanInput.generatedBreak(.init(
            source: .init(commandId: "finish-invalid", timerId: "timer-invalid"),
            canonical: .init(canonicalTimer: nil, history: []),
            optimistic: .init(canonicalTimer: nil, history: []),
            sourceFinishPending: true,
            requireCanonical: false,
            dayStart: date,
            dayEnd: date.addingTimeInterval(86_400)
        ))
        let contradictory = CoreCompletionPlanOutput(
            expired: false,
            commandEligible: false,
            reserveGeneratedBreak: false,
            selectedPhase: nil,
            queueAutoBreak: false,
            generatedBreakEligible: true,
            generatedBreakPhase: .shortBreak,
            sourceAlreadyAccepted: false
        )

        #expect(throws: SharedCoreError.self) {
            try contradictory.validated(for: input)
        }
    }

    @Test func completionValidationAcceptsExactGeneratedBreakEvidence() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let timer = CanonicalTimer(
            id: "timer-valid",
            taskId: nil,
            phase: .focus,
            status: .completed,
            plannedDurationMs: 1_500_000,
            elapsedAtAnchorMs: 1_500_000,
            anchorAt: date,
            lastIntent: nil
        )
        let history = HistoryItem(
            id: "history-valid",
            timerId: timer.id,
            commandId: "finish-valid",
            taskId: nil,
            phase: .focus,
            status: "completed",
            plannedDurationMs: 1_500_000,
            completedAt: date,
            endedAt: date
        )
        let projection = CoreCompletionProjection(canonicalTimer: timer, history: [history])
        let input = CoreCompletionPlanInput.generatedBreak(.init(
            source: .init(commandId: "finish-valid", timerId: timer.id),
            canonical: projection,
            optimistic: projection,
            sourceFinishPending: false,
            requireCanonical: true,
            dayStart: date,
            dayEnd: date.addingTimeInterval(86_400)
        ))
        let output = CoreCompletionPlanOutput(
            expired: false,
            commandEligible: false,
            reserveGeneratedBreak: false,
            selectedPhase: nil,
            queueAutoBreak: false,
            generatedBreakEligible: true,
            generatedBreakPhase: .shortBreak,
            sourceAlreadyAccepted: true
        )

        #expect(try output.validated(for: input) == output)
    }

    @Test func hlcTickAcceptsFutureCounterAndRejectsRollbackBeforeMutation() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        var accepted = PersistedTimerState.fresh()

        try accepted.advanceClock(at: date, tickingWith: { input in
            #expect(input.remote == nil)
            #expect(input.physicalNowMs == 1_000_000)
            return CoreHLCTickOutput(wallMs: 1_000_000, counter: 40)
        })

        #expect(accepted.hlcWallMs == 1_000_000)
        #expect(accepted.hlcCounter == 40)

        var rejected = PersistedTimerState.fresh()
        let before = try JSONEncoder.api.encode(rejected)
        #expect(throws: AppError.invalidLocalClock) {
            try rejected.advanceClock(at: date, tickingWith: { _ in
                CoreHLCTickOutput(wallMs: 999_999, counter: 80)
            })
        }
        #expect(try JSONEncoder.api.encode(rejected) == before)
    }
}

private func freeStatus(_ free: Function, pointer: UInt32, length: UInt32) throws -> UInt32 {
    let results = try free([.i32(pointer), .i32(length)])
    guard results.count == 1, case .i32(let status) = results[0] else {
        throw SharedCoreError.invalidABIResult("pomodorough_free_v2 must return one i32")
    }
    return status
}
