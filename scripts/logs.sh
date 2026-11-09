#!/usr/bin/env bash
# Tail os.Logger output of the app and the Camera Extension (shared subsystem).
# An optional first argument is AND-combined into the predicate verbatim;
# remaining args pass through to `log stream`:
#   scripts/logs.sh
#   scripts/logs.sh 'category == "CameraExtension"'
#   scripts/logs.sh '' --style json

set -euo pipefail

predicate='subsystem == "com.kawarimidoll.vutusi"'
if [[ $# -gt 0 ]]; then
  [[ -n "$1" ]] && predicate="$predicate AND ($1)"
  shift
fi

exec log stream --predicate "$predicate" --level debug --style compact "$@"
