# vutusi

<img src="Resources/Icon/icon-animated.svg" alt="vutusi icon" width="128">

A macOS menu bar app that exposes a VRM avatar as a virtual camera (`vutusi Camera`) for Google Meet, Slack and other video apps.

Requires macOS 15 or later. The face, body and hand tracking runs [animovi](https://github.com/motoki317/animovi)'s solvers on MediaPipe.

## Install

1. Download `vutusi-<version>.dmg` from [Releases](https://github.com/kataomoi-zone/vutusi/releases), open it, and drag `vutusi.app` onto `Applications`.
2. Open vutusi. Approve the camera extension when macOS asks (System Settings > General > Login Items & Extensions > Camera Extensions).
3. From the menu bar icon, choose Add Model… and pick a `.vrm` file.
4. Choose `vutusi Camera` as the camera in Google Meet, Slack, or another video app, and allow camera access when macOS asks.

Settings… in the menu bar opens a live preview with the tracking, framing, light and background settings.

## Reporting problems

Right after the problem, choose Save Logs… at the bottom of Settings… and attach the saved log file to the issue. It names the vutusi and macOS versions, the camera in use with its resolution and frame rate, and every 5 seconds the tracking rate, detection rates and latency.

macOS holds these messages in memory and drops the oldest after a few minutes, and the button cannot help once vutusi has crashed. In those cases, record from Terminal instead: quit vutusi, run the command below, open vutusi, reproduce the problem, and stop with Ctrl-C. This also records the Camera Extension.

```sh
/usr/bin/log stream --level info --style compact --predicate 'subsystem == "com.kawarimidoll.vutusi"' > vutusi.log
```

The full path avoids zsh's own `log` command.

## Development

Requirements:

- Xcode 27 or later (VRMKit does not compile with Xcode 26)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (falls back to `nix shell nixpkgs#xcodegen` when not on `PATH`)
- [esbuild](https://esbuild.github.io/) (same fallback, `nixpkgs#esbuild`)
- An App Store Connect API key with the Admin role, set in `.envrc` (copy `.envrc.sample`)

```sh
scripts/dev.sh   # generate project, build, install to /Applications, launch
scripts/logs.sh  # tail logs of the app and the Camera Extension
```

`vutusi.xcodeproj` is generated from `project.yml`; edit `project.yml` instead.

On the first launch, approve the extension in System Settings > General > Login Items & Extensions > Camera Extensions.

### Camera Extension troubleshooting

```sh
systemextensionsctl list          # expect [activated enabled] for com.kawarimidoll.vutusi.CameraExtension
```

- Stuck or stale extension: choose Uninstall and then Install under Camera Extension in Settings…, then quit and relaunch vutusi.
- A running process keeps the camera list it saw at launch, so after the extension is replaced or reinstalled, relaunch vutusi and any open video app. `scripts/dev.sh` relaunches vutusi itself.
- Still stuck: `systemextensionsctl reset` (removes all third-party system extensions; requires SIP to be disabled on recent macOS) or reboot.
- Chrome and Slack cache the camera list; restart them after replacing the extension.

## Release

Releases are built by the `release` workflow (Actions > release > Run workflow), which tags the commit with a date-based version and publishes the notarized disk image. Its required secrets are listed at the top of `.github/workflows/release.yml`.

To build one locally:

```sh
scripts/release.sh    # Developer ID-signed build/release/vutusi.app
scripts/notarize.sh   # notarize, staple, and pack as build/release/vutusi-<version>.dmg
```

One-time setup, because Release builds sign manually (an API key cannot use cloud-managed Developer ID certificates):

1. A "Developer ID Application" certificate with its private key in the login keychain (`security find-identity -v -p codesigning`).
2. Two Developer ID provisioning profiles, created at <https://developer.apple.com/account/resources/profiles/add> (Distribution > Developer ID) with that certificate, downloaded, and copied to where `xcodebuild` looks for them (double-clicking installs a profile into System Settings > Device Management instead, which `xcodebuild` does not read):

   ```sh
   mkdir -p ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
   cp ~/Downloads/vutusi_*.provisionprofile ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
   ```

   | App ID | Profile name |
   |---|---|
   | `com.kawarimidoll.vutusi` | `vutusi Developer ID` |
   | `com.kawarimidoll.vutusi.CameraExtension` | `vutusi Camera Extension Developer ID` |
