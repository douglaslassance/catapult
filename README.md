# trigger

Shared release pipeline for Swift macOS apps. Builds, signs, notarizes, and
publishes a .app to:

- a notarized **DMG** on Cloudflare R2 (with optional Sparkle appcast)
- a **Homebrew** cask (PR against any tap)
- the **Mac App Store** (.pkg via App Store Connect)

Supports both **Swift Package Manager** apps and **Tauri** apps (sharing the
notarize / upload / Homebrew steps; only the build step differs).

Each app picks which channels it ships through via its `trigger.toml`.

## Consuming trigger from an app

Add as a git submodule pinned to a tag:

```sh
git submodule add -b 0.1.0 https://github.com/douglaslassance/trigger.git trigger
```

Add a `trigger.toml` at the app repo root (copy
[templates/trigger.toml.example](templates/trigger.toml.example) and edit).

Add app-specific files at the app repo root:
- `<AppName>.entitlements` and `<AppName>-appstore.entitlements`
  (see [templates/entitlements-direct.example](templates/entitlements-direct.example)
  and [templates/entitlements-appstore.example](templates/entitlements-appstore.example))
- `cask.rb` if shipping via Homebrew
  (see [templates/cask.rb.example](templates/cask.rb.example))

### Local use

```sh
./trigger/scripts/build.sh                # direct distribution (DMG)
./trigger/scripts/build-appstore.sh       # App Store .pkg
./trigger/scripts/verify-appstore.sh      # post-build sanity checks
./trigger/scripts/upload.sh               # push DMG/appcast/KV to R2
./trigger/scripts/upload-appstore.sh      # upload .pkg to App Store Connect
./trigger/scripts/push-homebrew.sh        # update tap, optionally --pull-request
```

All scripts source `.env` from the app root for local secrets.

### GitHub Actions

Use the reusable workflows from each app's `.github/workflows/`:

```yaml
# .github/workflows/cd.yml
name: CD
on:
  push:
    tags: ['*.*.*']
  workflow_dispatch:
jobs:
  release:
    uses: douglaslassance/trigger/.github/workflows/release.yml@0.1.0
    secrets: inherit
    with:
      channels: "direct,homebrew"   # or "direct,appstore,homebrew"
```

```yaml
# .github/workflows/ci.yml
name: CI
on: pull_request
jobs:
  ci:
    uses: douglaslassance/trigger/.github/workflows/ci.yml@0.1.0
```

## `trigger.toml` schema

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

[r2]
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

See [templates/trigger.toml.example](templates/trigger.toml.example) for the
full annotated schema, including optional overrides.

## Required secrets

| Channel | Env var (local + CI) | Purpose |
|---------|----------------------|---------|
| direct  | `APPLE_SIGNING_IDENTITY` | "Developer ID Application: ..." string |
| direct  | `NOTARIZATION_KEY`, `NOTARIZATION_KEY_ID`, `NOTARIZATION_ISSUER_ID` | notarytool API key (base64 .p8) |
| sparkle | `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY` | EdDSA key pair (private base64) |
| r2      | `S3_ACCOUNT_ID`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET_NAME` | R2 credentials |
| r2      | `S3_PUBLIC_URL`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_KV_NAMESPACE_ID` | optional: cache purge + KV |
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
