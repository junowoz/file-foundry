# Privacy Policy

File Foundry is private, local-first software. One module, Transcribe, sends media you choose to AssemblyAI.

- No account is required.
- No internet connection is required for scanning, cleanup, organizing, converting, compressing or Second Screen.
- The app is distributed outside App Sandbox so it can launch a locally installed FFmpeg executable.
- The interface and application services operate on files and folders the user explicitly selects.
- No analytics are collected.
- No telemetry is collected.
- No tracking is performed.
- No file paths, hashes, metadata, or reports are uploaded.

Network features:

- **Check for Updates** contacts official GitHub Releases after the user clicks it. Update checks do not upload file paths, hashes, metadata, or reports.
- **Transcribe** uploads the audio or video you choose to AssemblyAI using your own API key (stored in the macOS Keychain) and downloads the transcript. AssemblyAI's own privacy terms apply to that media. Transcripts and media stay in `~/Library/Application Support/File Foundry/Transcribe`.
- **Second Screen** listens on TCP port 47321 and advertises itself on the local network only while you have started it. Tablets must pair with a one-time code; the stream and input are encrypted end to end (AES-256-GCM) and never leave your network.

Reports exported by the user may contain file paths and hashes. Store and share exported reports carefully.
