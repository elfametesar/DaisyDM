# Releasing Daisy DM

Daisy DM ships with a manual GitHub Actions workflow at
`.github/workflows/manual-build-release.yml`.

## Build only

1. Open **Actions → Build & Release Daisy DM → Run workflow**.
2. Leave **Create the tag and publish a GitHub release** disabled.
3. Enter a three-part numeric version such as `1.2.0`, or leave the version
   blank to generate one from the UTC date and workflow run number.
4. Download the `daisy-dm-<version>` artifact from the completed run.

## Publish a release

Enable **Create the tag and publish a GitHub release**. The workflow will:

- build a universal `arm64` and `x86_64` macOS application;
- synchronize the app, Safari extension, and Chrome extension versions;
- create ZIP archives and SHA-256 checksums;
- create the `v<version>` tag automatically;
- publish a GitHub release named `Daisy DM v<version>`;
- generate release notes unless custom notes are supplied.

The release job is separate from the build job. Repository write access is only
provided to the release job when publishing was explicitly requested.

## Signing status

The workflow uses ad-hoc signing so the app and embedded Safari extension can be
validated in CI without repository secrets. The resulting app is not notarized.
For public distribution, add Developer ID signing and Apple notarization before
publishing production releases.
