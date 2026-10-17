<div align="center">
  <img width="160" height="160" src="./screenshots/livecontainer_icon.png" alt="LiveContainer icon">
  <h1>LiveContainer (ext-host fork)</h1>
  <p><i>LiveContainer with App Extension hosting for guest apps</i></p>
</div>

This is a personal fork of [LiveContainer](https://github.com/LiveContainer/LiveContainer). It adds one feature: `LiveProcess.appex` can start the App Extensions that belong to a guest app. The goal is to run [Reynard Browser](https://github.com/minh-ton/reynard-browser), whose Gecko child processes are App Extensions, inside LiveContainer.

> [!WARNING]
> This is an experimental test build and has not been confirmed on a real device yet.
> It is not affiliated with the LiveContainer project. Please do not report issues from this build to upstream.

## Downloads

All builds are attached to the [v3.8.10-rc1 release](https://github.com/k41-vibe/LiveContainer/releases/tag/v3.8.10-rc1).

| File | Bundle ID | Installs as | Extensions | Branch |
|---|---|---|---|---|
| `LiveContainer-RC-lite.ipa` | `com.k41.livecontainerrc` | A separate app next to regular LiveContainer | LiveProcess only | `isolated-rc` |
| `LiveContainer-extswap.ipa` | `com.kdt.livecontainer` | An update that replaces regular LiveContainer | LiveProcess, ShareExtension, LaunchAppExtension | `reynard-ext-host` |

The `1.0` release only holds AltStore source files inherited from the parent fork. It does not contain this build.

## Installation

1. Back up your data first. In the Files app, compress the `LiveContainer` folder under On My iPhone and copy the zip somewhere safe.
2. Sign and install one of the IPAs above with AltStore or SideStore. Choose **Keep App Extensions**, because the guest extension host lives in `LiveProcess.appex`.
3. Import a guest app that uses this feature, such as [Reynard (LiveContainer build)](https://github.com/k41-vibe/reynard-lc/releases/tag/v0.17.0-lc1). Choose Keep App Extensions here as well.

To go back, install the official LiveContainer IPA over `LiveContainer-extswap.ipa`. App data stays because the bundle ID is the same.

## Differences from upstream

Common to both branches:

- `LiveProcess/main.m`: when a request includes `lcGuestExtensionPath`, LiveProcess loads that guest `.appex` and runs its principal class instead of a guest app. Failures cancel the extension request with an error in the `LiveContainer.GuestExtension` domain.

`isolated-rc` only:

- Bundle ID `com.k41.livecontainerrc` and keychain groups `com.k41.livecontainerrc.shared.*` for both the app and LiveProcess
- URL schemes `livecontainerrc://` and `liveprocessrc://`, so links do not open the regular install
- ShareExtension and LaunchAppExtension are removed to save App IDs. Importing from the share sheet and launching from Shortcuts are not available.
- Orange app icon

Full diff: [main...isolated-rc](https://github.com/k41-vibe/LiveContainer/compare/main...isolated-rc), [main...reynard-ext-host](https://github.com/k41-vibe/LiveContainer/compare/main...reynard-ext-host)

## Branches

| Branch | Contents |
|---|---|
| `main` | Upstream LiveContainer and this README |
| `isolated-rc` | Separate-app build (RC-lite) |
| `reynard-ext-host` | Regular-bundle-ID build (extswap) |

## Building

Every push to a branch runs the `Xcode - Build` workflow on GitHub Actions. The unsigned IPA is uploaded as a workflow artifact. To build locally, open `LiveContainer.xcodeproj` in Xcode and archive the `LiveContainer` scheme for `iphoneos`.

## Credits and license

LiveContainer is developed by the [LiveContainer contributors](https://github.com/LiveContainer/LiveContainer/graphs/contributors). Documentation and support are at [livecontainer.github.io](https://livecontainer.github.io/docs/intro).

This fork is distributed under the same [GNU AGPL-3.0](./LICENSE) license as upstream.
