# Shared by dev.sh, release.sh and notarize.sh; sourced with the repository root as
# the working directory.

# Loads .envrc when the App Store Connect key is not in the environment yet (a
# non-interactive shell has no direnv hook), and stops with a hint if it is incomplete.
require_asc_key() {
  if [[ -z "${VUTUSI_ASC_KEY_ID:-}" && -f .envrc ]]; then
    # shellcheck disable=SC1091
    source .envrc
  fi
  local missing=() v
  for v in VUTUSI_ASC_KEY_PATH VUTUSI_ASC_KEY_ID VUTUSI_ASC_ISSUER; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "$(basename "$0"): missing env: ${missing[*]} (see .envrc.sample)" >&2
    exit 1
  fi
}

# Regenerates vutusi.xcodeproj from project.yml.
xcodegen_generate() {
  if command -v xcodegen > /dev/null; then
    xcodegen generate --quiet
  else
    nix shell nixpkgs#xcodegen -c xcodegen generate --quiet
  fi
}
