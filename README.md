# catapult

Shared release pipeline for Swift apps. Builds, signs, notarizes, and
publishes to:

- a notarized **DMG** on S3-compatible storage (e.g. Cloudflare R2), with optional Sparkle appcast
- a **Homebrew** cask (PR against any tap)
- the **Mac App Store** (.pkg via App Store Connect)
- **iOS TestFlight / App Store** (.ipa via App Store Connect)
- **Google Play** (.aab via the Google Play Developer API)
- downloadable **MSI**, **DEB** and **AppImage** builds next to the DMG, for Compose and Tauri desktop apps

Supports **Swift Package Manager** and **Tauri** macOS apps (sharing the
notarize / upload / Homebrew steps; only the build step differs), plus **iOS
Xcode-project** apps (archived and exported by `xcodebuild`, uploaded to App
Store Connect — which is what puts a build on TestFlight), plus **Android
Gradle** apps (bundled and signed by the app's own Gradle build, published to a
Google Play track), plus **Tauri mobile** apps that release on iOS and Android
together, plus **Compose Multiplatform** and **Tauri** desktop apps built on
macOS, Windows and Linux.

Each app picks which channels it ships through via its `catapult.toml`.

### iOS apps in brief

iOS support is `kind = "xcodeproj"` + `platform = "ios"` in `catapult.toml`.
It only uses the `appstore` channel (DMG / Homebrew / Sparkle are macOS-only).
`release.sh` archives with `xcodebuild`, exports an App Store `.ipa`, and
uploads it with the same App Store Connect API key the macOS path uses
(`NOTARIZATION_KEY` / `_KEY_ID` / `_ISSUER_ID`). Locally:

```sh
./catapult/release.sh                    # defaults to --channels appstore for iOS
./catapult/release.sh 1.2.3              # explicit marketing version
```

See the iOS block in [catapult.toml.example](catapult.toml.example) for the
config fields. The build number is derived automatically from the latest
commit's Unix timestamp (`git log -1 --format=%ct`), so every upload is unique
and increasing. A timestamp rather than a commit count because a count can go
backwards after a rebase, a squash, or in a shallow clone, and App Store
Connect rejects a build number that is not greater than the last one.

Uploading only parks a build in App Store Connect. Add a `[testflight]` section
and `release.sh` also distributes it:

```toml
[testflight]
groups = ["Friends"]
submit_for_review = true
```

`testflight_ios.sh` then waits for processing, writes "What to Test" from the
commit subjects since the previous tag, attaches the groups, and submits the
build for Beta App Review when any group is external. Pass `--no-testflight` to
upload without distributing, and re-run `./catapult/testflight_ios.sh` on its
own if processing outruns the timeout — every step is idempotent.

Two caveats. Beta App Review is only waived for later builds inside a version
train that already passed review, and catapult mints a new marketing version per
release, so essentially every release goes through review. And the App Store
Connect key needs **App Manager** or Admin to submit for review, where uploading
alone only needs Developer.

### Android apps in brief

Android support is `kind = "gradle"` + `platform = "android"` in
`catapult.toml`, and it ships only through the `play` channel. `release.sh`
runs the app's Gradle release task (`bundleRelease` by default), checks the
bundle came out signed, and publishes it to a Google Play track:

```sh
./catapult/release.sh 1.2.3              # defaults to --channels play for Android
./catapult/upload_play.sh --dry-run      # check the service account can reach the app
```

The version is the tag and the versionCode is the latest commit's Unix
timestamp, the same scheme as iOS. catapult passes them to Gradle as
`CATAPULT_VERSION` and `CATAPULT_BUILD_NUMBER`, so the app's
`build.gradle.kts` should read those. Signing stays in the app's own Gradle
config.

Publishing needs a Google Cloud service account invited in Play Console with
release permission, its JSON key base64-encoded in `PLAY_SERVICE_ACCOUNT_JSON`.
With `[play] track = "internal"`, testers get the build as soon as the upload
commits, with release notes from the commit subjects since the previous tag.

### Tauri mobile apps in brief

A Tauri app ships on iOS and Android from one repo with `kind = "tauri"` and
`platforms = ["ios", "android"]` in `catapult.toml`. `release.sh` then builds
and publishes both under one version and one build number: `tauri ios build`
exports the `.ipa` that `upload_ios.sh` and `testflight_ios.sh` take from
there, and `tauri android build` makes the `.aab` that `upload_play.sh`
publishes.

```sh
./catapult/release.sh 1.2.3                     # appstore,play
./catapult/release.sh 1.2.3 --channels play     # Android only
```

### Compose desktop apps in brief

Compose Multiplatform desktop support is `kind = "compose"` in `catapult.toml`,
whose platform is then `desktop`. jpackage only builds for the OS it runs on,
so a release runs once per host and each run uploads what that host made.

| Host | Artifacts in `dist/`, each with a `.sha256` |
|------|---------------------------------------------|
| macOS | `${slug}-${version}-${target}.dmg`, signed inside out (natives inside jars too), notarized and stapled |
| Windows | `${slug}-${version}-${target}.msi`, Authenticode signed when `WINDOWS_CERTIFICATE` is set |
| Linux | `${slug}-${version}-${target}.deb` and `${slug}-${version}-${target}.AppImage` |

```sh
./catapult/release.sh 1.2.3              # s3 on any host, plus homebrew on a Mac
```

The app keeps a Gradle wrapper at its root and needs a JDK 17+. catapult runs
`createDistributable`, `packageMsi` or `packageDeb` on the `composeApp` module
(`[build] gradle_module` to change it) with `-Papp.version=<version>`. The
target triple comes from the host, so leave `arch` and `target_triple` unset.
On a Mac, catapult stamps the real version into the Info.plist (jpackage refuses
a zero major version), merges `[plist.extras]`, `[plist.usage_descriptions]` and
`[plist.env]` into it, and copies `[build] icon_assets` in as `Assets.car`. The
Linux AppImage takes its icon from `[build] linux_icon`, and appimagetool is
downloaded on first use.

Only the macOS host records the release, since the release API keeps the
extension of a version's first record and the Homebrew cask downloads the
`.dmg`. In GitHub Actions, `platform: desktop` builds on `runner` (`macos-15` by
default), `windows-latest` and `ubuntu-24.04`, and the Homebrew job takes the
DMG from the macOS leg.

### Tauri desktop apps in brief

A Tauri app releases on macOS, Windows and Linux the same way once
`catapult.toml` sets `platform = "desktop"` next to `kind = "tauri"`, without
`arch` or `target_triple` since the host decides them. Each host runs `tauri
build` for its own bundles and leaves the artifacts in the table above in
`dist/`. The macOS DMG is signed, notarized and stapled as before.

With `bundle.createUpdaterArtifacts`, the updater manifest `${slug}.json` lists
`darwin-aarch64` (the `.app.tar.gz`), `windows-x86_64` (the MSI, signed for the
updater after Authenticode), `linux-x86_64` (the AppImage) and
`linux-x86_64-deb` (the `.deb`, which an app installed from it picks first),
each with its signature. Every host writes its entries to
`dist/${slug}-${version}-${target}.updater.json`, and `upload_manifest.sh`
merges fragments into the published manifest. Run locally, `upload.sh` does
that for its own host at once. In GitHub Actions the legs run in parallel, so
the `updater-manifest` job merges every fragment once all legs succeeded. Each
leg needs `TAURI_SIGNING_PRIVATE_KEY` and its password.

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
[catapult.toml.example](catapult.toml.example) and edit).

Add app-specific files at the app repo root:
- `<AppName>.entitlements` and `<AppName>-appstore.entitlements`
  (see [entitlements-direct.example](entitlements-direct.example)
  and [entitlements-appstore.example](entitlements-appstore.example))
- `cask.rb` if shipping via Homebrew
  (see [cask.rb.example](cask.rb.example))
- `.env` for local secrets (copy `catapult/env.example` to `.env`)
- `PrivacyInfo.xcprivacy` if shipping to the App Store, copied into
  `Contents/Resources` of App Store builds
- `Licenses/` for third-party notices that must ship with the binary, copied
  into `Contents/Resources/Licenses`. Sparkle's is added there automatically.

### Local use

For a full release, use the orchestration script — it runs the same flow as
the CD workflow:

```sh
./catapult/release.sh                                  # s3 + homebrew (default)
./catapult/release.sh 1.2.3                            # explicit version
./catapult/release.sh --channels s3,homebrew,appstore  # all channels
```

Individual scripts are also available if you need to run just one step:

```sh
./catapult/build.sh                # direct distribution (DMG)
./catapult/build_appstore.sh       # App Store .pkg
./catapult/verify_appstore.sh      # post-build sanity checks
./catapult/upload.sh               # push DMG/appcast to S3, record the release
./catapult/upload_appstore.sh      # upload .pkg to App Store Connect
./catapult/push_homebrew.sh        # update tap, optionally --pull-request
```

All scripts source `.env` from the app root for local secrets.

> **Sparkle parity.** Declaring `[sparkle]` in `catapult.toml` enables embedding
> + signing in the direct build, but you must also `import Sparkle` in your
> `Package.swift` and wire `SPUStandardUpdaterController` into your app. If
> the framework isn't a Swift Package dependency, the build script logs a
> warning and continues without embedding.

### GitHub Actions

Catapult ships one reusable workflow — `release.yml` — for the release
pipeline. Pin to the same full SHA as your submodule (never `@main`):

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
      # platform: desktop       # Compose or Tauri apps, built on macOS, Windows and Linux
```

When bumping the submodule SHA, update the `uses:` line to match.

### Scope: release, not CI

Catapult is a **release** framework, not a CI framework. Each app implements
its own `ci.yml` (lint / build / test) — Swift apps want different tooling
than Tauri apps, and forcing a shared CI shape ends in conditionals. The
release pipeline is genuinely shared (codesign + notarize + DMG + upload +
homebrew are identical per app); CI isn't.

## `catapult.toml` schema

```toml
[app]
name        = "MyApp"                       # display + .app + executable
slug        = "myapp"                       # url/filename segment
bundle_id   = "com.example.myapp"
team_id     = "556XHQJK3G"
developer   = "Douglas Lassance"           # signing identity name
homepage    = "https://example.com/myapp"
description = "Leverageable tagging"
category    = "public.app-category.productivity"
min_macos   = "13.0"

[build]
kind          = "swift"                    # "swift", "tauri", "xcodeproj", "gradle" or "compose"
arch          = "arm64"
target_triple = "aarch64-apple-darwin"
swift_target  = "App"                      # SPM target name (swift only)
# For Tauri: package_manager = "bun" | "pnpm" | "yarn" | "npm",
#            platform = "desktop" for Windows and Linux too (no arch or target_triple)
# For Compose: gradle_module = "composeApp", icon_assets = "composeApp/icons/Assets.car",
#              linux_icon = "composeApp/icons/icon.png" (no arch or target_triple)

# Optional sections — presence enables the channel
[sparkle]
feed_url = "https://example.com/myapp/myapp.xml"

[s3]
bucket_prefix         = "myapp"
appcast_filename      = "myapp.xml"
download_url_template = "https://example.com/myapp/download/{version}/{target}"

[homebrew]
cask_name = "myapp"

[appstore]
non_exempt_encryption = false

[plist.usage_descriptions]
NSDocumentsFolderUsageDescription = "MyApp needs access to your Documents folder."
```

See [catapult.toml.example](catapult.toml.example) for the
full annotated schema, including optional overrides.

## Required secrets

| Channel | Env var (local + CI) | Purpose |
|---------|----------------------|---------|
| s3      | `APPLE_SIGNING_IDENTITY` | "Developer ID Application: ..." string |
| s3      | `NOTARIZATION_KEY`, `NOTARIZATION_KEY_ID`, `NOTARIZATION_ISSUER_ID` | notarytool API key (base64 .p8) |
| s3      | `S3_ACCOUNT_ID`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET_NAME` | S3-compatible bucket credentials |
| s3      | `S3_PUBLIC_URL`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `RELEASE_API_URL`, `RELEASE_API_TOKEN` | optional: Cloudflare cache purge, release record |
| sparkle | `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY` | EdDSA key pair (private base64) |
| homebrew | `HOMEBREW_TAP_URL` | tap repo URL (defaults to Homebrew/homebrew-cask) |
| homebrew | `HOMEBREW_TAP_ACCESS_TOKEN` | GH personal access token for tap push |
| appstore (CI) | `APPSTORE_CERT`, `APPSTORE_CERT_PASSWORD` | Apple Distribution cert (base64 .p12) |
| appstore (CI) | `INSTALLER_CERT`, `INSTALLER_CERT_PASSWORD` | Mac Installer Distribution cert |
| appstore (CI) | `PROVISIONING_PROFILE_B64` | base64 .provisionprofile |
| play    | `PLAY_SERVICE_ACCOUNT_JSON` | Google Play service account key (base64 JSON) |
| s3 (desktop on Windows) | `WINDOWS_CERTIFICATE`, `WINDOWS_CERTIFICATE_PASSWORD` | optional: Authenticode certificate (base64 .pfx) that signs the MSI |
| s3 (Tauri) | `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | updater signing key, needed on every host |

For local builds: `APPSTORE_CERT` / `INSTALLER_CERT` / provisioning profile
should already be in your keychain and `~/Library/MobileDevice/Provisioning Profiles/`.

## Requirements

- macOS with Xcode command-line tools
- Python 3.11+ (`brew install python@3.12` if your system Python is older)
- For uploads: `awscli`, `gh`, `brew` (auto-installed by scripts when missing)
- For Android: a JDK (Gradle and `jarsigner`) and `openssl`
- For Compose desktop apps: a JDK 17+ on every host, Git Bash and the Windows
  SDK's `signtool` on Windows (where `python` will do for Python), and `curl`
  on Linux to fetch appimagetool
- For Tauri desktop apps: Rust and the app's package manager on every host, Git
  Bash and `signtool` on Windows, and Tauri's Linux build dependencies
  (WebKitGTK 4.1 and friends) on Linux
