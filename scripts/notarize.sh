#!/usr/bin/env bash
# Notarize build/release/vutusi.app (from scripts/release.sh), staple the ticket,
# and pack it for distribution as build/release/vutusi-<version>.dmg.
#
# Submits to Apple's notary service twice, the app and then the disk image, each
# taking about 5 to 15 minutes.
# Never re-signs the app: a bundle that fails verification is a release.sh problem.
#
# Required environment: VUTUSI_ASC_KEY_PATH, VUTUSI_ASC_KEY_ID, VUTUSI_ASC_ISSUER

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

require_asc_key
key=(--key "$VUTUSI_ASC_KEY_PATH" --key-id "$VUTUSI_ASC_KEY_ID" --issuer "$VUTUSI_ASC_ISSUER")

app=build/release/vutusi.app
[[ -d "$app" ]] || { echo "notarize.sh: $app not found; run scripts/release.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$app"
signature="$(codesign -dvv "$app" 2>&1)"
# The first Authority line names the signing certificate; the image is signed with the same.
identity="$(grep -m1 "^Authority=Developer ID Application" <<< "$signature" || true)"
identity="${identity#Authority=}"
if [[ -z "$identity" ]]; then
  echo "notarize.sh: $app is not signed with Developer ID" >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
zip=build/release/vutusi.zip
dmg="build/release/vutusi-$version.dmg"
submission=build/release/notarize.json

submit() {
  echo "notarize.sh: submitting $1 (usually 5 to 15 minutes)"
  # A rejected submission may exit non-zero; read its status from the JSON either way so
  # the notary log below gets printed.
  xcrun notarytool submit "$1" "${key[@]}" --wait --output-format json > "$submission" || true
  local status id
  status="$(plutil -extract status raw -o - "$submission")"
  if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw -o - "$submission")"
    echo "notarize.sh: status $status; the notary log follows" >&2
    xcrun notarytool log "$id" "${key[@]}" >&2
    exit 1
  fi
}

# The app goes first, zipped because the service takes no bare bundle: the image has
# to hold the stapled app, so that the copy in /Applications also opens offline.
ditto -c -k --keepParent "$app" "$zip"
submit "$zip"
rm -f "$zip"
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"

# The image shows the app next to a link to /Applications to drag it onto.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/vutusi.app"
ln -s /Applications "$staging/Applications"
diskutil image create from --format UDZO --volumeName vutusi "$staging" "$dmg"
codesign --sign "$identity" --timestamp "$dmg"
submit "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "notarize.sh: $dmg"
