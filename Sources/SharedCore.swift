import CryptoKit
import Foundation
import WasmKit

final class SharedCore: @unchecked Sendable {
    static let coreCommit = "0d8603ddaa27f7cbafdeede8784c0a66b2ba959b"
    static let coreSHA256 = "8a9f7e5291bb6ddb09b1fe6d9f027ac9bf137814bfac1bf16a201bbb633cf235"
    private static let maxTransferBytes = 16 * 1024 * 1024

    private struct Runtime {
        let store: Store
        let memory: Memory
        let allocate: Function
        let free: Function
        let dispatch: Function
    }

    private struct EnvelopeHeader: Decodable {
        let ok: Bool
        let error: String?
    }

    private struct InvocationBuffers {
        var operationPointer: UInt32 = 0
        var inputPointer: UInt32 = 0
        var resultPointer: UInt32 = 0
        let operationLength: UInt32
        let inputLength: UInt32
        var resultLength: UInt32 = 0
    }

    private let moduleURL: URL
    private let freeResultValidator: @Sendable ([Value]) throws -> Void
    private let lock = NSRecursiveLock()
    private var runtime: Runtime?

    init(
        moduleURL: URL,
        freeResultValidator: @escaping @Sendable ([Value]) throws -> Void = SharedCore.validateFreeResult
    ) {
        self.moduleURL = moduleURL
        self.freeResultValidator = freeResultValidator
    }

    static func bundled(in bundle: Bundle = .main) throws -> SharedCore {
        SharedCore(moduleURL: try bundledModuleURL(in: bundle))
    }

    static func bundledModuleURL(in bundle: Bundle = .main) throws -> URL {
        let url = bundle.url(
            forResource: "pomodorough_core",
            withExtension: "wasm",
            subdirectory: "SharedCore"
        ) ?? bundle.url(forResource: "pomodorough_core", withExtension: "wasm")
        guard let url else {
            throw SharedCoreError.resourceMissing
        }
        return url
    }

    func dispatch<Output: Decodable & Sendable>(
        _ operation: String,
        inputJSON: Data,
        as outputType: Output.Type
    ) throws -> Output {
        lock.lock()
        defer { lock.unlock() }
        let response = try invoke(operation: operation, inputJSON: inputJSON)
        let decoder = JSONDecoder.api

        let header: EnvelopeHeader
        do {
            header = try decoder.decode(EnvelopeHeader.self, from: response)
        } catch {
            throw SharedCoreError.invalidResponse(String(describing: error))
        }
        guard header.ok else {
            throw SharedCoreError.core(header.error ?? "missing error message")
        }

        do {
            let object = try JSONSerialization.jsonObject(with: response, options: [.fragmentsAllowed])
            guard
                let envelope = object as? [String: Any],
                let value = envelope["value"]
            else {
                throw SharedCoreError.invalidResponse("successful envelope is missing value")
            }
            let valueJSON = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return try decoder.decode(outputType, from: valueJSON)
        } catch let error as SharedCoreError {
            throw error
        } catch {
            throw SharedCoreError.invalidResponse(String(describing: error))
        }
    }

    func dispatch<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ operation: String,
        input: Input,
        as outputType: Output.Type
    ) throws -> Output {
        let inputJSON: Data
        do {
            inputJSON = try JSONEncoder.sharedCore.encode(input)
        } catch {
            throw SharedCoreError.invalidInput("encoding failed: \(error)")
        }
        return try dispatch(operation, inputJSON: inputJSON, as: outputType)
    }

    func applyProjection(_ input: CoreProjectionInput) throws -> CoreProjectionOutput {
        let output: CoreProjectionOutput = try dispatch(
            "projection.apply.v2",
            input: input,
            as: CoreProjectionOutput.self
        )
        return try output.validated(for: input)
    }

    func completionPlan(_ input: CoreCompletionPlanInput) throws -> CoreCompletionPlanOutput {
        let output: CoreCompletionPlanOutput = try dispatch(
            "timer.completionPlan.v1",
            input: input,
            as: CoreCompletionPlanOutput.self
        )
        return try output.validated(for: input)
    }

    func tickHLC(_ input: CoreHLCTickInput) throws -> CoreHLCTickOutput {
        let output: CoreHLCTickOutput = try dispatch(
            "hlc.tick.v1",
            input: input,
            as: CoreHLCTickOutput.self
        )
        return try output.validated(for: input)
    }

    func headHLC(_ input: CoreHLCHeadInput) throws -> CoreHLC {
        let output: CoreHLC = try dispatch(
            "hlc.head.v1",
            input: input,
            as: CoreHLC.self
        )
        return try output.validatedHead(for: input)
    }

    func planBootstrap(_ input: CoreBootstrapPlanInput) throws -> CoreBootstrapPlanOutput {
        let output: CoreBootstrapPlanOutput = try dispatch(
            "bootstrap.plan.v1",
            input: input,
            as: CoreBootstrapPlanOutput.self
        )
        return try output.validated()
    }

    func reconcileRebase(_ input: CoreReconcileInput) throws -> CoreReconcileOutput {
        let output: CoreReconcileOutput = try dispatch(
            "reconcile.rebase.v1",
            input: input,
            as: CoreReconcileOutput.self
        )
        return try output.validated(for: input)
    }

    private func invoke(operation: String, inputJSON: Data) throws -> Data {
        let runtime = try loadedRuntime()
        let operationBytes = Data(operation.utf8)
        guard !operationBytes.isEmpty else {
            throw SharedCoreError.invalidInput("operation must not be empty")
        }
        guard !inputJSON.isEmpty else {
            throw SharedCoreError.invalidInput("input JSON must not be empty")
        }
        var buffers = InvocationBuffers(
            operationLength: try abiLength(operationBytes.count),
            inputLength: try abiLength(inputJSON.count)
        )
        do {
            buffers.operationPointer = try write(operationBytes, using: runtime)
            buffers.inputPointer = try write(inputJSON, using: runtime)
            let response = try dispatchAndRead(using: runtime, buffers: &buffers)
            try cleanupBuffers(&buffers, using: runtime)
            return response
        } catch {
            try recoverFromInvocationFailure(error, buffers: &buffers, runtime: runtime)
        }
    }

    private func dispatchAndRead(
        using runtime: Runtime,
        buffers: inout InvocationBuffers
    ) throws -> Data {
        let results: [Value]
        do {
            results = try runtime.dispatch([
                .i32(buffers.operationPointer),
                .i32(buffers.operationLength),
                .i32(buffers.inputPointer),
                .i32(buffers.inputLength),
            ])
        } catch {
            throw SharedCoreError.invalidABIResult(String(describing: error))
        }
        guard results.count == 1, case .i64(let packed) = results[0] else {
            throw SharedCoreError.invalidABIResult("pomodorough_dispatch must return one i64")
        }
        buffers.resultPointer = UInt32(truncatingIfNeeded: packed)
        buffers.resultLength = UInt32(truncatingIfNeeded: packed >> 32)
        guard buffers.resultPointer != 0, buffers.resultLength != 0 else {
            throw SharedCoreError.invalidABIResult("dispatch returned an empty result buffer")
        }
        guard buffers.resultLength <= UInt32(Self.maxTransferBytes) else {
            throw SharedCoreError.invalidABIResult("dispatch result exceeds the transfer limit")
        }
        try validate(
            pointer: buffers.resultPointer,
            length: buffers.resultLength,
            in: runtime.memory
        )
        return try read(
            pointer: buffers.resultPointer,
            length: buffers.resultLength,
            from: runtime.memory
        )
    }

    private func cleanupBuffers(_ buffers: inout InvocationBuffers, using runtime: Runtime) throws {
        try cleanup(pointer: &buffers.resultPointer, length: buffers.resultLength, using: runtime)
        try cleanup(pointer: &buffers.inputPointer, length: buffers.inputLength, using: runtime)
        try cleanup(pointer: &buffers.operationPointer, length: buffers.operationLength, using: runtime)
    }

    private func recoverFromInvocationFailure(
        _ primary: Error,
        buffers: inout InvocationBuffers,
        runtime: Runtime
    ) throws -> Never {
        let failures = [
            cleanupFailure(pointer: &buffers.resultPointer, length: buffers.resultLength, runtime: runtime),
            cleanupFailure(pointer: &buffers.inputPointer, length: buffers.inputLength, runtime: runtime),
            cleanupFailure(pointer: &buffers.operationPointer, length: buffers.operationLength, runtime: runtime),
        ].compactMap { $0 }
        guard failures.isEmpty else {
            self.runtime = nil
            throw SharedCoreError.invalidABIResult(
                "operation failed: \(primary); cleanup failed: \(failures.joined(separator: "; "))"
            )
        }
        throw primary
    }

    private func cleanupFailure(
        pointer: inout UInt32,
        length: UInt32,
        runtime: Runtime
    ) -> String? {
        do {
            try cleanup(pointer: &pointer, length: length, using: runtime)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func loadedRuntime() throws -> Runtime {
        if let runtime {
            return runtime
        }

        do {
            let moduleData = try Data(contentsOf: moduleURL, options: [.mappedIfSafe])
            let actualSHA256 = SHA256.hash(data: moduleData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualSHA256 == Self.coreSHA256 else {
                throw SharedCoreError.checksumMismatch(
                    expected: Self.coreSHA256,
                    actual: actualSHA256
                )
            }
            let module = try parseWasm(bytes: Array(moduleData))
            let store = Store(engine: Engine())
            let instance = try module.instantiate(store: store)
            guard let memory = instance.exports[memory: "memory"] else {
                throw SharedCoreError.missingExport("memory")
            }
            let allocate = try function(named: "pomodorough_alloc", in: instance)
            let free = try function(named: "pomodorough_free_v2", in: instance)
            let dispatch = try function(named: "pomodorough_dispatch", in: instance)
            guard allocate.type.parameters == [.i32], allocate.type.results == [.i32] else {
                throw SharedCoreError.invalidExportSignature("pomodorough_alloc")
            }
            guard free.type.parameters == [.i32, .i32], free.type.results == [.i32] else {
                throw SharedCoreError.invalidExportSignature("pomodorough_free_v2")
            }
            guard dispatch.type.parameters == [.i32, .i32, .i32, .i32], dispatch.type.results == [.i64] else {
                throw SharedCoreError.invalidExportSignature("pomodorough_dispatch")
            }

            let loaded = Runtime(
                store: store,
                memory: memory,
                allocate: allocate,
                free: free,
                dispatch: dispatch
            )
            runtime = loaded
            return loaded
        } catch let error as SharedCoreError {
            throw error
        } catch {
            throw SharedCoreError.runtimeInitializationFailed(String(describing: error))
        }
    }

    private func function(named name: String, in instance: Instance) throws -> Function {
        guard let function = instance.exports[function: name] else {
            throw SharedCoreError.missingExport(name)
        }
        return function
    }

    private func abiLength(_ length: Int) throws -> UInt32 {
        guard length <= Self.maxTransferBytes, let length = UInt32(exactly: length) else {
            throw SharedCoreError.inputTooLarge(length)
        }
        return length
    }

    private func write(_ data: Data, using runtime: Runtime) throws -> UInt32 {
        guard !data.isEmpty else {
            return 0
        }
        let length = try abiLength(data.count)
        let results: [Value]
        do {
            results = try runtime.allocate([.i32(length)])
        } catch {
            throw SharedCoreError.invalidABIResult(String(describing: error))
        }
        guard results.count == 1, case .i32(let pointer) = results[0] else {
            throw SharedCoreError.invalidABIResult("pomodorough_alloc must return one i32")
        }
        guard pointer != 0 else {
            throw SharedCoreError.allocationFailed(length: data.count)
        }
        do {
            try validate(pointer: pointer, length: length, in: runtime.memory)
            runtime.memory.withUnsafeMutableBufferPointer(offset: UInt(pointer), count: data.count) { destination in
                data.withUnsafeBytes { source in
                    destination.copyMemory(from: source)
                }
            }
        } catch {
            let primary = error
            do {
                try release(pointer, length: length, using: runtime)
            } catch {
                self.runtime = nil
                throw SharedCoreError.invalidABIResult(
                    "input write failed: \(primary); cleanup failed: \(error)"
                )
            }
            throw primary
        }
        return pointer
    }

    private func read(pointer: UInt32, length: UInt32, from memory: Memory) throws -> Data {
        try validate(pointer: pointer, length: length, in: memory)
        return memory.withUnsafeBufferPointer(offset: UInt(pointer), count: Int(length)) { buffer in
            Data(buffer)
        }
    }

    private func cleanup(pointer: inout UInt32, length: UInt32, using runtime: Runtime) throws {
        guard pointer != 0, length != 0 else {
            pointer = 0
            return
        }
        let ownedPointer = pointer
        pointer = 0
        do {
            try release(ownedPointer, length: length, using: runtime)
        } catch {
            self.runtime = nil
            throw error
        }
    }

    private func release(_ pointer: UInt32, length: UInt32, using runtime: Runtime) throws {
        guard pointer != 0, length != 0 else {
            return
        }
        do {
            let results = try runtime.free([.i32(pointer), .i32(length)])
            try freeResultValidator(results)
        } catch let error as SharedCoreError {
            throw error
        } catch {
            throw SharedCoreError.invalidABIResult(String(describing: error))
        }
    }

    private static func validateFreeResult(_ results: [Value]) throws {
        guard results.count == 1, case .i32(let status) = results[0], status == 1 else {
            throw SharedCoreError.invalidABIResult(
                "pomodorough_free_v2 rejected buffer with result \(results)"
            )
        }
    }

    private func validate(pointer: UInt32, length: UInt32, in memory: Memory) throws {
        let start = UInt64(pointer)
        let count = UInt64(length)
        let byteCount = UInt64(memory.byteCount)
        guard start <= byteCount, count <= byteCount - start else {
            throw SharedCoreError.memoryOutOfBounds(
                pointer: pointer,
                length: length,
                byteCount: memory.byteCount
            )
        }
    }
}

private extension JSONEncoder {
    static var sharedCore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(try sharedCoreTimestamp(for: date))
        }
        return encoder
    }
}

private func sharedCoreTimestamp(for date: Date) throws -> String {
    let seconds = date.timeIntervalSince1970
    let unroundedMilliseconds = seconds * 1_000
    guard seconds.isFinite,
          abs(unroundedMilliseconds) <= Double(WireBounds.maxSafeInteger) else {
        throw EncodingError.invalidValue(
            date,
            .init(codingPath: [], debugDescription: "Shared Core date is out of range")
        )
    }
    let milliseconds = Int64(unroundedMilliseconds.rounded())
    let wholeSeconds = milliseconds >= 0
        ? milliseconds / 1_000
        : (milliseconds - 999) / 1_000
    let fraction = milliseconds - wholeSeconds * 1_000
    let paddedFraction = String(fraction).leftPadded(to: 3, with: "0")
    let wholeDate = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
    let prefix = wholeDate.formatted(Date.ISO8601FormatStyle()).dropLast()
    return "\(prefix).\(paddedFraction)Z"
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        String(repeating: character, count: max(0, length - count)) + self
    }
}
