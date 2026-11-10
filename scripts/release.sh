#!/usr/bin/env bash
# Build a Developer ID-signed vutusi.app into build/release/, ready for
# scripts/notarize.sh.
#
# The Release configuration signs manually with the Developer ID certificate in the
# keychain and two Developer ID provisioning profiles placed by hand (README:
# Release), so neither step needs an Xcode account or an API key, locally or on CI.
# Automatic signing cannot be used: it signs with a cloud-managed Developer ID
# certificate, which only the Account Holder may use, not an API key.
#
# CFBundleVersion is the current time, so an installed copy's Camera Extension is
# replaced by this one. CFBundleShortVersionString is $VERSION when set (CI passes
# the release tag), else project.yml's MARKETING_VERSION.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

scripts/build-web.sh
xcodegen_generate

out=build/release
mkdir -p "$out"
version_settings=(CURRENT_PROJECT_VERSION="$(date +%s)")
[[ -n "${VERSION:-}" ]] && version_settings+=(MARKETING_VERSION="$VERSION")

run() {
  local log=$1
  shift
  if ! "$@" > "$log" 2>&1; then
    grep -E "error:|FAILED" "$log" | sort -u >&2 || tail -30 "$log" >&2
    echo "release.sh: failed (full log: $log)" >&2
    exit 1
  fi
}

echo "release.sh: archiving (log: $out/archive.log)"
run "$out/archive.log" xcodebuild archive \
  -project vutusi.xcodeproj -scheme vutusi -configuration Release \
  -archivePath "$out/vutusi.xcarchive" \
  "${version_settings[@]}"

cat > "$out/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>8QD5Y2QV2Q</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>com.kawarimidoll.vutusi</key>
		<string>vutusi Developer ID</string>
		<key>com.kawarimidoll.vutusi.CameraExtension</key>
		<string>vutusi Camera Extension Developer ID</string>
	</dict>
</dict>
</plist>
PLIST

echo "release.sh: exporting with Developer ID (log: $out/export.log)"
run "$out/export.log" xcodebuild -exportArchive \
  -archivePath "$out/vutusi.xcarchive" \
  -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out"

codesign --verify --deep --strict "$out/vutusi.app"
codesign -dvv "$out/vutusi.app" 2>&1 | grep -E "^Authority=Developer ID Application|^TeamIdentifier"
echo "release.sh: $out/vutusi.app"
