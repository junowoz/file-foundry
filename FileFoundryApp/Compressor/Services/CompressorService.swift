import Foundation

struct ProgressUpdate: Sendable {
    var fraction: Double?
    var label: String
}

struct CompressionResult: Equatable, Sendable {
    var outputURL: URL
    var originalBytes: Int
    var newBytes: Int
    var targetBytes: Int?

    var percentSmaller: Int {
        guard originalBytes > 0, newBytes < originalBytes else { return 0 }
        return Int((Double(originalBytes - newBytes) / Double(originalBytes) * 100).rounded())
    }
    var exceededTarget: Bool {
        guard let targetBytes else { return false }
        return Double(newBytes) > Double(targetBytes) * 1.02
    }
}

enum OutputSafety {
    /// Refuses output == input and symlinked output directories.
    static func validate(input: URL, output: URL) throws {
        let inPath = input.standardizedFileURL.resolvingSymlinksInPath().path
        let outPath = output.standardizedFileURL.path
        if outPath == inPath || output.standardizedFileURL.resolvingSymlinksInPath().path == inPath {
            throw ToolError.invalid("The output must be a different file from the input.")
        }
        let dir = output.deletingLastPathComponent().standardizedFileURL
        if let values = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ToolError.invalid("Choose an output folder that is not a symbolic link.")
        }
        if FileManager.default.fileExists(atPath: output.path) {
            throw ToolError.invalid("A file already exists at the chosen output path.")
        }
    }
}

enum PrivateTemp {
    /// A fresh private (0700) directory in the user's temp area.
    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileFoundry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }
}

enum CompressorService {
    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Executes the plan. `plan.steps` carry the pass log path chosen by the caller inside `tempDir`.
    static func run(
        plan: CompressionPlan, request: CompressionRequest, input: URL, output: URL, tempDir: URL,
        handle: ProcessHandle, progress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> CompressionResult {
        try OutputSafety.validate(input: input, output: output)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        do {
            switch plan.kind {
            case .other: try await zip(input: input, output: output, handle: handle, progress: progress)
            case .image where plan.imageTargetBytes != nil:
                try await searchImage(plan: plan, request: request, input: input, output: output, tempDir: tempDir, handle: handle, progress: progress)
            default:
                var done = 0.0
                for step in plan.steps {
                    let base = done
                    progress(ProgressUpdate(fraction: base, label: step.label))
                    try await FFmpegRunner.run(arguments: step.arguments, duration: request.info.duration > 0 ? request.info.duration : nil, handle: handle) { f in
                        progress(ProgressUpdate(fraction: base + step.weight * f, label: step.label))
                    }
                    done += step.weight
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return CompressionResult(outputURL: output, originalBytes: request.originalBytes, newBytes: fileSize(output), targetBytes: plan.targetBytes)
    }

    private static func zip(input: URL, output: URL, handle: ProcessHandle, progress: @Sendable (ProgressUpdate) -> Void) async throws {
        progress(ProgressUpdate(fraction: nil, label: "Creating ZIP archive"))
        let outcome = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, output.path], handle: handle)
        if outcome.cancelled { throw CancellationError() }
        guard outcome.succeeded else { throw ToolError.failed(outcome.stderrTail.isEmpty ? "ditto failed." : outcome.stderrTail) }
    }

    /// Binary-searches quality with up to 6 encodes and keeps the best result under the target.
    private static func searchImage(
        plan: CompressionPlan, request: CompressionRequest, input: URL, output: URL, tempDir: URL,
        handle: ProcessHandle, progress: @Sendable (ProgressUpdate) -> Void
    ) async throws {
        guard let target = plan.imageTargetBytes else { return }
        var lo = 5, hi = 95
        var best: (quality: Int, file: URL)?
        let attempts = 6
        for attempt in 0..<attempts where lo <= hi {
            let q = (lo + hi) / 2
            let temp = tempDir.appendingPathComponent("try-\(attempt).\(plan.outputExtension)")
            progress(ProgressUpdate(fraction: Double(attempt) / Double(attempts), label: "Trying quality \(q) (\(attempt + 1) of \(attempts))"))
            try await FFmpegRunner.run(
                arguments: CompressionPlanner.imageArguments(input: input, output: temp, settings: request.image, quality: q),
                duration: nil, handle: handle) { _ in }
            if fileSize(temp) <= target { best = (q, temp); lo = q + 1 } else { hi = q - 1 }
        }
        guard let best else {
            throw ToolError.failed("Can't reach \(ByteFormat.string(target)) even at the lowest quality. Try a smaller maximum dimension.")
        }
        try FileManager.default.moveItem(at: best.file, to: output)
    }
}
