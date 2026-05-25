# catapult

Shared release pipeline for Swift macOS apps. Builds, signs, notarizes, and
publishes a .app to:

- a notarized **DMG** on S3-compatible storage (e.g. Cloudflare R2), with optional Sparkle appcast
- a **Homebrew** cask (PR against any tap)
- the **Mac App Store** (.pkg via App Store Connect)

Supports both **Swift Package Manager** apps and **Tauri** apps (sharing the
notarize / upload / Homebrew steps; only the build step differs).

Each app picks which channels it ships through via its `catapult.toml`.

## Consuming catapult from an app

Add as a git submodule. The submodule itself is always SHA-pinned by git;
you just pick which commit to start from:

```sh
git submodule add https://github.com/douglaslassance/catapult.git catapult
cd catapult && git checkout <full-sha> && cd ..
git add .gitmodules catapult
```

`catapult` is intentionally untagged — releases happen by commit. To bump,
`cd catapult && git fetch && git checkout <new-sha> && cd .. && git add catapult`
and commit. GitHub Actions workflows use the same SHA via `@<sha>` refs
(see below), so the version of catapult that runs in CI matches what's
checked into the submodule.

Add a `catapult.toml` at the app repo root (copy
[templates/catapult.toml.example](templates/catapult.toml.example) and edit).

Add app-specific files at the app repo root:
- `<AppName>.entitlements` and `<AppName>-appstore.entitlements`
  (see [templates/entitlements-direct.example](templates/entitlements-direct.example)
  and [templates/entitlements-appstore.example](templates/entitlements-appstore.example))
- `cask.rb` if shipping via Homebrew
  (see [templates/cask.rb.example](templates/cask.rb.example))
- `.env` for local secrets (copy [templates/env.example](templates/env.example))

### Local use

```sh
./catapult/scripts/build.sh                # direct distribution (DMG)
./catapult/scripts/build-appstore.sh       # App Store .pkg
./catapult/scripts/verify-appstore.sh      # post-build sanity checks
./catapult/scripts/upload.sh               # push DMG/appcast/KV to S3
./catapult/scripts/upload-appstore.sh      # upload .pkg to App Store Connect
./catapult/scripts/push-homebrew.sh        # update tap, optionally --pull-request
```

All scripts source `.env` from the app root for local secrets.

### GitHub Actions

Use the reusable workflows from each app's `.github/workflows/`. Pin to
the same full SHA as your submodule — never `@main`. GitHub Actions
accepts full commit SHAs as refs:

```yaml
# .github/workflows/cd.yml
name: CD
on:
  push:
    tags: ['*.*.*']
  workflow_dispatch:
jobs:
  release:
    uses: douglaslassance/catapult/.github/workflows/release.yml@<full-sha>
    secrets: inherit
    with:
      channels: "s3,homebrew"   # or "s3,appstore,homebrew"
```

```yaml
# .github/workflows/ci.yml
name: CI
on: pull_request
jobs:
  ci:
    uses: douglaslassance/catapult/.github/workflows/ci.yml@<full-sha>
```

When bumping the submodule SHA, update both `uses:` lines to match.

## `catapult.toml` schema

```toml
[app]
name        = "Peel"                       # display + .app + executable
slug        = "peel"                       # url/filename segment
bundle_id   = "me.douglaslassance.peel"
team_id     = "556XHQJK3G"
developer   = "Douglas Lassance"           # signing identity name
homepage    = "https://peel.douglaslassance.me/"
description = "Browse different"
category    = "public.app-category.productivity"
min_macos   = "13.0"

[build]
kind          = "swift"                    # "swift" or "tauri"
arch          = "arm64"
target_triple = "aarch64-apple-darwin"
swift_target  = "App"                      # SPM target name (swift only)
# For Tauri: package_manager = "bun" | "pnpm" | "yarn" | "npm"

# Optional sections — presence enables the channel
[sparkle]
feed_url = "https://storage.douglaslassance.me/peel/peel.xml"

[s3]
bucket_prefix         = "peel"
appcast_filename      = "peel.xml"
download_url_template = "https://api.douglaslassance.me/peel/download/{version}/{target}"

[homebrew]
cask_name = "peel"

[appstore]
non_exempt_encryption = false

[plist.usage_descriptions]
NSDocumentsFolderUsageDescription = "Peel needs access to browse and display your tagged files."
```

See [templates/catapult.toml.example](templates/catapult.toml.example) for the
full annotated schema, including optional overrides.

## Required secrets

| Channel | Env var (local + CI) | Purpose |
|---------|----------------------|---------|
| s3      | `APPLE_SIGNING_IDENTITY` | "Developer ID Application: ..." string |
| s3      | `NOTARIZATION_KEY`, `NOTARIZATION_KEY_ID`, `NOTARIZATION_ISSUER_ID` | notarytool API key (base64 .p8) |
| s3      | `S3_ACCOUNT_ID`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET_NAME` | S3-compatible bucket credentials |
| s3      | `S3_PUBLIC_URL`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_KV_NAMESPACE_ID` | optional: Cloudflare cache purge + KV |
| sparkle | `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY` | EdDSA key pair (private base64) |
| homebrew | `HOMEBREW_TAP_URL` | tap repo URL (defaults to Homebrew/homebrew-cask) |
| homebrew | `HOMEBREW_TAP_TOKEN` (CI) → `GITHUB_PERSONAL_ACCESS_TOKEN` (script) | GH token for tap push |
| appstore (CI) | `APPSTORE_CERT`, `APPSTORE_CERT_PASSWORD` | Apple Distribution cert (base64 .p12) |
| appstore (CI) | `INSTALLER_CERT`, `INSTALLER_CERT_PASSWORD` | Mac Installer Distribution cert |
| appstore (CI) | `PROVISIONING_PROFILE_B64` | base64 .provisionprofile |

For local builds: `APPSTORE_CERT` / `INSTALLER_CERT` / provisioning profile
should already be in your keychain and `~/Library/MobileDevice/Provisioning Profiles/`.

## Requirements

- macOS with Xcode command-line tools
- Python 3.11+ (`brew install python@3.12` if your system Python is older)
- For uploads: `awscli`, `gh`, `brew` (auto-installed by scripts when missing)
