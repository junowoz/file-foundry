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

The release workflow builds the app, embeds the updater helper, creates a ZIP, creates a guided DMG, generates SHA-256 checksums, and publishes a GitHub Release. DMG packaging uses `npx` to run the pinned `appdmg@0.6.6` layout tool.

Release artifacts are Apple Silicon only. Ad-hoc signing is the default for local and CI builds unless `CODESIGN_IDENTITY` is set to a Developer ID Application identity. Gatekeeper-friendly public releases require Developer ID signing and notarization.

The app requests no signing entitlements and is intentionally not App Sandboxed so Converter can launch a user-installed FFmpeg executable. Release validation must include `FILE_FOUNDRY_VERIFY_FFMPEG=1 ./dist/FileFoundry.app/Contents/MacOS/FileFoundry` on a Mac with FFmpeg installed.

The in-app updater expects these release assets:

- `FileFoundry.app.zip`
- `FileFoundry.app.zip.sha256`

Manual downloads also include:

- `FileFoundry.dmg`
- `FileFoundry.dmg.sha256`

The updater downloads both assets from the latest stable GitHub Release, validates the checksum and extracted `FileFoundry.app` bundle, and installs through the embedded `FileFoundryUpdater.app` helper.
