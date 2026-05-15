# Release

Muzzle is distributed outside the Mac App Store with Developer ID signing and Apple notarization.

## Requirements

- Paid Apple Developer Program membership.
- A `Developer ID Application` certificate installed in Keychain.
- A notarization credential profile stored locally with `notarytool`.

The Team ID is supplied locally with `APPLE_TEAM_ID` and is not stored in the repository.

## One-time Setup

Create the local notarization profile:

```sh
APPLE_ID="you@example.com" APPLE_TEAM_ID="YOURTEAMID" just notary-profile
```

`notarytool` stores the credential in Keychain under the `muzzle-notary` profile name.

## Build a Release Asset

```sh
APPLE_TEAM_ID="YOURTEAMID" just release
```

This will:

1. Generate the Tuist project.
2. Archive a Release build with Developer ID signing.
3. Export the archive for Developer ID distribution.
4. Submit a zipped app to Apple notarization.
5. Staple and validate the notarization ticket.
6. Produce a GitHub-release-ready zip in `build/release`.

The final artifact to upload to GitHub Releases is:

```text
build/release/Muzzle-<version>-macOS.zip
```

If `just check-signing` fails, install or create a Developer ID Application certificate in Xcode before retrying.
