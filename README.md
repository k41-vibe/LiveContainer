# LiveContainer RC (isolated ext-host build)

Personal test build of [LiveContainer](https://github.com/LiveContainer/LiveContainer) (AGPL-3.0) with one change:

**LiveProcess.appex can host guest apps' App Extensions** — see `LiveProcess/main.m` (`LCLaunchGuestExtensionProcess`). A guest app (e.g. [Reynard Browser](https://github.com/minh-ton/reynard-browser)) whose child processes are App Extensions can ask this LiveProcess to spawn them.

Branches:
- `isolated-rc` — bundle ID `com.k41.livecontainerrc` (display name "LiveContainer RC"), installable alongside regular LiveContainer; keychain groups separated; ShareExtension/LaunchAppExtension removed to save App ID slots
- `reynard-ext-host` — regular bundle ID (`com.kdt.livecontainer`), upstream-equivalent build with the ext-host change

Use the upstream repo for documentation, features and support. This build is for personal testing; issues go to upstream.
