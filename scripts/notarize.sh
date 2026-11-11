#!/usr/bin/env bash
# Notarize build/release/vutusi.app (from scripts/release.sh), staple the ticket,
# and zip it for distribution as build/release/vutusi-<version>.zip.
#
# Submits the app to Apple's notary service, which takes about 5 to 15 minutes.
# Never re-signs: a bundle that fails verification is a release.sh problem.
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
# Captured first: `grep -q` stops reading early, and under pipefail the SIGPIPE it
# leaves codesign with fails the whole check.
signature="$(codesign -dvv "$app" 2>&1)"
if ! grep -q "^Authority=Developer ID Application" <<< "$signature"; then
  echo "notarize.sh: $app is not signed with Developer ID" >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
zip="build/release/vutusi-$version.zip"
submission=build/release/notarize.json

# A zip with the .app as its single top-level entry, as Finder expects.
ditto -c -k --keepParent "$app" "$zip"
echo "notarize.sh: submitting $zip (usually 5 to 15 minutes)"
# A rejected submission may exit non-zero; read its status from the JSON either way so
# the notary log below gets printed.
xcrun notarytool submit "$zip" "${key[@]}" --wait --output-format json > "$submission" || true
status="$(plutil -extract status raw -o - "$submission")"
if [[ "$status" != "Accepted" ]]; then
  id="$(plutil -extract id raw -o - "$submission")"
  echo "notarize.sh: status $status; the notary log follows" >&2
  xcrun notarytool log "$id" "${key[@]}" >&2
  exit 1
fi

# The submitted zip lacks the ticket; staple it into the app and zip again, so the
# app also opens offline.
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
spctl --assess --type execute --verbose=2 "$app"
echo "notarize.sh: $zip"
