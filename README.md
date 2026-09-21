# File Foundry

File Foundry is a native Apple Silicon macOS app with private, local-first tools to find exact duplicates, organize media, and convert files with FFmpeg.

## Modules

- **Duplicate Finder** safely finds exact duplicates, verifies them byte-for-byte, and moves selected copies to Trash without permanently deleting files.
- **Media Organizer** scans selected media folders, plans a dated library, and creates verified copies while preserving originals.
- **Converter** converts video, audio, and image files through a local FFmpeg executable with explicit presets, command preview, cancellation, and no silent overwrite.

## Download

Download the latest Apple Silicon build from the [File Foundry GitHub Releases](https://github.com/junowoz/file-foundry/releases).

- `FileFoundry.dmg` is the drag-to-Applications installer.
- `FileFoundry.app.zip` is the app bundle archive for manual installs or in-app updates.

Builds are arm64-only and require macOS 14 or later. The bundle identifier is `com.junowoz.filefoundry`.

## Privacy and safety

File Foundry has no login, analytics, telemetry, tracking, or external SDKs. It only accesses folders and files selected by the user. The updater contacts GitHub Releases only after the user explicitly asks to check for updates.

Duplicate Finder never permanently deletes files. Media Organizer only creates verified copies and validates source/destination scope. Converter invokes FFmpeg directly with `Process`, uses `-n` to refuse overwrites, and never runs a shell command.

File Foundry is distributed outside App Sandbox because macOS otherwise blocks launching the user's locally installed FFmpeg executable. The app requests no signing entitlements and its own interface and services remain limited to paths the user explicitly chooses. Install FFmpeg with `brew install ffmpeg` before using Converter.

The Media Organizer threat model and residual symlink/staging risks are documented in [Media Organizer Safety](docs/media-organizer-safety.md).

## Development

```bash
swift test
swift build --arch arm64 --product FileFoundry
swift build --arch arm64 --product FileFoundryUpdater
./script/build_and_run.sh --verify
```

The release scripts build the app and updater, sign the bundles, create ZIP/checksum assets, and package the DMG under `dist/`.
