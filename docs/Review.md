# Code Review

A full review of the repository at commit `8f5323a` (12 September 2026), covering every first-party
source file, the three test suites, the scripts, the Xcode project, and the documentation. The FFmpeg
submodule itself was not reviewed beyond diffing the two vendored `fftools` files against it.

## Verdict

This is a well-built project with a sound architecture and unusually good tests for its size. The
three-process design is justified in the docs and holds up in the code: the reasons given (FFmpeg's
global state, signal-based cancellation, crash isolation, and the sandbox-extension hop limit) are
real, and the descriptor-passing design is the correct answer to the last of them. The end-to-end
harness is the strongest part of the repo, because it proves the sandbox claim rather than asserting
it.

All three unit suites pass on this machine, as does the end-to-end harness. The counts below differ
from the ones in [Testing.md](Testing.md), which are stale.

| Suite | Tests | Result |
|---|---|---|
| `XPCFFmpeg` (`swift test`) | 157 | pass, ~11s |
| `XPCFFmpegServiceTests` | 53 | pass, ~66s |
| `FFmpegTaskTests` | 33 | pass, ~0.07s |
| End-to-end harness | 122 checks | pass, unsandboxed |

`Scripts/coverage.sh` was not run, so the coverage figures quoted in Testing.md are unverified here,
and the harness was run unsandboxed only.

There were six confirmed correctness bugs, all in [RequestBuilder.swift](../XPCFFmpeg/Sources/XPCFFmpeg/RequestBuilder.swift),
and all in the newer typed surface (stream overrides, two-pass, the escape hatch). None affected the
simple one-input, one-output path that the sample app and most callers use. They are listed first,
then design concerns, then hygiene.

## Confirmed bugs

**All six were fixed after this review, and each has a regression test.** The descriptions are kept
as the record of what was wrong; the *Fixed* note on each says what changed. The client suite is 157
tests as a result, and the end-to-end harness gained four sections covering the risky parts against
real FFmpeg.

### 1. A destination is truncated before the request is validated, and regardless of `overwriteExisting`

[RequestBuilder.swift:43-56](../XPCFFmpeg/Sources/XPCFFmpeg/RequestBuilder.swift:43) opens every
output with `O_WRONLY | O_CREAT | O_TRUNC` while the argument vector is still being built. Two
consequences:

- **A conversion that fails to build destroys earlier outputs.** With two outputs where the second
  has an unrecognisable extension, `container(for:)` throws `indeterminateContainer` for the second,
  but the first has already been truncated to zero bytes. Repro: write bytes to `keep.mp4`, build a
  `Conversion` with outputs `[Output(url: keep), Output(url: "noext")]`, catch the throw, check the
  size of `keep.mp4`. It is 0.
- **`Conversion.overwriteExisting = false` does not protect the file.** The flag only controls
  whether `-y` is emitted. The file is truncated at build time either way, so the best case is that
  ffmpeg then refuses to write to an already-emptied file. Repro: same as above with a single output
  and `overwriteExisting: false`; the file is 0 bytes after `RequestBuilder.request(for:)` returns,
  before any job runs.

The `placeholders` cleanup in `FFmpeg.discardUnwritten` only removes files that did not exist before,
so an existing file that was truncated is left empty rather than restored.

**Fixed.** `request(for:)` now resolves every output's muxer and checks the overwrite policy before
anything is opened, and destinations are opened without `O_TRUNC` and emptied together, last, only
once the whole vector is built. A build that throws deletes the destinations it created. Truncation
is still ours to do rather than ffmpeg's, since ffmpeg reaches the output through a descriptor and
cannot truncate it. `overwriteExisting: false` now throws `FFmpegError.destinationExists`, which is
the only place it can be enforced: ffmpeg's `-n` never sees a filename to refuse.

### 2. Stream overrides emit encoder options that are not stream-scoped

`append(video:streamIndex:pass:)` scopes `-c`, `-b`, `-maxrate`, `-bufsize`, `-profile` and `-level`
to the selector, but emits `-crf`, `-g`, `-tune`, `-s`, `-r`, `-preset` and `-pix_fmt` bare
([RequestBuilder.swift:104-121](../XPCFFmpeg/Sources/XPCFFmpeg/RequestBuilder.swift:104)). Bare
options apply to every stream of that type, so an override cannot actually override them.

Repro: blanket `.h264(quality: 20, preset: .fast)` plus
`StreamOverride(.video(1), .video(VideoSettings(codec: .h264, quality: 35, preset: .ultrafast)))`
produces:

```
-c:v libx264 -crf 20 -preset fast -c:v:1 libx264 -crf 35 -preset ultrafast
```

The second `-crf 35` and `-preset ultrafast` are global, so they win for stream 0 too. The doc
comment on `StreamOverride` promises the opposite. Audio has the same problem with `-ar`, `-ac` and
`-channel_layout`.

**Fixed.** Every per-stream option now carries its specifier, in the blanket case too: `-crf:v`,
`-g:v`, `-tune:v`, `-s:v`, `-r:v`, `-preset:v`, `-pix_fmt:v`, the four colour tags, the encoder
options, `-ar:a`, `-ac:a` and `-channel_layout:a`. Verified against real FFmpeg by the end-to-end
harness, which exercises all of them.

### 3. `isTwoPass` on a stream override runs two jobs but never emits `-pass`

`Output.requiresTwoPasses` and `convertInPasses` both look inside `streamOverrides` for
`isTwoPass`, so the conversion runs twice. But `-pass N` is only appended from `append(video:...)`
when called for `output.video`; `append(overrides:)` at
[RequestBuilder.swift:251](../XPCFFmpeg/Sources/XPCFFmpeg/RequestBuilder.swift:251) does not receive
the pass number. Both jobs run as ordinary single-pass encodes, the first one to `/dev/null`.

Repro: an `Output` with no blanket `video` and a `.video(0)` override carrying `isTwoPass: true`;
`requiresTwoPasses` is true, and the pass-1 argument vector contains `-passlogfile` but no `-pass`.
There is a test that the override is *recognised* (`testATwoPassEncodeIsRecognisedFromItsSettings`)
but none that it is *acted on*.

### 4. Loudness on a stream override costs a measuring pass and then does nothing

`Output.requiresTwoPasses` checks override audio for `loudness?.isTwoPass`, but `filterGraph(for:)`
at [RequestBuilder.swift:408](../XPCFFmpeg/Sources/XPCFFmpeg/RequestBuilder.swift:408) reads only
`outputs.first?.audio?.loudness`. An override-only loudness request runs two jobs and never composes
the `loudnorm` filter. It also means loudness on any output other than the first is silently ignored.

Repro: an `Output` with `video: .disabled` and a `.audio(0)` override carrying `loudness: .streaming`;
`requiresTwoPasses` is true and the measuring-pass arguments contain no `loudnorm`.

**Fixed (3).** `append(overrides:pass:)` now receives the pass number, and `-pass` is emitted
scoped to whichever settings actually asked for two passes — so an override gets `-pass:v:0` and a
blanket setting that never asked for it no longer picks one up.

**Fixed (4).** Loudness inside a `StreamOverride` now throws `FFmpegError.unsupportedSetting`, whose
message carries the `loudnorm` filter string and says to put it on `Output.audio` or into a graph of
your own. Making it work properly would mean naming every other stream of the output in the graph,
which needs a stream count the builder does not have. Loudness on any output but the first is
refused too, rather than costing a measuring pass and being left out of the command line.

### 5. The escape hatch opens every file read-only

`RequestBuilder.raw` at [RequestBuilder.swift:446](../XPCFFmpeg/Sources/XPCFFmpeg/RequestBuilder.swift:446)
calls `token(forReading:)` for every URL in `files`. The comment in the substitution loop talks about
"a bare trailing path - an output", but an output path in `files` either fails to open (file does not
exist) or is opened read-only, and ffmpeg then fails writing to it. So `FFmpeg.run` can only be used
for probes and for conversions whose output is `-f null`, which is exactly what the one end-to-end
check of it does. The Usage docs do not say this.

**Fixed.** `FFmpeg.run` and `RequestBuilder.raw` now take `reading:` and `writing:`, and open each
accordingly. A destination created this way is recorded as a placeholder, so a failed job tidies it
away like any other.

### 6. `.webm` extension maps to the `matroska` muxer

[RequestBuilder.swift:275](../XPCFFmpeg/Sources/XPCFFmpeg/RequestBuilder.swift:275) infers
`"matroska"` for both `mkv` and `webm`. The `webm` muxer writes a WebM DocType and enforces the
codec subset; `matroska` does neither. A file written this way carries a Matroska DocType under a
`.webm` name, which some players and every browser conformance check will reject. `Container.webm`
already maps correctly to `"webm"`, so the inconsistency is only in the extension fallback.

**Fixed.** The two extensions map to their own muxers. The end-to-end harness reads the EBML DocType
out of the written file to check it, since ffprobe reports `matroska,webm` for either.

## Design and API concerns

These are judgement calls rather than bugs. They are ordered by how much they would cost to change
later.

**Swift 6 readiness.** Nothing in the public API is `Sendable`. `FFmpeg` and `Job` are classes
guarded by `NSLock`, `Progress` is handed to a `@Sendable` closure, and `Conversion` and friends are
plain structs. Under Swift 5 language mode this compiles cleanly (no warnings from `swift build`).
Under strict concurrency it will not. Marking the value types `Sendable`, and `FFmpeg` and `Job`
`@unchecked Sendable` with a note about the lock, would be cheap now and expensive once consumers
exist.

**`Job.value()` returns `Any?`.** The typed paths (`convert`, `probe`, the capability queries)
wrap this, but `startConversion` and `run` hand a caller an untyped result. A generic
`Job<Result>` or separate `ConversionJob` and `RawJob` types would remove the cast from every
consumer.

**`MediaInfo` is neither `Equatable`, `Codable` nor `Sendable`.** It is the type most likely to be
cached, compared or displayed, and it is a pure value. Adding the conformances is mechanical.

**Frame rate reads `r_frame_rate`.** [MediaInfo.swift:128](../XPCFFmpeg/Sources/XPCFFmpeg/MediaInfo.swift:128)
uses ffprobe's `r_frame_rate`, which is the timebase-derived rate and is famously wrong for
variable-frame-rate sources (phone video often reports 1000 or 90000). `avg_frame_rate` is what most
callers want. Exposing both, or preferring `avg_frame_rate`, would avoid a support question later.
Rotation (the display matrix in `side_data_list`) is also absent, and phone video is the common case
where it matters.

**`convert` probes remote inputs too.** [FFmpeg.swift:60](../XPCFFmpeg/Sources/XPCFFmpeg/FFmpeg.swift:60)
calls `probeDuration(of: first.url)` for any input. For `.remote`, `probeRequest` tries to open the
URL as a local file, throws, and is swallowed. Harmless, but a remote input could be probed properly
by passing the URL through to ffprobe, and then remote conversions would get a progress fraction.

**The measuring pass encodes audio it will discard.** For a video-only two-pass encode, pass 1
still decodes and encodes the audio track to `/dev/null`. Adding `-an` to a measuring pass that has
no loudness work would make it noticeably faster on long files.

**`-passlogfile` is emitted per output.** [RequestBuilder.swift:354](../XPCFFmpeg/Sources/XPCFFmpeg/RequestBuilder.swift:354)
is inside the outputs loop, so a two-pass conversion with two outputs gives both the same log prefix.
ffmpeg suffixes the prefix with the output stream index, not the output file index, so two outputs
each with one video stream collide. Rare, but silent.

**`LoudnessMeasurement(parsing:)` searches for the last `{`.** [MultiPass.swift:32](../XPCFFmpeg/Sources/XPCFFmpeg/MultiPass.swift:32)
works because `loudnorm` prints a flat object at the very end. Any later log line containing a brace,
or a future nested field, breaks it. Anchoring on the `input_i` key, or on the line that precedes the
block, would be more robust.

**The measuring share is a constant.** `measuringShare = 0.33` is reasonable, but a loudness-only
measuring pass (decode audio, no video) is far quicker than a video first pass, so the bar will jump
at the handover in that case. Not worth fixing unless someone complains.

**`FFmpegStatus.Domain.unkown`** at [XPCFFmpegProtocols.swift:98](../XPCFFmpegServiceFramework/Sources/XPCFFmpegServiceFramework/XPCFFmpegProtocols.swift:98)
is a typo in a public enum, mirrored in FFmpegTask's `OutputHandlers.swift`. It is also on the wire,
so fixing it means changing both ends together. The client's `LogMessage.Level` already maps it to
`.unknown` so nothing user-facing shows it.

**`FFmpegStatus` conforms to `LocalizedError`.** A status line is not an error. This is a 2020
leftover and confuses the type's role.

## The service and the child process

The service is the part most likely to hurt if it is wrong, and it is in good shape. `complete(_:)`
enforcing exactly one reply, the escalation capturing the process rather than `self`, signal
dispositions reset at spawn, and the write lock on the stderr pipe are all correct and all tested.
Some notes:

**Nothing cancels a job when the client goes away.** The per-job status connection's error handler
at [XPCFFmpegServices.swift:139](../XPCFFmpegService/XPCFFmpegServices.swift:139) is a `print` with
a TODO, and `XPCListenerDelegate` sets no invalidation handler on accepted connections. If the app
drops its `FFmpeg` (which invalidates the connection) while a conversion runs, the service keeps
encoding to completion. Because the app embeds the service, quitting the app does terminate the
service, but FFmpegTask is a plain child and is reparented rather than killed. Worth verifying by
hand and, if confirmed, setting an invalidation handler that cancels every job on that connection.

**One blocked thread per running child.** [ChildProcess.swift:138](../XPCFFmpegService/ChildProcess.swift:138)
parks a global-queue thread in `waitpid` for the life of each job. Fine for a handful of concurrent
conversions; a `DispatchSource.makeProcessSource` would not consume a thread. Low priority.

**The argument blocklist is not a security boundary, and should not be described as one.**
[FFmpegTask.swift:36](../FFmpegTask/FFmpegTask.swift:36) rejects `-vf`, `-af` and `-filter` by exact
match, so `-filter:v` passes. It also does not cover options that take a path ffmpeg opens by name:
`-filter_script`, `-filter_complex_script`, `-passlogfile`, `-vstats_file`, `-report`,
`-dump_attachment`. None of this matters for privilege, because the only client is the app that
embeds the service, and the child is sandboxed with `inherit`. But the docs say `-vf` is "rejected"
as if that were a guarantee. The honest statement is that the sandbox is the boundary and the
blocklist is a convenience. The list also contains `-version` and `-license` twice.

**Scratch directories can leak on early rejection.** `invoke` creates scratch directories while
walking the arguments, and returns `inaccessibleFile` on a token mismatch afterwards without removing
them. The hourly sweep catches it, so this is cosmetic.

**`sweepStaleScratch` runs on every invoke.** A directory listing per job is cheap, but it would be
tidier on a timer or at service start.

## FFmpegTask

**`PipeConnector.write(data:)` uses `buffer` when there is no output handler**
([PipeConnector.swift:97](../FFmpegTask/PipeConnector.swift:97)). Every live path either has a
handler or is `.end` mode where `data` and `buffer` are the same thing, so this is latent. In
`.available` mode (unused) it would re-send the whole accumulated buffer on every read. Change it to
`data` and the surprise goes away.

**Unparseable stderr lines are dropped silently.** A stderr line that does not match
`FFmpegStatus.RegExPattern` returns nil from `init(from:)` and `write(data:)` returns without
framing anything. The pattern ends with a catch-all `(?<Unknown>.*)` so in practice everything
matches, but the failure mode is invisible if that ever changes.

**`CStringArray` traps on an empty array.** [CStringArray.swift:31](../Support/CStringArray.swift:31)
iterates `0...count - 1`, which is a fatal range when `count` is 0. Every caller passes at least the
program name, so it cannot happen today. `0..<count` costs nothing.

**`descriptors.c` has a no-op macro.** [descriptors.c:16](../FFmpegTask/descriptors.c:16) defines
`show_help_default()` as a macro in a translation unit that never uses it, with a comment about
avoiding a change to `ffmpeg_opt.c`. Macros do not cross translation units. What actually makes this
link is that `ffprobe.c` had its `show_help_default` removed in the vendored copy (see the diff below)
and `ffmpeg_opt.c` still provides one. The macro and its comment should go.

**The vendored `ffmpeg.c` and `ffprobe.c` diverge from upstream by exactly four hunks:** the
`program_name`/`program_birth_year` globals removed from each, `main` renamed to `ffmpeg`/`ffprobe`,
and `ffprobe.c`'s `show_help_default` deleted. That is the minimal patch and it is easy to re-apply
on an FFmpeg bump. Consider a `Scripts/refresh-fftools.sh` that copies from the submodule and applies
those four edits with `sed`, so the next upgrade is mechanical and the diff stays reviewable.

## Build and project hygiene

**`.gitmodules` lists a submodule that does not exist.** It declares
`XPCFFmpegService/NSException` pointing at `rsalesas/NSException`, but there is no such path in the
tree and `git submodule status` shows only FFmpeg. The functionality was vendored into `Support/`.
Remove the stale entry; some tooling (and `git submodule update --init` on a strict client) will
complain about it.

**FFmpeg is built for one architecture.** The *Make FFmpeg* phase configures with
`--arch="${ARCHS%% *}"`. Debug has `ONLY_ACTIVE_ARCH = YES` so this matches. A Release build with the
default `ARCHS` of `arm64 x86_64` would build FFmpeg for arm64 only and fail to link the x86_64
slice. If universal builds are ever wanted, the phase needs to build twice and `lipo`. If they are
not, `ARCHS` should be pinned so the failure mode is explicit rather than discovered at archive time.

**The FFmpeg build phase does not rerun when the submodule moves.** Its only outputs are
`lib/libavutil.a` and the two generated C files, and it declares no inputs. Bumping the FFmpeg
submodule leaves stale archives in `lib/` until someone runs the `rm -rf` from Building.md. Declaring
`$(PROJECT_DIR)/.git/modules/FFmpeg/HEAD` as an input, or writing a stamp file keyed on the submodule
hash (the fixtures script already computes one), would make the bump self-correcting.

**`FFmpegTask` points at an `Info.plist` that does not exist.** `INFOPLIST_FILE =
"$(SRCROOT)/FFmpegTask/Info.plist"` in both configurations, but the file is not in the tree. Xcode
tolerates this for a command-line tool, so the build passes. Clear the setting.

**`DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY = "Apple Development"` are hardcoded** for every
target. Anyone outside that team has to pass `CODE_SIGN_IDENTITY=-` on the command line, which the
scripts do, or edit the project. An `xcconfig` that is gitignored, or a `Local.xcconfig` pattern,
would let a contributor build without touching `project.pbxproj`.

**Test schemes are not shared.** `xcshareddata/xcschemes` contains only `FFmpegTask` and
`TestXPCFFmpegService`. `xcodebuild -list` still shows `XPCFFmpegServiceTests` and `FFmpegTaskTests`
because Xcode autocreates schemes per target, and the docs' `xcodebuild test -scheme ...` commands
work for that reason. Sharing them makes that explicit and lets them carry test-plan settings.

**The two protocol packages have placeholder tests.** `XPCServiceFrameworkTests` and
`XPCFFmpegServiceFrameworkTests` each contain one test that asserts a string constant, plus
`LinuxMain.swift` and `XCTestManifests.swift` from a 2020 template. Either give them something to
test (`ServiceError(exitCode:)`, `FFmpegRequest.scratch(from:)`, the secure-coding round trips, all of
which are currently only tested indirectly from `XPCFFmpeg`) or delete them.

**Version numbers are all `1.0` / `1`** and copyright strings say 2020. `MARKETING_VERSION` is not
set. Fine for now, but the licensing docs recommend tagging what is shipped, and there is nothing to
tag against.

## Dead code

None of the following is referenced anywhere outside its own definition:

- `XPCServiceProxy`, `XPCServiceProxyProtocol`, `XPCServiceProxyDelegateProtocol` in
  [XPCServiceFramework.swift](../XPCServiceFramework/Sources/XPCServiceFramework/XPCServiceFramework.swift)
  (the client uses `NSXPCConnection` directly via `XPCServiceTransport`).
- The whole of [XPCServiceFactory.swift](../XPCServiceFramework/Sources/XPCServiceFramework/XPCServiceFactory.swift).
- [Support/URLExtensions.swift](../Support/URLExtensions.swift), the bookmark-resolving initialiser.
  Bookmarks are no longer used anywhere, which the Architecture doc explains at length. It is still
  compiled into two targets.
- [Support/MiscExtensions.swift](../Support/MiscExtensions.swift): `ProcessInfo.isSandboxed` and
  `LosslessStringConvertible.string`.
- `MatchRegularExpression.fullMatch`.

Removing them shrinks the public surface of `XPCServiceFramework` to the two listener-delegate
classes, which is what it actually is.

## Documentation

The docs are the best part of the repository after the tests, and most of what follows is drift
from the last four days of commits.

- ~~**[Testing.md](Testing.md) counts are stale.**~~ It said 88 / 44 / 32 tests and 23 end-to-end
  checks; refreshed to the measured 157 / 53 / 33 and 122 checks.
- ~~**[Usage.md](Usage.md) contradicts itself on remote inputs.**~~ Fixed while the bugs were being
  fixed: the "Capabilities" passage said `protocols()` listed more than the API could reach, which
  predated `Input.remote`. The same stale note was on `Protocols` in Capabilities.swift.
- **[Building.md](Building.md) says "four Homebrew packages"** and then lists eleven.
- **[Architecture.md](Architecture.md) says "Two consequences"** and lists four.
- ~~**The escape hatch's read-only limitation** (bug 5) is not documented.~~ The limitation is
  gone, and Usage.md now shows both `reading:` and `writing:`.
- **`FFmpeg.run` has its summary line twice** in the doc comment at
  [FFmpeg.swift:140-142](../XPCFFmpeg/Sources/XPCFFmpeg/FFmpeg.swift:140).
- The README's claim that `-vf`/`-af` are "rejected" should be softened as described above.

## Tests

What is good: the fixture-based drift suite for the parsers is exactly the right shape and the
comments explain why hand-written fixtures would be worthless. The stub-executable suite for the
service reaches cases (a child that ignores SIGTERM, exit 123, a desynchronised pipe) that would be
impractical with real FFmpeg. The client tests drive a real anonymous XPC listener for progress,
which is more honest than mocking it. The end-to-end harness checks the sandbox claim with real
entitlements.

What is missing, in order of value:

1. ~~Regression tests for bugs 1 to 6.~~ Added: nine in `RequestBuilderTests`, six in
   `ConversionOptionsTests`, four end-to-end sections.
2. Direct tests for `ServiceError(exitCode:)`, `FFmpegRequest.scratch(from:)` and the
   `NSSecureCoding` round trips, in the framework package that owns them.
3. A `PipeConnector` test. It is the one non-trivial piece of FFmpegTask with no coverage, and the
   `payload = buffer` oddity would have been noticed.

The `ServiceTransportTests` case against a missing service takes ten seconds because it waits for
the inverted expectation. That is most of the package suite's wall clock; a shorter timeout on the
inverted expectation would bring the suite under two seconds.

## Security and the sandbox

The threat model is malformed media, not a hostile client, and the design handles that model well:
FFmpeg runs sandboxed, in its own process, with only the descriptors the app chose to hand it, and
a crash there is a failed job rather than a dead app.

Things worth stating plainly in the docs:

- The service accepts any connection (`shouldAcceptNewConnection` returns `true` unconditionally).
  That is correct for an app-embedded XPC service, which launchd scopes to the containing bundle,
  but the reason should be written down so nobody "fixes" it by adding audit-token checks, and so
  nobody reuses `XPCServiceFramework` for a Mach service where it would matter.
- Scratch-token ids are validated as UUIDs before naming a directory, which closes the path
  traversal that `testAScratchTokenThatIsNotOneIsRejected` covers. Good.
- Hardened runtime is on for every target and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` is off for
  FFmpegTask. Both correct.
- The argument blocklist caveat above.

## Licensing

The NOTICE, the FFmpegTask README and the Integrating doc are consistent with each other and with
the build: the GPL surface is FFmpegTask alone, the codec list in NOTICE matches `CODEC_LIBRARIES`
and `OTHER_LDFLAGS`, and the LGPL fallback is described accurately. The reasoning about the
process boundary is careful and includes the right caveat. Nothing to change.

One small thing: NOTICE's table lists `libvmaf`, and the configure line enables it via the library
copy, but `--enable-libvmaf` is not in the configure flags. Either it is linked without being used
(harmless, but then it need not be copied or listed) or it should be enabled. Worth checking what
`ffmpeg.license()` and `-filters` actually report for `libvmaf`.

## Recommendations, in order

Bugs 1 to 6 are done. What is left:

1. Add `Sendable` conformances now, while there are no external consumers.
2. Remove the dead code, the stale `.gitmodules` entry, the phantom `Info.plist` setting, and the
   `descriptors.c` macro.
3. Decide on universal builds and make the FFmpeg phase either do them or refuse them.
4. Add the invalidation handler that cancels jobs when a client connection dies, after checking by
   hand whether FFmpegTask outlives a killed service.
