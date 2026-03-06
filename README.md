# mocode (codex-ios)

<p align="center">
  <img src="Sources/Mocode/Resources/brand_logo.png" alt="mocode logo" width="180" />
</p>

`mocode` is an iOS client for Codex in remote mode.

## Prerequisites

- Xcode.app (full install, not only CLT)
- `xcodegen` (for regenerating `Mocode.xcodeproj`):
  ```bash
  brew install xcodegen
  ```

## Codex source (submodule + patch)

This repo now vendors upstream Codex as a submodule:

- `third_party/codex` -> `https://github.com/openai/codex`

On-device iOS exec hook changes are kept as a local patch:

- `patches/codex/ios-exec-hook.patch`

Sync/apply patch (idempotent):

```bash
./scripts/sync-codex.sh
```

## Optional: Build the Rust bridge

```bash
./scripts/build-rust.sh
```

This is optional and not required for the default app target. The script:

1. Syncs `third_party/codex` and applies the iOS hook patch
2. Builds `codex-bridge` for device + simulator targets
3. Repackages `Frameworks/codex_bridge.xcframework`

## Build and run iOS app

Regenerate project if `project.yml` changed:

```bash
xcodegen generate
```

Open in Xcode:

```bash
open Mocode.xcodeproj
```

Schemes:

- `Mocode`

CLI build example:

```bash
xcodebuild -project Mocode.xcodeproj -scheme Mocode -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Important paths

- `project.yml`: source of truth for Xcode project/schemes
- `codex-bridge/`: Rust staticlib wrapper exposing `codex_start_server`/`codex_stop_server`
- `third_party/codex/`: upstream Codex source (submodule)
- `patches/codex/ios-exec-hook.patch`: iOS-specific hook patch applied to submodule
- `Sources/Mocode/Bridge/`: Swift bridge + JSON-RPC client
- `Sources/Mocode/Resources/brand_logo.svg`: source logo (SVG)
- `Sources/Mocode/Resources/brand_logo.png`: in-app logo image used by `BrandLogo`
- `Sources/Mocode/Assets.xcassets/AppIcon.appiconset/`: generated app icon set

## Branding assets

- Home/launch branding uses `BrandLogo` (`Sources/Mocode/Views/BrandLogo.swift`) backed by `brand_logo.png`.
- The app icon is generated from the same logo and stored in `AppIcon.appiconset`.
- If logo art changes, regenerate icon sizes from `Icon-1024.png` (or re-run your ImageMagick resize pipeline) before building.
