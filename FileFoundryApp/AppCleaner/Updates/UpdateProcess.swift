import Foundation

enum UpdateProcessError: LocalizedError {
    case timedOut
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: "The command took too long and was stopped."
        case .launchFailed(let reason): "The command could not start. \(reason)"
        }
    }
}

struct UpdateProcessResult: Sendable {
    let status: Int32
    let stdout: Data
}

/// Runs one command from an argument array (never through a shell). Output streams to `onOutput`.
/// The process is terminated on timeout or when the calling task is cancelled.
enum UpdateProcess {
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> UpdateProcessResult {
        try Task.checkCancellation()
        let running = RunningProcess(executable: executable, arguments: arguments)
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                running.stop(timedOut: true)
            } catch {}
        }
        defer { timer.cancel() }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                running.start(onOutput: onOutput) { continuation.resume(with: $0) }
            }
        } onCancel: {
            running.stop(timedOut: false)
        }
        if Task.isCancelled { throw CancellationError() }
        return result
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var collected = Data()
    private var timedOut = false

    init(executable: URL, arguments: [String]) {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start(onOutput: (@Sendable (String) -> Void)?,
               completion: @escaping @Sendable (Result<UpdateProcessResult, Error>) -> Void) {
        attach(stdout, collects: true, onOutput: onOutput)
        attach(stderr, collects: false, onOutput: onOutput)
        process.terminationHandler = { [self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let rest = stdout.fileHandleForReading.readDataToEndOfFile()
            let (data, wasTimedOut) = lock.withLock { () -> (Data, Bool) in
                collected.append(rest)
                return (collected, timedOut)
            }
            if wasTimedOut {
                completion(.failure(UpdateProcessError.timedOut))
            } else {
                completion(.success(UpdateProcessResult(status: process.terminationStatus, stdout: data)))
            }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(UpdateProcessError.launchFailed(error.localizedDescription)))
        }
    }

    func stop(timedOut: Bool) {
        lock.withLock {
            if timedOut { self.timedOut = true }
        }
        guard process.isRunning else { return }
        process.terminate()
        // A process that ignores SIGTERM would leave the continuation waiting forever: escalate after 5 s.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func attach(_ pipe: Pipe, collects: Bool, onOutput: (@Sendable (String) -> Void)?) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if collects {
                lock.withLock { collected.append(data) }
            }
            onOutput?(String(decoding: data, as: UTF8.self))
        }
    }
}
