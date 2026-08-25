# Changelog

All notable changes to Doppel will be documented in this file.

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
- `DoppelUpdater` helper app for replacing the current app bundle after Doppel quits.
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
