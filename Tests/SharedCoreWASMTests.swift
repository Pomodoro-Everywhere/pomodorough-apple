import Foundation
import Testing
@testable import Pomodorough

@Suite("Shared core WebAssembly ABI")
struct SharedCoreWASMTests {
    private struct CoreVersion: Decodable, Equatable, Sendable {
        let schemaVersion: Int
        let coreVersion: String
    }

    private struct HLCHead: Decodable, Equatable, Sendable {
        let wallMs: Int64
        let counter: Int64
    }

    @Test func coreVersionDispatchesThroughBundledWebAssembly() async throws {
        let core = try SharedCore.bundled()

        let version = try await core.dispatch(
            "core.version",
            inputJSON: Data("{}".utf8),
            as: CoreVersion.self
        )

        #expect(version == CoreVersion(schemaVersion: 1, coreVersion: "0.1.5"))
    }

    @Test func hlcHeadDispatchesThroughBundledWebAssembly() async throws {
        let core = try SharedCore.bundled()
        let input = Data(
            #"{"physicalNowMs":100,"observed":[{"wallMs":101,"counter":2},{"wallMs":101,"counter":7},{"wallMs":99,"counter":99}]}"#.utf8
        )

        let head = try await core.dispatch(
            "hlc.head.v1",
            inputJSON: input,
            as: HLCHead.self
        )

        #expect(head == HLCHead(wallMs: 101, counter: 7))
    }

    @Test func selectedTaskClassifyPreservesOmissionNullAndValue() async throws {
        let core = try SharedCore.bundled()

        let omitted = try await core.dispatch(
            "selectedTask.classify",
            inputJSON: Data(#"{}"#.utf8),
            as: String.self
        )
        let deselected = try await core.dispatch(
            "selectedTask.classify",
            inputJSON: Data(#"{"selectedTaskId":null}"#.utf8),
            as: String.self
        )
        let selected = try await core.dispatch(
            "selectedTask.classify",
            inputJSON: Data(#"{"selectedTaskId":"33f9d32c-a7ee-8aa9-897a-13e19bc4e5d4"}"#.utf8),
            as: String.self
        )

        #expect(omitted == "omitted")
        #expect(deselected == "deselected")
        #expect(selected == "selected:33f9d32c-a7ee-8aa9-897a-13e19bc4e5d4")
    }

    @Test func rejectsEmptyOperationAndInputBeforeEnteringTheABI() async throws {
        let core = try SharedCore.bundled()

        await #expect(throws: SharedCoreError.self) {
            let _: CoreVersion = try await core.dispatch(
                "",
                inputJSON: Data("{}".utf8),
                as: CoreVersion.self
            )
        }
        await #expect(throws: SharedCoreError.self) {
            let _: CoreVersion = try await core.dispatch(
                "core.version",
                inputJSON: Data(),
                as: CoreVersion.self
            )
        }
    }

    @Test func rejectsModuleWhoseDigestDoesNotMatchThePinnedArtifact() async throws {
        let source = try SharedCore.bundledModuleURL()
        var bytes = try Data(contentsOf: source)
        bytes[bytes.index(before: bytes.endIndex)] ^= 1
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wasm")
        try bytes.write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }

        let core = SharedCore(moduleURL: target)
        await #expect(throws: SharedCoreError.self) {
            let _: CoreVersion = try await core.dispatch(
                "core.version",
                inputJSON: Data("{}".utf8),
                as: CoreVersion.self
            )
        }
    }
}
