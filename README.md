# File Foundry

All-in-one Mac toolkit: find duplicates, organize media, compress and convert files, transcribe meetings and turn an Android tablet into a second screen. Everything runs on your Mac except transcription, which uses your AssemblyAI account.

## Download

**[Download for Mac](https://github.com/junowoz/file-foundry/releases/latest/download/FileFoundry.dmg)** needs macOS 14 or later on Apple Silicon.

**[Download for Android](https://github.com/junowoz/file-foundry/releases/latest/download/FileFoundry-Android.apk)** needs Android 8 or later.

Both apps update themselves. All releases and checksums are on the [Releases page](https://github.com/junowoz/file-foundry/releases).

## Modules

- **Duplicate Finder** safely finds exact duplicates, double-checks them, and moves selected copies to Trash without permanently deleting files.
- **Media Organizer** scans selected media folders, plans a dated library, and creates verified copies while preserving originals.
- **Convert & Compress** takes one or many files. Video, audio and images can be compressed to a size you choose (for example 25 MB, with two-pass FFmpeg encoding) or a quality preset, or converted to another format. Other files and folders become a lossless ZIP.
- **Transcribe** transcribes audio, video and recorded meetings with AssemblyAI, with search, summaries and TXT/Markdown/PDF/SRT/VTT export. It can import an existing Meeting Scribe library.
- **Second Screen** turns an Android tablet or phone into an extra display over USB or Wi-Fi, using a virtual display, hardware HEVC/H.264 encoding and an encrypted, paired connection. Install the Android app from the release on the tablet.

## Privacy and safety

File Foundry has no login, analytics, telemetry, tracking, or external SDKs. It only accesses folders and files selected by the user. Network use is limited to: the updater (checks GitHub Releases at launch and once a day; you can turn this off in the update window), Transcribe (uploads the media you choose to AssemblyAI with your own API key, kept in the Keychain), and Second Screen (listens on TCP 47321 only while you have started it; every connection must pair with a one-time code and is encrypted with AES-256-GCM).

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

The release scripts build the app and updater, sign the bundles, package the DMG and `SHA256SUMS` under `dist/`. `scripts/publish_android.sh <tag>` adds the Android APK to a release.
