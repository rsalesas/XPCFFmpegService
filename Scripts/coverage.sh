#!/bin/bash
#
# Runs the unit tests for the API package and the XPC service and reports line coverage for each.
#
# FFmpegTask is deliberately not covered: it is a thin shell around FFmpeg's own fftools, most of
# its behaviour only exists when real FFmpeg is linked in, and it is the component the process
# isolation exists to contain. The end-to-end harness is what exercises it.
#
# Usage: Scripts/coverage.sh [minimum-percent]   (default 90)

set -euo pipefail

MINIMUM="${1:-90}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${TMPDIR:-/tmp}/XPCFFmpegCoverage"
FAILED=0

report() {   # name  covered  total
    local pct
    pct=$(echo "scale=2; $2 * 100 / $3" | bc)
    printf '  %-28s %7s%%  (%d/%d lines)\n' "$1" "$pct" "$2" "$3"
    if [ "$(echo "$pct < $MINIMUM" | bc)" -eq 1 ]; then
        printf '    ^ below the %s%% minimum\n' "$MINIMUM"
        FAILED=1
    fi
}

echo "== XPCFFmpeg (the API) =="
cd "$ROOT/XPCFFmpeg"
swift test --enable-code-coverage > /dev/null 2>&1
BIN=".build/arm64-apple-macosx/debug/XPCFFmpegPackageTests.xctest/Contents/MacOS/XPCFFmpegPackageTests"
PROFILE=".build/arm64-apple-macosx/debug/codecov/default.profdata"

read -r COVERED TOTAL < <(
    xcrun llvm-cov report "$BIN" -instr-profile="$PROFILE" 2>/dev/null \
    | grep "Sources/XPCFFmpeg/" \
    | awk '{ total += $8; missed += $9 } END { print total - missed, total }'
)
report "XPCFFmpeg" "$COVERED" "$TOTAL"

echo
echo "== XPCFFmpegService (the service) =="
cd "$ROOT"
xcodebuild test -project XPCFFmpegService.xcodeproj -scheme XPCFFmpegServiceTests \
    -configuration Debug -derivedDataPath "$DERIVED" -enableCodeCoverage YES \
    CODE_SIGN_IDENTITY=- > /dev/null 2>&1

XCRESULT=$(ls -td "$DERIVED"/Logs/Test/*.xcresult | head -1)

read -r COVERED TOTAL < <(
    xcrun xccov view --report "$XCRESULT" 2>/dev/null \
    | grep -E "/XPCFFmpegService/(XPCFFmpegServices|FFmpegTaskProcess|ChildProcess)\.swift" \
    | sed -E 's/.*\(([0-9]+)\/([0-9]+)\).*/\1 \2/' \
    | awk '{ covered += $1; total += $2 } END { print covered, total }'
)
report "XPCFFmpegService" "$COVERED" "$TOTAL"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "Both above the ${MINIMUM}% minimum."
else
    echo "Coverage minimum not met."
fi
exit "$FAILED"
