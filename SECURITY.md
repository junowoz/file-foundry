# Security Policy

## Supported Versions

Security fixes target the latest released version.

## Reporting A Vulnerability

Please open a private security advisory on GitHub or email the maintainer if private disclosure is needed.

Include:

- Affected version or commit.
- Reproduction steps.
- Expected and actual behavior.
- Security impact.

## Security Principles

- File Foundry must not make telemetry, analytics, tracking, or background network calls.
- File Foundry may use client networking only when the user manually checks GitHub Releases for updates.
- File Foundry must never request a network server entitlement.
- File Foundry is intentionally distributed outside App Sandbox so it can launch the user's local FFmpeg executable.
- File Foundry must request no signing entitlements and enforce user-selected scope in its own services.
- File Foundry must only operate on user-selected folders.
- File Foundry must never permanently delete files.
- File Foundry must move files to Trash with `FileManager.trashItem`.
- File Foundry must revalidate files before moving them.
- File Foundry must keep at least one file in every duplicate group.
- File Foundry must treat metadata matches as review-only and reject file actions for unverified groups.
- File Foundry must validate update ZIP checksums, app bundle identity, version, architecture, and code signature before installation.

See [Media Organizer Safety](docs/media-organizer-safety.md) for the detailed copy, staging, and symlink threat model.

## Release Integrity

Release artifacts include SHA-256 checksums. The in-app updater downloads the app ZIP and checksum from official GitHub Releases, validates them, stages the app in a temporary directory, and removes update files after installation. Public releases should use Apple Developer ID signing and notarization when available.
