# vutusi

A macOS menu bar app that exposes a VRM avatar as a virtual camera (`vutusi Camera`) for Google Meet, Slack and other video apps.

Requires macOS 15 or later.

## Development

Requirements:

- Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (falls back to `nix shell nixpkgs#xcodegen` when not on `PATH`)
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

- Stuck or stale extension: choose "Uninstall Camera Extension" and then "Install Camera Extension" from the menu bar, then quit and relaunch vutusi.
- A running process keeps the camera list it saw at launch, so after the extension is replaced or reinstalled, relaunch vutusi and any open video app. `scripts/dev.sh` relaunches vutusi itself.
- Still stuck: `systemextensionsctl reset` (removes all third-party system extensions; requires SIP to be disabled on recent macOS) or reboot.
- Chrome and Slack cache the camera list; restart them after replacing the extension.

## Release

```sh
scripts/release.sh    # Developer ID-signed build/release/vutusi.app
scripts/notarize.sh   # notarize, staple, and zip as build/release/vutusi-<version>.zip
```

One-time setup, because the export signs manually (an API key cannot use cloud-managed Developer ID certificates):

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
