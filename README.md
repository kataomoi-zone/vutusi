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
