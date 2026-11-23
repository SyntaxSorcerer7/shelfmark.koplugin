#!/usr/bin/env bash
set -euo pipefail
export KO_HOME="$RUNNER_TEMP/e2e-home"
export SHELFMARK_E2E_ARTIFACTS="$RUNNER_TEMP/e2e-artifacts"
export SDL_AUDIODRIVER=dummy
cd "$RUNNER_TEMP/koreader/lib/koreader"
# The packaged executable uses paths relative to the KOReader runtime directory.
timeout 120s xvfb-run -a ./luajit reader.lua "$RUNNER_TEMP/e2e-home" \
  > "$SHELFMARK_E2E_ARTIFACTS/$SHELFMARK_E2E_PHASE.log" 2>&1
cat "$SHELFMARK_E2E_ARTIFACTS/$SHELFMARK_E2E_PHASE-passed.txt"
