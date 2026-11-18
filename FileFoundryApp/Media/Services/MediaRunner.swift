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
    /// Path components, symlinks resolved, lowercased (APFS is case-insensitive by default).
    private static func components(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
    }

    /// The output as it will land on disk: its parent directory resolved, so a symlinked parent can't hide the target.
    private static func resolvedOutput(_ output: URL) -> [String] {
        components(output.deletingLastPathComponent()) + [output.lastPathComponent.lowercased()]
    }

    /// Refuses output == input, a ZIP written inside the folder it archives, and symlinked output directories.
    /// An existing destination is not an error: publishing picks the next free name.
    static func validate(input: URL, output: URL) throws {
        let inComps = components(input)
        let outComps = resolvedOutput(output)
        if outComps == inComps {
            throw ToolError.invalid("The output must be a different file from the input.")
        }
        let dir = output.deletingLastPathComponent().standardizedFileURL
        if let values = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ToolError.invalid("Choose an output folder that is not a symbolic link.")
        }
        let isFolder = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isFolder, outComps.count > inComps.count, Array(outComps.prefix(inComps.count)) == inComps {
            throw ToolError.invalid("The output can't be saved inside the folder being archived.")
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

enum OutputPublisher {
    /// Moves `staged` to `destination`. `moveItem` fails instead of replacing, so a file that appeared in the meantime
    /// is never touched: the next free name ("… 2", "… 3") is tried instead. Bounded. Returns the final URL.
    static func publish(staged: URL, to destination: URL, maxAttempts: Int = 200) throws -> URL {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        var candidate = destination
        for n in 2...(maxAttempts + 1) {
            do {
                try fm.moveItem(at: staged, to: candidate)
                return candidate
            } catch {
                guard destinationTaken(candidate, error: error) else { throw error }
                let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                candidate = dir.appendingPathComponent(name)
            }
        }
        throw ToolError.failed("Couldn't find a free file name for the result.")
    }

    private static func destinationTaken(_ url: URL, error: Error) -> Bool {
        if (error as NSError).code == NSFileWriteFileExistsError { return true }
        // attributesOfItem does not follow symlinks, so a dangling link counts as taken too.
        return (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}

/// The single runner for every job: compress, convert and ZIP all execute a `CompressionPlan`.
enum MediaRunner {
    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Total bytes of a file, or of every file inside a folder. Blocking: call off the main actor.
    static func measure(_ url: URL) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(url) }
        var total = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let item as URL in e { total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        }
        return total
    }

    /// Where every tool writes: inside the job's private temp dir. `plan` must be built with this as its output.
    static func stagedURL(tempDir: URL, ext: String) -> URL {
        tempDir.appendingPathComponent(ext.isEmpty ? "output" : "output.\(ext)")
    }

    /// Executes the plan, which writes to `stagedURL(tempDir:ext:)`, then publishes with `moveItem` (never replacing).
    /// Always removes `tempDir`; on failure or cancel only the staged file goes, nothing in the user's folder.
    static func run(
        plan: CompressionPlan, originalBytes: Int, input: URL, output: URL, tempDir: URL,
        handle: ProcessHandle, progress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> CompressionResult {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try OutputSafety.validate(input: input, output: output)
        let staged = stagedURL(tempDir: tempDir, ext: plan.outputExtension)
        do {
            if plan.usesZip {
                try await zip(input: input, output: staged, handle: handle, progress: progress)
            } else if plan.imageTargetBytes != nil {
                try await searchImage(plan: plan, input: input, output: staged, tempDir: tempDir, handle: handle, progress: progress)
            } else {
                var done = 0.0
                for step in plan.steps {
                    let base = done
                    progress(ProgressUpdate(fraction: base, label: step.label))
                    switch step.tool {
                    case .ffmpeg:
                        try await FFmpegRunner.run(arguments: step.arguments, duration: plan.duration, handle: handle) { f in
                            progress(ProgressUpdate(fraction: base + step.weight * f, label: step.label))
                        }
                    case .sips:
                        try await runTool(URL(fileURLWithPath: "/usr/bin/sips"), step.arguments, handle: handle, name: "sips")
                    }
                    done += step.weight
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        let newBytes = fileSize(staged)
        let published = try OutputPublisher.publish(staged: staged, to: output)
        return CompressionResult(outputURL: published, originalBytes: originalBytes, newBytes: newBytes, targetBytes: plan.targetBytes)
    }

    private static func runTool(_ executable: URL, _ arguments: [String], handle: ProcessHandle, name: String) async throws {
        let outcome = try await ProcessRunner.run(executable, arguments, handle: handle)
        if outcome.cancelled { throw CancellationError() }
        guard outcome.succeeded else { throw ToolError.failed(outcome.stderrTail.isEmpty ? "\(name) failed." : outcome.stderrTail) }
    }

    private static func zip(input: URL, output: URL, handle: ProcessHandle, progress: @Sendable (ProgressUpdate) -> Void) async throws {
        progress(ProgressUpdate(fraction: nil, label: "Creating ZIP archive"))
        try await runTool(URL(fileURLWithPath: "/usr/bin/ditto"),
                          ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, output.path], handle: handle, name: "ditto")
    }

    /// Binary-searches quality with up to 6 encodes and keeps the best result under the target.
    private static func searchImage(
        plan: CompressionPlan, input: URL, output: URL, tempDir: URL,
        handle: ProcessHandle, progress: @Sendable (ProgressUpdate) -> Void
    ) async throws {
        guard let target = plan.imageTargetBytes, let settings = plan.imageSettings else { return }
        var lo = 5, hi = 95
        var best: (quality: Int, file: URL)?
        let attempts = 6
        for attempt in 0..<attempts where lo <= hi {
            let q = (lo + hi) / 2
            let temp = tempDir.appendingPathComponent("try-\(attempt).\(plan.outputExtension)")
            progress(ProgressUpdate(fraction: Double(attempt) / Double(attempts), label: "Trying quality \(q) (\(attempt + 1) of \(attempts))"))
            try await FFmpegRunner.run(
                arguments: CompressionPlanner.imageArguments(input: input, output: temp, settings: settings, quality: q),
                duration: nil, handle: handle) { _ in }
            if fileSize(temp) <= target { best = (q, temp); lo = q + 1 } else { hi = q - 1 }
        }
        guard let best else {
            throw ToolError.failed("Can't reach \(ByteFormat.string(target)) even at the lowest quality. Try a smaller maximum dimension.")
        }
        try FileManager.default.moveItem(at: best.file, to: output)
    }
}
