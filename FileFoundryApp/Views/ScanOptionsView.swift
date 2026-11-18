import FileFoundryCore
import SwiftUI

struct ScanOptionsView: View {
    @Binding var options: ScanOptions

    var body: some View {
        Form {
            Section("Scan") {
                Toggle("Include subfolders", isOn: $options.includeSubfolders)
                Toggle("Ignore hidden files", isOn: $options.ignoreHiddenFiles)
                Toggle("Ignore symlinks", isOn: $options.ignoreSymlinks)

                TextField("Minimum file size", value: $options.minimumFileSize, format: .number)

                Picker("File types", selection: fileTypeSelection) {
                    ForEach(FileTypeChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            }

            Section("Match") {
                Picker("Compare By", selection: $options.matchMode) {
                    Text("Identical Content").tag(MatchMode.exactContent)
                    Text("Matching Details").tag(MatchMode.metadata)
                }

                Text(matchHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Scope", selection: $options.searchScope) {
                    Text("Anywhere").tag(SearchScope.anywhere)
                    Text("Between folders").tag(SearchScope.betweenFolders)
                    Text("Within each folder").tag(SearchScope.withinFolders)
                }

                if options.matchMode == .metadata {
                    Toggle("Filename", isOn: criterionBinding(\.filename))
                    Toggle("Duration", isOn: criterionBinding(\.duration))
                    Toggle("File kind", isOn: criterionBinding(\.fileKind))
                    Toggle("File extension", isOn: criterionBinding(\.fileExtension))

                    if !options.metadataCriteria.hasSelection {
                        Text("Pick at least one detail.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var matchHelp: String {
        options.matchMode == .exactContent
            ? "Only files with identical content are matched."
            : "Matches files by the details you pick. Contents are not compared, so check matches before moving anything."
    }

    private func criterionBinding(_ keyPath: WritableKeyPath<MetadataMatchCriteria, Bool>) -> Binding<Bool> {
        Binding {
            options.metadataCriteria[keyPath: keyPath]
        } set: { value in
            options.metadataCriteria[keyPath: keyPath] = value
        }
    }

    private var fileTypeSelection: Binding<FileTypeChoice> {
        Binding {
            FileTypeChoice(filter: options.fileTypeFilter)
        } set: { choice in
            options.fileTypeFilter = choice.filter
        }
    }
}

private enum FileTypeChoice: String, CaseIterable, Hashable {
    case all
    case images
    case videos
    case audio
    case documents
    case archives

    init(filter: FileTypeFilter) {
        switch filter {
        case .images: self = .images
        case .videos: self = .videos
        case .audio: self = .audio
        case .documents: self = .documents
        case .archives: self = .archives
        case .all, .customExtensions: self = .all
        }
    }

    var filter: FileTypeFilter {
        switch self {
        case .all: .all
        case .images: .images
        case .videos: .videos
        case .audio: .audio
        case .documents: .documents
        case .archives: .archives
        }
    }

    var label: String {
        switch self {
        case .all: "All"
        case .images: "Images"
        case .videos: "Videos"
        case .audio: "Audio"
        case .documents: "Documents"
        case .archives: "Archives"
        }
    }
}
