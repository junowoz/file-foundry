# Release Process

1. Update `CHANGELOG.md` and `AppMetadata.version`.
2. Run tests.
3. Run `./scripts/check_secure_entitlements.sh`.
4. Run `./scripts/build_release.sh`.
5. Run `./scripts/package_dmg.sh` to create the guided drag-to-Applications DMG.
6. Create and push a SemVer tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow builds the app, embeds the updater helper, creates a guided DMG, writes `SHA256SUMS`, and publishes a GitHub Release. DMG packaging uses `npx` to run the pinned `appdmg@0.6.6` layout tool.

Release artifacts are Apple Silicon only. Ad-hoc signing is the default for local and CI builds unless `CODESIGN_IDENTITY` is set to a Developer ID Application identity. Gatekeeper-friendly public releases require Developer ID signing and notarization.

The app requests no signing entitlements and is intentionally not App Sandboxed and ships its own FFmpeg and ffprobe in `Contents/Helpers`. `scripts/build_ffmpeg.sh` builds them from pinned sources (the release workflow caches the result by the script's hash, so changing a version rebuilds them). When FFmpeg versions change, upload `vendor/ffmpeg/sources/*` to a new `ffmpeg-sources-<version>` prerelease and update `THIRD_PARTY_NOTICES.md`.

A release has exactly three assets:

- `FileFoundry.dmg`: the Mac app, used for manual downloads and by the in-app updater.
- `FileFoundry-Android.apk`: the Second Screen Android app, uploaded after CI with `scripts/publish_android.sh <tag>`.
- `SHA256SUMS`: one `shasum -a 256` line per asset. `publish_android.sh` adds the APK line.

The Mac updater downloads the DMG from the latest stable GitHub Release, checks it against `SHA256SUMS`, mounts it read-only, validates the `FileFoundry.app` bundle and installs through the embedded `FileFoundryUpdater.app` helper. The Android app checks the same release and installs `FileFoundry-Android.apk` through the system installer, which requires the same signing key.

Every tag needs its own section in `CHANGELOG.md`; the release notes are that section only.
