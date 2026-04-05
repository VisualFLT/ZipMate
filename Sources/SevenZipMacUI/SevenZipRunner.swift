import Foundation

private final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()

    func appendStdout(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        outData.append(chunk)
        lock.unlock()
    }

    func appendStderr(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        errData.append(chunk)
        lock.unlock()
    }

    func combinedOutput(appendTailOut: Data, appendTailErr: Data) -> String {
        lock.lock()
        outData.append(appendTailOut)
        errData.append(appendTailErr)
        let combined = String(decoding: outData + errData, as: UTF8.self)
        lock.unlock()
        return combined
    }
}

struct SevenZipRunner {
    static func runSilent(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            DebugLogger.log("runSilent() prepare executable=\(executablePath) args=\(arguments.joined(separator: " "))")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL

            // Fully silence child process output to avoid high-frequency callbacks
            // that can overwhelm the UI thread on large archives.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { finished in
                DebugLogger.log("runSilent() terminated exit=\(finished.terminationStatus)")
                continuation.resume(returning: finished.terminationStatus)
            }

            do {
                try process.run()
                DebugLogger.log("runSilent() process.run() succeeded pid=\(process.processIdentifier)")
            } catch {
                DebugLogger.log("runSilent() process.run() failed error=\(error.localizedDescription)")
                continuation.resume(returning: -1)
            }
        }
    }

    static func runCapture(
        executablePath: String,
        arguments: [String]
    ) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let capture = CaptureBuffer()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                capture.appendStdout(chunk)
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                capture.appendStderr(chunk)
            }

            process.terminationHandler = { finished in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                // Drain any remaining bytes after readability handlers are removed.
                let tailOut = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let tailErr = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let combined = capture.combinedOutput(appendTailOut: tailOut, appendTailErr: tailErr)
                continuation.resume(returning: (finished.terminationStatus, combined))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, "Failed to start 7zz process: \(error.localizedDescription)\n"))
            }
        }
    }

    static func run(
        executablePath: String,
        arguments: [String],
        onOutput: @escaping @Sendable @MainActor (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let emit: @Sendable (Data) -> Void = { data in
                guard !data.isEmpty else { return }
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    Task { @MainActor in
                        onOutput(text)
                    }
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                emit(handle.availableData)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                emit(handle.availableData)
            }

            process.terminationHandler = { finished in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: finished.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    onOutput("Failed to start 7zz process: \(error.localizedDescription)\n")
                }
                continuation.resume(returning: -1)
            }
        }
    }
}
