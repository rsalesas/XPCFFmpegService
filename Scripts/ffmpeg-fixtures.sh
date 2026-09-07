#!/bin/bash
#
# Refreshes the captured FFmpeg output that FFmpegTaskTests parses, and reports any drift.
#
# This is the expensive half of the drift story. It builds FFmpegTask, which builds FFmpeg, so it
# is gated on a fingerprint: it does nothing unless the FFmpeg checkout, its build configuration,
# or the parsers themselves have changed. Editing the XPC service or the client package does not
# trigger it.
#
#   Scripts/ffmpeg-fixtures.sh           check; rebuild and diff only if the fingerprint moved
#   Scripts/ffmpeg-fixtures.sh --force   rebuild and diff regardless
#   Scripts/ffmpeg-fixtures.sh --accept  rebuild, then adopt the new output as the fixtures
#
# The cheap half - FFmpegTaskTests itself - runs against the committed fixtures in well under a
# second and needs none of this.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/FFmpegTaskTests/Fixtures"
STAMP="$FIXTURES/.fingerprint"
DERIVED="${TMPDIR:-/tmp}"; DERIVED="${DERIVED%/}/XPCFFmpegFixtures"

MODE="${1:-check}"

VERBS=(version license protocols formats muxers demuxers devices bsfs codecs
       decoders encoders sample_fmts colors pix_fmts layouts filters)

# What the captured output actually depends on: the FFmpeg source, the flags it is configured and
# built with, and the parsers that read what it prints. Nothing else can change these files.
fingerprint() {
    {
        git -C "$ROOT" rev-parse HEAD:FFmpeg 2>/dev/null || echo "no-submodule"
        # The "Make FFmpeg" build phase carries the configure flags.
        sed -n '/Make FFmpeg/,/End PBXShellScriptBuildPhase/p' "$ROOT/XPCFFmpegService.xcodeproj/project.pbxproj" \
            | grep -o 'shellScript = .*' || true
        cat "$ROOT/FFmpegTask/OutputHandlers.swift" "$ROOT/FFmpegTask/MatchRegularExpression.swift"
    } | shasum -a 256 | cut -d' ' -f1
}

CURRENT="$(fingerprint)"
RECORDED="$(cat "$STAMP" 2>/dev/null || echo none)"

if [ "$MODE" = "check" ] && [ "$CURRENT" = "$RECORDED" ]; then
    echo "FFmpeg and the parsers are unchanged - fixtures not regenerated."
    echo "  fingerprint ${CURRENT:0:12}"
    exit 0
fi

echo "Fingerprint changed (was ${RECORDED:0:12}, now ${CURRENT:0:12}) - rebuilding FFmpegTask."

xcodebuild -project "$ROOT/XPCFFmpegService.xcodeproj" -scheme FFmpegTask \
    -configuration Debug -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- > /dev/null

# FFmpegTask is sandboxed and inherits from its parent, so a copy has to be re-signed without
# entitlements before it will run from a shell.
TASK="$DERIVED/task"
cp "$DERIVED/Build/Products/Debug/FFmpegTask" "$TASK"
codesign -f -s - "$TASK" 2>/dev/null

BREW_PREFIX="$(brew --prefix)"

# The capture hook makes PipeConnector relay raw bytes instead of running the output handler,
# which is the only way to see what FFmpeg actually printed.
CAPTURED="$DERIVED/captured"
mkdir -p "$CAPTURED"
for verb in "${VERBS[@]}"; do
    FFMPEGTASK_CAPTURE_RAW=1 "$TASK" "-$verb" > "$CAPTURED/$verb.txt" 2>/dev/null || true
    if [ ! -s "$CAPTURED/$verb.txt" ]; then
        echo "  WARNING: -$verb produced nothing; is the capture hook present in PipeConnector?"
    fi

    # -version echoes the configure line, which carries this machine's checkout, build and
    # Homebrew directories - and Homebrew lives under /opt/homebrew on Apple Silicon and
    # /usr/local on Intel. Left alone, every clone would see spurious drift. The paths are
    # replaced rather than removed so they are still absolute, which is what the parser is
    # expected to strip.
    sed -i '' -E -e "s|--prefix=[^ ]*|--prefix=/BUILD/Products/Debug|g" \
                     -e "s|$ROOT|/PROJECT|g" \
                     -e "s|$BREW_PREFIX|/HOMEBREW|g" "$CAPTURED/$verb.txt"
done

DRIFTED=0
for verb in "${VERBS[@]}"; do
    if ! diff -q "$FIXTURES/$verb.txt" "$CAPTURED/$verb.txt" > /dev/null 2>&1; then
        echo "  drift: $verb"
        # diff exits 1 when it finds differences, which under set -e + pipefail would abort here.
        diff "$FIXTURES/$verb.txt" "$CAPTURED/$verb.txt" | head -6 | sed 's/^/      /' || true
        DRIFTED=1
    fi
done

if [ "$MODE" = "--accept" ]; then
    cp "$CAPTURED"/*.txt "$FIXTURES/"
    echo "$CURRENT" > "$STAMP"
    echo
    echo "Fixtures updated. Run FFmpegTaskTests - failures now mean a parser needs fixing."
    exit 0
fi

echo
if [ "$DRIFTED" -eq 0 ]; then
    echo "FFmpeg's output is unchanged; recording the new fingerprint."
    echo "$CURRENT" > "$STAMP"
    exit 0
fi

echo "FFmpeg's output has changed. Review the diffs above, then:"
echo "  Scripts/ffmpeg-fixtures.sh --accept"
echo "and run FFmpegTaskTests to see which parsers need updating."
exit 1
