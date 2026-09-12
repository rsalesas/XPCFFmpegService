# Testing

Four suites, plus two scripts.

| Suite | Count | Needs FFmpeg? | Time |
|---|---|---|---|
| `XPCFFmpeg` (SwiftPM) | 157 | no | ~11s |
| `XPCFFmpegServiceTests` | 53 | no — stub executables | ~70s |
| `FFmpegTaskTests` | 33 | no — captured fixtures | ~0.08s |
| End-to-end harness | 122 checks | yes | ~2m |

```bash
cd XPCFFmpeg && swift test
xcodebuild test -project XPCFFmpegService.xcodeproj -scheme XPCFFmpegServiceTests
xcodebuild test -project XPCFFmpegService.xcodeproj -scheme FFmpegTaskTests
```

Only the end-to-end harness needs a built FFmpeg. Everything else runs against stubs or fixtures,
which is why the first three are quick enough to run on every change.

## Coverage

```bash
Scripts/coverage.sh          # exits non-zero below 90%
Scripts/coverage.sh 95       # or any other floor
```

```
XPCFFmpeg           98.85%  (864/874 lines)
XPCFFmpegService    96.96%  (766/790 lines)
```

FFmpegTask is deliberately outside that gate: most of its behaviour only exists once real FFmpeg is
linked, and it is the component the process isolation exists to contain. Its parsers are covered
separately by `FFmpegTaskTests`.

Two seams exist to make this testable, both useful in their own right: `FFmpeg` takes a
`ServiceTransport` so the session can be driven without a live service, and `FFmpegTaskProcess`
takes an executable URL and a grace period so tests can substitute a stub and shorten the
cancellation escalation.

## Parser drift

`FFmpegTaskTests` is the guard against FFmpeg changing its human-readable output from under the
regular expressions that read it. Three parsers had already drifted before it existed.

The fixtures are **real captured FFmpeg output**, not hand-written samples — that distinction is the
whole point, since samples written from the documented format would encode someone's reading of it
and go on passing while `-pix_fmts` parsed nothing.

Two kinds of assertion, because neither alone is enough:

- **Line accounting** — every row FFmpeg printed must match the parser's pattern. Catches a column
  added or removed.
- **Exact values** for known entries. A column shifted by one still matches a loose pattern, and
  only a value assertion notices.

Plus a test that legend lines are *not* parsed as data, against the opposite mistake of loosening a
pattern until it swallows the preamble.

### Regenerating the fixtures

```bash
Scripts/ffmpeg-fixtures.sh            # check; rebuilds and diffs only if it needs to
Scripts/ffmpeg-fixtures.sh --force    # rebuild and diff regardless
Scripts/ffmpeg-fixtures.sh --accept   # adopt the new output as the fixtures
```

This is the expensive half — it builds FFmpeg — so it is gated on a fingerprint of the FFmpeg
checkout, its configure flags, and the parser sources. Editing the service or the client package
leaves it a 0.02s no-op; touching a parser or bumping FFmpeg makes it rebuild and report.

After `--accept`, run `FFmpegTaskTests`: failures then mean a parser needs updating, which is
exactly the signal you want from an FFmpeg upgrade.

The captured configure line is path-normalised so a different checkout is not reported as drift.

## The end-to-end harness

The suites above use stubs, so something has to exercise the real service and the real FFmpegTask
together:

```bash
Scripts/end-to-end.sh               # the API against a real service, sandbox off
Scripts/end-to-end.sh --sandboxed   # the same stack with the App Sandbox in force
Scripts/end-to-end.sh --both        # both of the above
```

It builds the project, generates its own test clip, compiles
[`EndToEndTests/`](../EndToEndTests) and injects the result into a copy of the built `.app` —
replacing the sample app's executable, so `launchd` resolves the genuine embedded XPC service. Then
it re-signs and runs. Exits non-zero if anything fails.

It covers what unit tests cannot: a real probe and conversion, progress over a real anonymous
listener, cancellation reaping the child, and the service still healthy afterwards. It also runs
the parts that only fail against real FFmpeg — the capability queries answering from the actual
build, the codec libraries encoding, two passes sharing a pass log across two jobs, loudness
measured and then applied, stills and joining.

Its first check is that the generated clip has both video and audio. That is not ceremony: until
the clip had a soundtrack, every audio assertion below it passed vacuously, and the first thing
that named an audio stream failed on the media rather than on the code.

**`--sandboxed` is the one that proves the descriptor design.** All three processes run with the
shipped entitlements, converting a file outside every container. The app is granted that directory
by a temporary-exception entitlement, which stands in for a user's Open panel selection — the
mechanism only requires that the client can open the file, not how it came by the right. A genuine
`NSOpenPanel` grant was verified by hand once, with the same result.

Not part of `xcodebuild test`, because it needs a built FFmpeg and has to re-sign a bundle. Treat it
as the check to run before trusting a release.

One wrinkle worth knowing if you edit the script: the sandboxed run canonicalises its workspace path
with `pwd -P`. `TMPDIR` lives under `/var/folders`, the sandbox resolves that to `/private/var/…`,
and a temporary-exception entitlement written with the uncanonicalised path silently never matches.
