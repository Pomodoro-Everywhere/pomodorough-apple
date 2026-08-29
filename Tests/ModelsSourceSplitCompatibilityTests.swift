import Foundation
import Testing
@testable import Pomodorough

@Suite("Models source split compatibility")
struct ModelsSourceSplitCompatibilityTests {
    @Test
    func remainingModelSymbolsStayAvailableAcrossSourceMoves() {
        let symbols: [Any.Type] = [
            WireBounds.self, UUIDv7.self, UUIDv7.Parts.self,
            SSERevisionParser.self, RevisionHintCoalescer.self,
            RevisionStreamLifecycle.self, SessionVerification.self,
            SyncOwnership.self, RemotePolling.self, RevisionStreamResponse.self,
            CommandType.self, TimerCommand.self,
            SyncRequest.self, BootstrapResolutionStrategy.self, BootstrapResolveRequest.self,
            EmptyStringIfMissing.self, Acknowledgement.self,
            TaskOperationType.self, TaskOperation.self, TaskAcknowledgement.self,
            DurationOperation.self, DurationAcknowledgement.self,
            AutoStartOperation.self, AcknowledgementOutcome.self, AutoStartAcknowledgement.self,
            SelectedTaskOperation.self, SelectedTaskAcknowledgement.self,
            ProvisionalBreak.self, ProvisionalPhaseAdvance.self, AcknowledgementSet.self,
            TimerIntent.self, CanonicalTimer.self, CanonicalTimer.Status.self,
            HistoryItem.self, FocusTask.self, LocalTaskState.self,
            TaskDailySummary.self, CompletedFocusSummary.self, HistoryAnalytics.self,
            SyncResponse.self, BootstrapResponse.self,
            CanonicalSnapshotValidation.self, HistoryResponse.self,
            PersistedTimerState.self, AppError.self
        ]

        #expect(symbols.count == 45)
    }

    @Test
    func synchronizationWireModelsKeepExactBytesAndMissingDefaults() throws {
        let sync = SyncRequest(
            deviceId: "device-fixed",
            lastRevision: 7,
            commands: [],
            taskOperations: [],
            durationOperations: [],
            autoStartOperations: nil
        )
        #expect(try JSONEncoder.api.encode(sync) == Data(
            #"{"commands":[],"deviceId":"device-fixed","durationOperations":[],"lastRevision":7,"selectedTaskOperations":[],"taskOperations":[]}"#.utf8
        ))

        let bootstrap = BootstrapResolveRequest(
            requestId: "request-fixed",
            deviceId: "device-fixed",
            expectedRevision: 7,
            strategy: .keepRemote,
            commands: [],
            taskOperations: [],
            durationOperations: [],
            autoStartOperations: nil
        )
        #expect(try JSONEncoder.api.encode(bootstrap) == Data(
            #"{"commands":[],"deviceId":"device-fixed","durationOperations":[],"expectedRevision":7,"requestId":"request-fixed","strategy":"keep_remote","taskOperations":[]}"#.utf8
        ))

        let missingReason = try JSONDecoder.api.decode(
            Acknowledgement.self,
            from: Data(#"{"commandId":"command-fixed","outcome":"applied"}"#.utf8)
        )
        #expect(missingReason.reason == "")
        #expect(try JSONEncoder.api.encode(missingReason) == Data(
            #"{"commandId":"command-fixed","outcome":"applied","reason":{"wrappedValue":""}}"#.utf8
        ))
        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(
                Acknowledgement.self,
                from: Data(#"{"commandId":"command-fixed","outcome":"applied","reason":null}"#.utf8)
            )
        }
    }
}
