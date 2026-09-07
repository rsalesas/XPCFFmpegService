#!/bin/bash
#
# Runs the end-to-end checks against the real XPC service and the real FFmpegTask.
#
# The unit suites all run against stubs and captured fixtures, which is what makes them fast. This
# is the one thing that puts the three processes together, so it is the check to run before
# trusting a release. It is not part of `xcodebuild test` because it needs a built FFmpeg and has
# to re-sign the app bundle it injects into.
#
#   Scripts/end-to-end.sh                the API against a real service, sandbox off
#   Scripts/end-to-end.sh --sandboxed    the same stack with the App Sandbox in force, converting
#                                        a file outside every container
#   Scripts/end-to-end.sh --both
#
# Exits non-zero if any check fails.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/XPCFFmpegEndToEnd"
mkdir -p "$WORK"
# Canonical path, not the symlinked one. TMPDIR is under /var/folders, the sandbox resolves it to
# /private/var/folders, and a temporary-exception entitlement written with the former never
# matches - the same /var vs /private/var trap that catches bookmark resolution.
WORK="$(cd "$WORK" && pwd -P)"
DERIVED="$WORK/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Debug"
MEDIA="$WORK/media"

MODE="${1:-unsandboxed}"
case "$MODE" in
    ""|unsandboxed) MODES="unsandboxed" ;;
    --sandboxed)    MODES="sandboxed" ;;
    --both)         MODES="unsandboxed sandboxed" ;;
    *) echo "usage: $(basename "$0") [--sandboxed|--both]"; exit 2 ;;
esac

mkdir -p "$MEDIA"

cleanup() { pkill -x FFmpegTask 2>/dev/null || true; pkill -x XPCFFmpegService 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- build

echo "Building (first run compiles FFmpeg, which takes a few minutes)..."
xcodebuild -project "$ROOT/XPCFFmpegService.xcodeproj" -scheme TestXPCFFmpegService \
    -configuration Debug -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- > "$WORK/build.log" 2>&1 \
    || { echo "build failed - see $WORK/build.log"; exit 1; }

# ---------------------------------------------------------------- test media

# FFmpegTask carries com.apple.security.inherit and needs a sandboxed parent, so a copy has to be
# re-signed without entitlements before it will run from a shell.
TASK="$WORK/FFmpegTask-nosandbox"
cp "$PRODUCTS/FFmpegTask" "$TASK"
codesign -f -s - "$TASK" 2>/dev/null

if [ ! -s "$MEDIA/src.mp4" ]; then
    echo "Generating test media..."
    "$TASK" -ffmpeg -f lavfi -i "testsrc=size=640x480:rate=25:duration=40" \
        -f lavfi -i "sine=frequency=440:duration=40" \
        -c:v libx264 -preset ultrafast -c:a aac -shortest \
        -y "$MEDIA/src.mp4" > /dev/null 2>&1
fi

# ---------------------------------------------------------------- entitlements
#
# Written here rather than committed, because the sandboxed run needs an absolute path to the
# workspace and that differs per machine.

cat > "$WORK/unsandboxed.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
EOF

# The temporary exception stands in for a user's Open panel selection: it gives the app - and only
# the app - access to the workspace, which is the asymmetry a real grant creates.
cat > "$WORK/sandboxed-app.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-write</key><true/>
    <key>com.apple.security.temporary-exception.files.absolute-path.read-write</key>
    <array><string>$WORK/outside/</string></array>
</dict></plist>
EOF

# ---------------------------------------------------------------- run one mode

run_mode() {
    local mode="$1" harness app xpc appEnt xpcEnt taskEnt arg

    app="$WORK/$mode.app"
    xpc="$app/Contents/XPCServices/XPCFFmpegService.xpc"

    if [ "$mode" = "sandboxed" ]; then
        harness="$ROOT/EndToEndTests/SandboxHarness.swift"
        appEnt="$WORK/sandboxed-app.entitlements"
        xpcEnt="$ROOT/XPCFFmpegService/XPCFFmpegService.entitlements"
        taskEnt="$ROOT/FFmpegTask/FFmpegTask.entitlements"
        arg="$WORK/outside"
        mkdir -p "$arg"
        cp "$MEDIA/src.mp4" "$arg/outside.mp4"
        rm -f "$arg/outside-out.mp4"
    else
        harness="$ROOT/EndToEndTests/Harness.swift"
        appEnt="$WORK/unsandboxed.entitlements"
        xpcEnt="$appEnt"
        taskEnt="$appEnt"
        arg="$MEDIA"
        rm -f "$MEDIA"/facade_* 2>/dev/null || true
    fi

    # The harness replaces the sample app's executable inside a copy of the built bundle, so that
    # launchd resolves the genuine embedded XPC service rather than anything stubbed.
    rm -rf "$app"
    cp -R "$PRODUCTS/TestXPCFFmpegService.app" "$app"
    rm -f "$app/Contents/MacOS/TestXPCFFmpegService" \
          "$app/Contents/MacOS/TestXPCFFmpegService.debug.dylib" \
          "$app/Contents/MacOS/__preview.dylib"

    xcrun swiftc -o "$app/Contents/MacOS/TestXPCFFmpegService" \
        -I "$PRODUCTS" -F "$PRODUCTS/PackageFrameworks" \
        -framework XPCFFmpeg -framework XPCFFmpegServiceFramework -framework XPCServiceFramework \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        "$harness" 2>&1 | grep " error:" && { echo "harness failed to compile"; return 1; }

    for framework in "$xpc"/Contents/Frameworks/*.framework "$app"/Contents/Frameworks/*.framework; do
        codesign -f -s - "$framework" > /dev/null 2>&1
    done
    codesign -f -s - --entitlements "$taskEnt" "$xpc/Contents/MacOS/FFmpegTask" > /dev/null 2>&1
    codesign -f -s - --entitlements "$xpcEnt" "$xpc" > /dev/null 2>&1
    codesign -f -s - --entitlements "$appEnt" "$app" > /dev/null 2>&1

    cleanup; sleep 1

    echo
    echo "=================== $mode ==================="
    "$app/Contents/MacOS/TestXPCFFmpegService" "$arg"
}

STATUS=0
for mode in $MODES; do
    run_mode "$mode" || STATUS=1
done

echo
if [ "$STATUS" -eq 0 ]; then
    echo "End-to-end checks passed."
else
    echo "End-to-end checks FAILED."
fi
exit "$STATUS"
