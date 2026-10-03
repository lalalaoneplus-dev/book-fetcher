import Foundation

struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let output: String
}

enum ProcessRunnerError: LocalizedError {
    case failedToLaunch(String)
    case nonZeroExit(executable: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .failedToLaunch(let message):
            return message
        case .nonZeroExit(let executable, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(executable) exited with status \(status)."
                : detail
        }
    }
}

struct ProcessRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        allowFailure: Bool = false
    ) throws -> ProcessResult {
        let fileManager = FileManager.default
        let logURL = fileManager.temporaryDirectory
            .appendingPathComponent("book-fetcher-\(UUID().uuidString).log")

        guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
            throw ProcessRunnerError.failedToLaunch("Could not create a process log file.")
        }

        defer { try? fileManager.removeItem(at: logURL) }

        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.failedToLaunch(
                "Could not launch \((executable as NSString).lastPathComponent): \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()
        try? logHandle.synchronize()

        let data = (try? Data(contentsOf: logURL)) ?? Data()
        let output = String(decoding: data, as: UTF8.self)
        let result = ProcessResult(
            terminationStatus: process.terminationStatus,
            output: output
        )

        if !allowFailure && result.terminationStatus != 0 {
            throw ProcessRunnerError.nonZeroExit(
                executable: (executable as NSString).lastPathComponent,
                status: result.terminationStatus,
                output: result.output
            )
        }

        return result
    }
}
