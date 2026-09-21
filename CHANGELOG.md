# Changelog

All notable changes to File Foundry will be documented in this file.

## [1.0.0] - 2026-09-21

### Added

- Combined Duplicate Finder and Media Organizer in one native macOS app.
- Added a local FFmpeg converter with nine video, audio, and image presets.
- Added a persistent module sidebar and shared settings for both existing tools.

### Changed

- Renamed the app, bundle, updater, release assets, and repository references to File Foundry.
- Moved the published identity from Doppel to `com.junowoz.filefoundry`.
- Preserved the previous duplicate-finder preferences through a one-time fallback migration.

## [0.2.2] - 2026-08-25

### Added

- Added an LLM-friendly audit JSON export for every duplicate group found in the current scan.
- Added explicit current `keep`, `trash`, and `review` actions for every reported path.
- Added group and file SHA-256 evidence, byte-for-byte status, ordered Keep Priority matches, and machine-readable audit issues.

### Changed

- JSON export now reflects the live UI selection instead of only the initial recommendation.
- Reports now contain only duplicate groups found by the scan and omit unrelated indexed or skipped files.

## [0.2.1] - 2026-08-25

### Added

- Added persistent, ordered Keep Priority locations that automatically choose the preferred copy across every exact duplicate group.
- Added nested-folder priority so a preferred subfolder can outrank its parent library or another sibling folder.

### Changed

- Replaced removal checkboxes with a keep-first, single-choice control for each exact duplicate group.
- Simplified Exact matching so the app always performs SHA-256 hashing followed by full byte-for-byte confirmation.
- Reworked the results list with a stable lazy scroll layout and cleaner group/file rows.
- Simplified and reorganized the sidebar scan controls.

### Fixed

- Fixed result-list scroll jumps when changing which duplicate copy should be kept.
- Normalized macOS path aliases before applying or saving Keep Priority locations.

## [0.2.0] - 2026-08-25

### Added

- Added explicit Anywhere, Between Folders, and Within Each Folder search scopes.
- Added review-only metadata matching with combinable filename, media duration, file kind, and file extension criteria.
- Added native AVFoundation duration reading for supported audio and video files.
- Added tests for cross-folder matching, internal matching, metadata combinations, duration matching, and cleanup safety.

### Changed

- Recursive scans now retain each file's selected root and avoid indexing the same standardized path twice when selected folders overlap.
- Metadata candidates never receive removal recommendations or potential savings estimates.
- Trash controls remain disabled until files are confirmed through Exact Content matching.

## [0.1.5] - 2026-06-08

### Fixed

- Fixed in-app update validation inside the macOS App Sandbox by replacing `lipo` and `codesign` subprocess checks with native Mach-O and Security.framework validation.

## [0.1.4] - 2026-06-08

### Added

- Added manual keep/remove selection so users can choose which duplicate file stays before moving selected files to Trash.

### Changed

- Group and footer removable counts now reflect the current manual selection plan.
- Move-to-Trash validation now rejects any inconsistent plan that selects the keep file for removal.

## [0.1.3] - 2026-06-08

### Changed

- Improved the DMG installer with a polished Finder layout, large app icon, Applications shortcut, and drag-to-install background.
- Release DMGs now open as a guided installer instead of a raw app bundle folder.

## [0.1.2] - 2026-06-08

### Added

- Built-in **Check for Updates** panel for standalone app updates from GitHub Releases.
- `FileFoundryUpdater` helper app for replacing the current app bundle after File Foundry quits.
- Update validation for ZIP SHA-256 checksums, bundle identifier, release version, Apple Silicon architecture, and code signature.
- Ephemeral update downloads with temporary staging cleanup.

### Changed

- Added the sandbox network client entitlement only for user-triggered GitHub Releases update checks.
- Release builds now embed and sign the updater helper.
- Security, privacy, architecture, and release docs now describe the updater boundary.

## [0.1.1] - 2026-06-08

### Added

- App icon and release bundle icon embedding.
- Screenshot assets folder and README screenshot references.
- Safe **Check for Updates** entrypoint that opens GitHub Releases in the browser without adding app network entitlements.
- Apple Silicon-only release packaging checks.

### Changed

- Improved README for OSS launch readiness, usage, downloads, updates, security, and Apple Silicon builds.
- Release scripts now embed the icon and ad-hoc sign local builds by default.

### Fixed

- Hardlinked files are no longer automatically recommended for removal.
- Safe mode now repeats byte-by-byte validation before moving selected files.

## [0.1.0] - 2026-06-08

### Added

- Native SwiftUI macOS app scaffold.
- Exact duplicate detection using size, SHA-256, and byte-by-byte checks.
- Safe recommendation rules that keep at least one file.
- Move selected duplicates to Trash with pre-action validation.
- JSON and CSV report export services.
- Unit tests for hashing, comparison, duplicate detection, recommendation, export, and action validation.
- GitHub Actions CI and release workflows.
- Security, privacy, contribution, and release documentation.
