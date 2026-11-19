# Architecture

File Foundry is organized around a testable core and a native SwiftUI shell with Duplicate Finder, Media Organizer, and Converter modules.

The direct-distribution bundle is not App Sandboxed because Converter launches the FFmpeg executables bundled in `Contents/Helpers`. All three modules still begin from explicit user selections and apply their own path and operation checks.

## Core Target

- `Models`: file metadata, duplicate groups, options, results, actions, and settings.
- `Services`: scanning, hashing, byte comparison, duplicate detection, recommendations, file actions, reports, previews, and settings persistence.
- `ViewModels`: app state and UI orchestration.

## App Target

- `App`: SwiftUI app entrypoint.
- `Views`: sidebar, duplicate groups, file rows, preview, settings, progress, and summary surfaces.
- `Support`: formatting helpers, update notifications, and updater helper launch code.

## Updater Target

`FileFoundryUpdater` is a small helper app embedded in `FileFoundry.app/Contents/Library/Helpers`. It does not perform network requests. The main app downloads and validates the update, then launches the helper so it can wait for File Foundry to quit, replace the app bundle, reopen File Foundry, and remove temporary update files.

## Detection Pipeline

1. Scan user-selected folders.
2. Skip hidden files, symlinks, and macOS packages according to options.
3. Retain the selected root for each indexed file and apply the chosen Anywhere, Between Folders, or Within Each Folder scope.
4. In Exact mode, group by size and hash candidates.
5. Confirm Exact-mode matches with a full byte-by-byte comparison after SHA-256 hashing.
6. In Metadata mode, group review candidates by the selected filename, duration, file kind, and extension criteria.
7. Recommend removals only for exact groups; metadata groups never cross the file-action boundary.

## Safety Boundary

Only `FileActionService` moves files. It rejects metadata groups and validates existence, size, SHA-256, and byte comparison before calling `FileManager.trashItem`.

`RecommendationService` applies ordered preferred-folder paths before fallback filename, temporary-folder, and path-length heuristics. The first matching preferred location wins, allowing a nested folder to outrank its parent when ordered first.

`ReportExportService` creates a local, selection-aware audit JSON from duplicate groups only. It records per-file hashes and current actions, group verification state, ordered preferred-folder matches, and machine-readable consistency checks without performing network requests.

Only `AppUpdateService` downloads updates. It uses an ephemeral URL session, validates the release ZIP checksum, validates the extracted app bundle, and stages files in a temporary directory before installation.
