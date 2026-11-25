# Changelog

All notable changes to File Foundry will be documented in this file.

## [1.5.3] - 2026-11-25

### Fixed

- Racks keep working in parallel. Switching to another rack no longer stops a conversion, compression, duplicate scan or App Cleaner scan, and each rack keeps its files and results when you come back.

### Added

- Explicit reset: Start Over in Duplicate Finder and Media Organizer (Remove all in Convert & Compress, Rescan in App Cleaner). Nothing is cleared by switching racks anymore.

## [1.5.2] - 2026-11-18

### Added

- Convert & Compress: SVG images convert to PNG, JPEG, WebP, HEIC, TIFF, GIF and BMP. Vectors are rendered sharp (at least 2048 px on the long side) with transparency kept.
- A Home screen is now the first thing File Foundry shows, with a card for each tool.

### Fixed

- Dark Mode: the Move to Trash button in Duplicate Finder no longer renders as a washed-out red block.

## [1.5.1] - 2026-11-18

### Changed

- FFmpeg now ships inside File Foundry. Convert & Compress works on any Mac with nothing to install, including WebP, VP9/WebM, MP3, Opus, H.264 and HEVC.

## [1.5.0] - 2026-11-18

### Added

- Convert & Compress: images convert like video and audio. Photos convert to JPEG, PNG, HEIC, TIFF, GIF and BMP (and WebP when FFmpeg supports it).
- iPhone HEIC/HEIF photos, RAW camera files, AVIF and JPEG 2000 are recognised as images instead of plain files, read by macOS at full resolution with the right orientation.
- Image conversions use macOS itself, so they work even without FFmpeg installed, and keep colour profiles and photo metadata.

## [1.4.2] - 2026-11-18

### Changed

- New, cleaner logo for File Foundry on Mac and Android: three rack units with the active one lit. The Android app now has its own icon.
- Sidebar: every rack icon sits in the same column, so the names line up and no longer touch the icons.

### Fixed

- Transcribe and Duplicate Finder: the end of the list or transcript was hidden under the status bar.
- Transcribe: importing a large video no longer freezes the app while it copies.
- Transcribe: canceling a resumed transcription or a queue marks every item as canceled instead of leaving it spinning.
- App Cleaner: removing an app no longer changes the app you selected meanwhile; Leftovers refresh after a removal or Put Back; safety checks no longer stall the window; scans stop when you leave the rack.
- App Cleaner: clearing caches says the files went to the Trash (space frees up when you empty it).
- Updates: a running Homebrew upgrade stays visible when you switch tabs and can't be started twice; a stuck upgrade is stopped after its time limit.

## [1.4.1] - 2026-11-18

### Fixed

- Transcribe: "Try Again" retries the same item instead of adding a copy named "source". Items already named "source" get their original title back.
- Transcribe: canceling shows "Processing canceled" instead of a raw "cancelled" error.
- Transcribe: long uploads retry on their own (up to 3 times) when AssemblyAI or the network has a brief problem, instead of failing with "AssemblyAI is unavailable".

## [1.4.0] - 2026-11-18

### Added

- App Cleaner, a new rack. Pick an app to see everything it installed and move it to the Trash in one step. It also finds leftovers of apps that are no longer installed and clears developer caches. Everything goes to the Trash and can be put back from the Removed tab.
- App Updates, inside App Cleaner: Homebrew apps, apps with their own updater and App Store apps in one list.

### Fixed

- Convert & Compress: the empty screen matches the other racks and no longer repeats the title.
- Duplicate Finder: the "Folders" header is no longer a white bar.

### Safety

- App Cleaner only looks in the Library folders where apps keep their files and matches by the app's identifier, never by searching the whole disk for a name. It never deletes anything permanently, and it names every large folder of app data before you confirm.

## [1.3.0] - 2026-11-18

### Added

- File Foundry checks for updates on its own and shows an "Update Available" button in the toolbar. "Check for Updates…" is in the File Foundry menu.
- The Android app checks for updates and installs them itself.
- Racks can be reordered by dragging them in the sidebar (right-click → Reset Order to undo).

### Changed

- The whole app is in English, and every rack shares the same layout: an empty state with one clear action, a status bar at the bottom, and file pickers that no longer lock the rest of the app.
- Releases now have only three files: `FileFoundry.dmg`, `FileFoundry-Android.apk` and `SHA256SUMS`. The README links straight to both downloads.
- Duplicate Finder: plainer options. "Identical Content" and "Matching Details" replace the technical labels, and the macOS packages option is gone (apps and libraries are always skipped as single items).
- Meeting summaries are written in the language of the transcript.
- Media Organizer creates English folder names (Photos, Undated, Reports…) in new organized copies.

### Upgrading from 1.2.x

The 1.2 updater looks for files that no longer exist, so download `FileFoundry.dmg` once from the README link. From 1.3.0 on, updates install from inside the app.

## [1.2.1] - 2026-11-18

### Fixed

- The rack list on the left went blank in Transcribe and Duplicate Finder because their own split views were nested inside the app's. They now use a plain resizable split.
- The Meeting Scribe import card did not appear: macOS hides another app's data until access is allowed, so the library looked missing. File Foundry now reads it directly, which shows the macOS prompt, and explains how to allow access if it was denied.
- Transcribe stayed empty and unresponsive while macOS waited for Keychain permission (each new build asks again). The library now loads first and the API key follows.
- The Meeting Scribe import is offered even if something was already transcribed in File Foundry.
- The Transcribe file picker opens as a sheet on the window instead of a blocking app-wide panel.

## [1.2.0] - 2026-11-18

### Added

- Transcribe: Meeting Scribe now lives inside File Foundry, with a one-time import of an existing Meeting Scribe library (APFS clone copy, paths rewritten) and its AssemblyAI key. Deleting can also move the original imported file to the Trash.
- Second Screen: use an Android tablet or phone as an extra display over USB (adb) or Wi-Fi, with a virtual display, hardware encoding, pairing codes and an encrypted stream. Android app `FileFoundryScreen.apk` ships with the release.

### Changed

- Converter and Compressor are one module, Convert & Compress: drop one or many files, pick Compress or Convert per kind, and process them as a queue. Optional hardware encoding for quality mode, HEIC output.
- Transcribe settings moved into a compact in-module sheet; the transcript action bar no longer stretches.

## [1.1.0] - 2026-11-17

### Added

- Compressor: shrink any video, audio or image to a target size (two-pass H.264/HEVC with automatic resolution step-down) or a quality preset; other files and folders become a lossless ZIP.
- Shared drop zone, file card, progress and result panels for Compressor and Converter, with determinate FFmpeg progress and cancellation.

### Changed

- New simple vector app icon (`FileFoundryApp/Resources/Brand/FileFoundryIcon.svg`).
- Redesigned Converter, Duplicate Finder and Media Organizer: adaptive layouts down to 760x520, collapsible preview inspector, grouped toolbar, stepper for the organizer flow.
- Heavy work (trash validation, previews, planning, probing) moved off the main thread; thumbnails are cached.

### Security

- Duplicate Finder re-checks file type, size and modification time before moving to Trash.
- The scanner no longer follows symlinks out of the chosen folders.
- Updates require HTTPS and a code signature from the same Team ID as the running app.
- Compressor and Converter never use a shell, refuse to overwrite or write onto the input, and keep temporary files in a private directory removed on finish or cancel.

## [1.0.0] - 2026-09-21

### Added

- Combined Duplicate Finder and Media Organizer in one native macOS app.
- Added a local FFmpeg converter with nine video, audio, and image presets.
- Added a persistent module sidebar and shared settings for both existing tools.

### Changed

- Renamed the app, bundle, updater, release assets, and repository references to File Foundry.
- Moved the published identity from the previous standalone duplicate finder to `com.junowoz.filefoundry`.
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
