import Foundation

public final class DuplicateDetectionService: @unchecked Sendable {
    private let scanner: FileScannerService
    private let hashService: HashService
    private let byteCompareService: ByteCompareService
    private let recommendationService: RecommendationService

    public init(
        scanner: FileScannerService = FileScannerService(),
        hashService: HashService = HashService(),
        byteCompareService: ByteCompareService = ByteCompareService(),
        recommendationService: RecommendationService = RecommendationService()
    ) {
        self.scanner = scanner
        self.hashService = hashService
        self.byteCompareService = byteCompareService
        self.recommendationService = recommendationService
    }

    public func scan(folders: [URL], options: ScanOptions) async throws -> ScanResult {
        let indexed = try await scanner.scan(folders: folders, options: options)
        var skipped = indexed.skippedFiles
        var groups: [DuplicateGroup] = []

        if options.matchMode == .metadata {
            groups = metadataGroups(for: indexed.files, criteria: options.metadataCriteria)
        } else {
            let filesBySize = Dictionary(grouping: indexed.files, by: \.size)
                .filter { $0.value.count > 1 }

            for (_, sameSizeFiles) in filesBySize {
                try Task.checkCancellation()
                let partialCandidates = try partialHashGroups(for: sameSizeFiles, options: options, skipped: &skipped)

                for candidateFiles in partialCandidates {
                    try Task.checkCancellation()
                    let shaGroups = try shaGroups(for: candidateFiles, skipped: &skipped)

                    for (sha, shaFiles) in shaGroups where shaFiles.count > 1 {
                        try Task.checkCancellation()
                        if options.compareMode == .fast {
                            groups.append(group(files: shaFiles, sha256: sha, level: .sha256Match, options: options))
                        } else {
                            let clusters = try byteConfirmedClusters(shaFiles)
                            for cluster in clusters where cluster.count > 1 {
                                groups.append(group(files: cluster, sha256: sha, level: .byteByByteConfirmed, options: options))
                            }
                        }
                    }
                }
            }
        }

        groups = apply(scope: options.searchScope, to: groups, options: options)

        return ScanResult(
            selectedFolders: folders,
            options: options,
            scannedFiles: indexed.files,
            skippedFiles: skipped,
            duplicateGroups: groups.sorted {
                if $0.totalLogicalWastedBytes != $1.totalLogicalWastedBytes {
                    return $0.totalLogicalWastedBytes > $1.totalLogicalWastedBytes
                }
                return $0.files.count > $1.files.count
            }
        )
    }

    private func metadataGroups(for files: [ScannedFile], criteria: MetadataMatchCriteria) -> [DuplicateGroup] {
        guard criteria.hasSelection else { return [] }

        let candidates = files.compactMap { file -> (MetadataKey, ScannedFile)? in
            let duration: Int?
            if criteria.duration {
                guard let seconds = file.mediaDurationSeconds else { return nil }
                duration = Int(seconds.rounded())
            } else {
                duration = nil
            }

            let filename = criteria.filename
                ? (file.filename as NSString).deletingPathExtension.normalizedForRecommendation
                : nil
            let fileExtension = criteria.fileExtension
                ? file.fileExtension.normalizedForRecommendation
                : nil
            let fileKind = criteria.fileKind ? file.fileKind.rawValue : nil
            return (
                MetadataKey(
                    filename: filename,
                    durationSeconds: duration,
                    fileKind: fileKind,
                    fileExtension: fileExtension
                ),
                file
            )
        }

        return Dictionary(grouping: candidates, by: \.0)
            .values
            .map { $0.map(\.1) }
            .filter { $0.count > 1 }
            .map { DuplicateGroup(files: $0, sha256: "", verificationLevel: .metadataMatch) }
    }

    private func apply(scope: SearchScope, to groups: [DuplicateGroup], options: ScanOptions) -> [DuplicateGroup] {
        switch scope {
        case .anywhere:
            return groups
        case .betweenFolders:
            return groups.filter { Set($0.files.map(\.sourceFolderPath)).count > 1 }
        case .withinFolders:
            return groups.flatMap { original in
                Dictionary(grouping: original.files, by: \.sourceFolderPath)
                    .values
                    .filter { $0.count > 1 }
                    .map { files in
                        if original.verificationLevel == .metadataMatch {
                            return DuplicateGroup(files: files, sha256: "", verificationLevel: .metadataMatch)
                        }
                        return group(
                            files: files,
                            sha256: original.sha256,
                            level: original.verificationLevel,
                            options: options
                        )
                    }
            }
        }
    }

    private func partialHashGroups(
        for files: [ScannedFile],
        options: ScanOptions,
        skipped: inout [ScannedFile]
    ) throws -> [[ScannedFile]] {
        if options.compareMode == .fast {
            return [files]
        }

        var hashedFiles: [ScannedFile] = []
        for file in files {
            do {
                hashedFiles.append(file.with(partialHash: try hashService.partialHash(for: file.url)))
            } catch {
                skipped.append(file.with(error: error.localizedDescription))
            }
        }

        return Dictionary(grouping: hashedFiles, by: \.partialHash)
            .values
            .filter { $0.count > 1 }
    }

    private func shaGroups(for files: [ScannedFile], skipped: inout [ScannedFile]) throws -> [String: [ScannedFile]] {
        var hashedFiles: [ScannedFile] = []
        for file in files {
            do {
                hashedFiles.append(file.with(sha256: try hashService.sha256(for: file.url)))
            } catch {
                skipped.append(file.with(error: error.localizedDescription))
            }
        }
        return Dictionary(grouping: hashedFiles) { $0.sha256 ?? "" }
            .filter { !$0.key.isEmpty }
    }

    private func byteConfirmedClusters(_ files: [ScannedFile]) throws -> [[ScannedFile]] {
        var clusters: [[ScannedFile]] = []

        fileLoop: for file in files {
            for index in clusters.indices {
                if try byteCompareService.contentsAreEqual(clusters[index][0].url, file.url) {
                    clusters[index].append(file)
                    continue fileLoop
                }
            }
            clusters.append([file])
        }

        return clusters.filter { $0.count > 1 }
    }

    private func group(files: [ScannedFile], sha256: String, level: VerificationLevel, options: ScanOptions) -> DuplicateGroup {
        let base = DuplicateGroup(files: files, sha256: sha256, verificationLevel: level)
        let recommendation = recommendationService.recommendation(for: base, options: options)
        return DuplicateGroup(
            id: base.id,
            files: files,
            sha256: sha256,
            verificationLevel: level,
            recommendedKeepFileID: recommendation.keepFileID,
            recommendedRemovalFileIDs: recommendation.removalFileIDs,
            recommendationReasons: recommendation.reasons
        )
    }
}

private struct MetadataKey: Hashable {
    var filename: String?
    var durationSeconds: Int?
    var fileKind: String?
    var fileExtension: String?
}
