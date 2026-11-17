import Foundation

/// Thread-safe handle used to cancel a running child process.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Returns false when cancel() already happened; the caller must terminate the process.
    func attach(_ process: Process) -> Bool {
        lock.withLock {
            if cancelled { return false }
            self.process = process
            return true
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }
}

final class LineTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
    }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

struct ProcessOutcome: Sendable {
    var status: Int32
    var cancelled: Bool
    var stderrTail: String
    var succeeded: Bool { status == 0 && !cancelled }
}

enum ToolError: LocalizedError {
    case toolMissing(String)
    case failed(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name): "\(name) was not found. Install it with Homebrew: brew install ffmpeg"
        case .failed(let message), .invalid(let message): message
        }
    }
}

/// Runs an executable directly (never through a shell). Arguments are passed as an array.
enum ProcessRunner {
    static func run(
        _ executable: URL,
        _ arguments: [String],
        handle: ProcessHandle = ProcessHandle(),
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        let tail = LineTail(limit: 14)

        // Both pipes are drained continuously so a chatty child can never fill a pipe buffer and stall.
        let outReader = Task.detached {
            do { for try await line in outHandle.bytes.lines { onStdoutLine?(line) } } catch {}
        }
        let errReader = Task.detached {
            do { for try await line in errHandle.bytes.lines { tail.append(line) } } catch {}
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if !handle.attach(process) { process.terminate() }
            }
        } onCancel: {
            handle.cancel()
        }
        await outReader.value
        await errReader.value
        return ProcessOutcome(status: status, cancelled: handle.isCancelled, stderrTail: tail.text)
    }
}

enum FFmpegProgress {
    /// Parses `out_time_us=` / `out_time_ms=` lines (both are microseconds in ffmpeg) into seconds.
    static func seconds(from line: String) -> Double? {
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            guard let value = Double(line.dropFirst(key.count)), value >= 0 else { return nil }
            return value / 1_000_000
        }
        return nil
    }

    static func fraction(from line: String, duration: Double?) -> Double? {
        guard let duration, duration > 0, let seconds = seconds(from: line) else { return nil }
        return min(max(seconds / duration, 0), 1)
    }
}

enum FFmpegRunner {
    static let baseArguments = ["-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]

    /// Runs ffmpeg with progress reporting. `arguments` should start with `baseArguments`.
    static func run(
        arguments: [String],
        duration: Double?,
        handle: ProcessHandle,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let ffmpeg = ToolLocator.locate("ffmpeg") else { throw ToolError.toolMissing("FFmpeg") }
        let outcome = try await ProcessRunner.run(ffmpeg, arguments, handle: handle) { line in
            if let fraction = FFmpegProgress.fraction(from: line, duration: duration) { onFraction(fraction) }
        }
        if outcome.cancelled { throw CancellationError() }
        guard outcome.succeeded else {
            let detail = outcome.stderrTail.isEmpty ? "FFmpeg exited with code \(outcome.status)." : outcome.stderrTail
            throw ToolError.failed(detail)
        }
    }
}
