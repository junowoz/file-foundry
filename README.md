# File Foundry

All-in-one Mac toolkit: find duplicates, organize media, compress and convert files, transcribe meetings and turn an Android tablet into a second screen. Everything runs on your Mac except transcription, which uses your AssemblyAI account.

## Modules

- **Duplicate Finder** safely finds exact duplicates, verifies them byte-for-byte, and moves selected copies to Trash without permanently deleting files.
- **Media Organizer** scans selected media folders, plans a dated library, and creates verified copies while preserving originals.
- **Convert & Compress** takes one or many files. Video, audio and images can be compressed to a size you choose (for example 25 MB, with two-pass FFmpeg encoding) or a quality preset, or converted to another format. Other files and folders become a lossless ZIP.
- **Transcribe** transcribes audio, video and recorded meetings with AssemblyAI, with search, summaries and TXT/Markdown/PDF/SRT/VTT export. It can import an existing Meeting Scribe library.
- **Second Screen** turns an Android tablet or phone into an extra display over USB or Wi-Fi, using a virtual display, hardware HEVC/H.264 encoding and an encrypted, paired connection. Install `FileFoundryScreen.apk` from the release on the tablet.

## Download

Download the latest Apple Silicon build from the [File Foundry GitHub Releases](https://github.com/junowoz/file-foundry/releases).

- `FileFoundry.dmg` is the drag-to-Applications installer.
- `FileFoundry.app.zip` is the app bundle archive for manual installs or in-app updates.
- `FileFoundryScreen.apk` is the Android app for Second Screen (Android 8 or later).

Builds are arm64-only and require macOS 14 or later. The bundle identifier is `com.junowoz.filefoundry`.

## Privacy and safety

File Foundry has no login, analytics, telemetry, tracking, or external SDKs. It only accesses folders and files selected by the user. Network use is limited to: the updater (GitHub Releases, when you ask), Transcribe (uploads the media you choose to AssemblyAI with your own API key, kept in the Keychain), and Second Screen (listens on TCP 47321 only while you have started it; every connection must pair with a one-time code and is encrypted with AES-256-GCM).

Duplicate Finder never permanently deletes files. Media Organizer only creates verified copies and validates source/destination scope. Convert & Compress invokes FFmpeg directly with `Process`, uses `-n` to refuse overwrites, and never runs a shell command.

File Foundry is distributed outside App Sandbox because macOS otherwise blocks launching the user's locally installed FFmpeg executable. The app requests no signing entitlements and its own interface and services remain limited to paths the user explicitly chooses. Install FFmpeg with `brew install ffmpeg` before using Convert & Compress. Second Screen needs Screen Recording and Accessibility permission; transcription recordings need Microphone and Screen Recording.

The Media Organizer threat model and residual symlink/staging risks are documented in [Media Organizer Safety](docs/media-organizer-safety.md).

## Development

```bash
swift test
swift build --arch arm64 --product FileFoundry
swift build --arch arm64 --product FileFoundryUpdater
./script/build_and_run.sh --verify
```

The release scripts build the app and updater, sign the bundles, create ZIP/checksum assets, and package the DMG under `dist/`.
