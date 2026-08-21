import CryptoKit
import Foundation
import WasmKit

enum SharedCoreError: Error, Equatable, LocalizedError, Sendable {
    case resourceMissing
    case runtimeInitializationFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case missingExport(String)
    case invalidExportSignature(String)
    case inputTooLarge(Int)
    case allocationFailed(length: Int)
    case memoryOutOfBounds(pointer: UInt32, length: UInt32, byteCount: Int)
    case invalidABIResult(String)
    case invalidInput(String)
    case core(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "Bundled pomodorough_core.wasm resource is missing."
        case .runtimeInitializationFailed(let message):
            "Shared core WebAssembly initialization failed: \(message)"
        case .checksumMismatch(let expected, let actual):
            "Shared core SHA-256 mismatch: expected \(expected), got \(actual)."
        case .missingExport(let name):
            "Shared core WebAssembly export is missing: \(name)."
        case .invalidExportSignature(let name):
            "Shared core WebAssembly export has an invalid signature: \(name)."
        case .inputTooLarge(let length):
            "Shared core input exceeds the 32-bit ABI length: \(length) bytes."
        case .allocationFailed(let length):
            "Shared core failed to allocate \(length) bytes."
        case .memoryOutOfBounds(let pointer, let length, let byteCount):
            "Shared core memory range \(pointer)..<\(UInt64(pointer) + UInt64(length)) exceeds \(byteCount) bytes."
        case .invalidABIResult(let message):
            "Shared core returned an invalid ABI result: \(message)"
        case .invalidInput(let message):
            "Shared core input is invalid: \(message)"
        case .core(let message):
            "Shared core rejected the operation: \(message)"
        case .invalidResponse(let message):
            "Shared core returned an invalid response: \(message)"
        }
    }
}

actor SharedCore {
    static let coreCommit = "9a01dc8da0f1612e7a301c19cf42f3b522e61684"
    static let coreSHA256 = "89fb6300324042b61d62070242cccad10e30f125885bb1b7a05af67b077bac83"
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

    private let moduleURL: URL
    private var runtime: Runtime?

    init(moduleURL: URL) {
        self.moduleURL = moduleURL
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
        let response = try invoke(operation: operation, inputJSON: inputJSON)
        let decoder = JSONDecoder()

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
            inputJSON = try JSONEncoder().encode(input)
        } catch {
            throw SharedCoreError.invalidInput("encoding failed: \(error)")
        }
        return try dispatch(operation, inputJSON: inputJSON, as: outputType)
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
        let operationLength = try abiLength(operationBytes.count)
        let inputLength = try abiLength(inputJSON.count)
        var operationPointer: UInt32 = 0
        var inputPointer: UInt32 = 0
        var resultPointer: UInt32 = 0
        var resultLength: UInt32 = 0

        do {
            operationPointer = try write(operationBytes, using: runtime)
            inputPointer = try write(inputJSON, using: runtime)
            let results: [Value]
            do {
                results = try runtime.dispatch([
                    .i32(operationPointer),
                    .i32(operationLength),
                    .i32(inputPointer),
                    .i32(inputLength),
                ])
            } catch {
                throw SharedCoreError.invalidABIResult(String(describing: error))
            }
            guard results.count == 1, case .i64(let packed) = results[0] else {
                throw SharedCoreError.invalidABIResult("pomodorough_dispatch must return one i64")
            }

            resultPointer = UInt32(truncatingIfNeeded: packed)
            resultLength = UInt32(truncatingIfNeeded: packed >> 32)
            guard resultPointer != 0, resultLength != 0 else {
                throw SharedCoreError.invalidABIResult("dispatch returned an empty result buffer")
            }
            guard resultLength <= UInt32(Self.maxTransferBytes) else {
                throw SharedCoreError.invalidABIResult("dispatch result exceeds the transfer limit")
            }
            try validate(pointer: resultPointer, length: resultLength, in: runtime.memory)
            let response = try read(pointer: resultPointer, length: resultLength, from: runtime.memory)
            try cleanup(pointer: &resultPointer, length: resultLength, using: runtime)
            try cleanup(pointer: &inputPointer, length: inputLength, using: runtime)
            try cleanup(pointer: &operationPointer, length: operationLength, using: runtime)
            return response
        } catch {
            let primary = error
            var cleanupFailures: [String] = []
            for cleanup in [
                { try self.cleanup(pointer: &resultPointer, length: resultLength, using: runtime) },
                { try self.cleanup(pointer: &inputPointer, length: inputLength, using: runtime) },
                { try self.cleanup(pointer: &operationPointer, length: operationLength, using: runtime) },
            ] {
                do {
                    try cleanup()
                } catch {
                    cleanupFailures.append(String(describing: error))
                }
            }
            guard cleanupFailures.isEmpty else {
                self.runtime = nil
                throw SharedCoreError.invalidABIResult(
                    "operation failed: \(primary); cleanup failed: \(cleanupFailures.joined(separator: "; "))"
                )
            }
            throw primary
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
            let free = try function(named: "pomodorough_free", in: instance)
            let dispatch = try function(named: "pomodorough_dispatch", in: instance)
            guard allocate.type.parameters == [.i32], allocate.type.results == [.i32] else {
                throw SharedCoreError.invalidExportSignature("pomodorough_alloc")
            }
            guard free.type.parameters == [.i32, .i32], free.type.results.isEmpty else {
                throw SharedCoreError.invalidExportSignature("pomodorough_free")
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
            guard results.isEmpty else {
                throw SharedCoreError.invalidABIResult("pomodorough_free must not return a value")
            }
        } catch let error as SharedCoreError {
            throw error
        } catch {
            throw SharedCoreError.invalidABIResult(String(describing: error))
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
