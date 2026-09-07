# Using XPCFFmpeg

`XPCFFmpeg` is the package an app links. It hides the XPC entirely: no connections, no listener
endpoints, no job IDs, no bookmarks or descriptors.

```swift
import XPCFFmpeg

let ffmpeg = FFmpeg()
```

One `FFmpeg` per app is the intended shape. It owns the connection to the service and hands out
jobs; it is not a per-job object, because you cannot hold a handle to something you have not
started. It tears the connection down when it deinitialises.

## Probing

```swift
let info = try await ffmpeg.probe(sourceURL)

info.duration                        // TimeInterval?, seconds
info.videoStreams.first?.frameSize   // FrameSize?
info.videoStreams.first?.frameRate   // Double? — 29.97, parsed from "30000/1001"
info.audioStreams.first?.channels    // Int?
info.format?.formatLongName          // "QuickTime / MOV"
info.format?.tags["title"]
```

`MediaInfo.duration` falls back to the longest stream when the container declares none, which some
formats genuinely do not.

Streams also carry their colour tags, and know whether they are HDR:

```swift
let stream = info.videoStreams.first
stream?.colorSpace           // "bt2020nc"
stream?.colorTransfer        // "smpte2084" (PQ), "arib-std-b67" (HLG)
stream?.isHighDynamicRange   // Bool
stream?.colorProperties      // ready to hand to VideoSettings.colorProperties
```

Absent is not the same as Rec. 709 — it means the file never said, and ffmpeg will guess from the
resolution.

Ask for less, or more, with `ProbeOptions`:

```swift
try await ffmpeg.probe(url, options: ProbeOptions(showFormat: true,
                                                  showStreams: false,
                                                  showChapters: true))
```

**Chapters** arrive only when asked for — ffprobe does not report them otherwise, so
`info.chapters` is empty unless `showChapters` was set:

```swift
let info = try await ffmpeg.probe(url, options: ProbeOptions(showChapters: true))

for chapter in info.chapters {
    print(chapter.title ?? "untitled", chapter.start ?? 0, chapter.end ?? 0)
}
```

`Chapter.title` reads the `title` tag, which is where files conventionally put the name.

## Converting

The simple case, awaited to completion:

```swift
try await ffmpeg.convert(
    Conversion(from: source, to: destination,
               video: .h264(quality: 23, preset: .veryfast),
               audio: .aac())
) { progress in
    print(progress.fractionCompleted ?? 0)
}
```

`convert` probes the source first so progress can report a fraction. A source it cannot probe costs
you the fraction, not the conversion.

## Holding the job

`startConversion` returns immediately and gives you a handle. Use it when you need to follow the
job or cancel it:

```swift
let job = try ffmpeg.startConversion(conversion)

for await event in job.events {
    switch event {
    case .progress(let p):  update(p.fractionCompleted, p.framesPerSecond)
    case .log(let message) where message.isError: report(message.message)
    case .log:              break
    }
}

_ = try await job.value()
```

`events` and `value()` are both safe to use at once, and both safe to ignore — the job runs either
way. A stream created after the job has finished terminates immediately rather than hanging, and
several subscribers each see every event.

A `Progress` carries the frame count, rate, bitrate, bytes written, dropped and duplicated frames,
and how far into the output it has reached. Two of its values are computed rather than reported:

```swift
p.fractionCompleted        // 0...1, only when the total duration is known
p.estimatedTimeRemaining   // seconds, from what is left and how fast it is going
```

Both are `nil` rather than a guess when the duration is unknown — which it is unless the job came
from `convert`, since that probes the source first. The estimate is a projection from the current
speed, so it moves around early and settles; ffmpeg's speed over the first second of a file is not
what it will average over the rest.

`job.log` is everything FFmpeg said, kept whether or not anyone was listening, bounded to the last
500 lines.

### Cancelling

```swift
job.cancel()        // -> value() throws FFmpegError.cancelled
```

There is exactly one completion per job. Cancelling is one-way and idempotent; the outcome arrives
through `value()`. Cancelling the `Task` that awaits `value()` cancels the conversion too:

```swift
let task = Task { try await job.value() }
task.cancel()       // the conversion stops
```

Behind that, the service escalates SIGTERM → SIGTERM → SIGKILL, stopping short of the fourth signal
where FFmpeg's own handler calls `exit(123)`.

## Describing a conversion

```swift
Conversion(
    inputs: [Input(url: source, timeRange: .first(30))],
    outputs: [Output(url: destination,
                     container: .mp4,
                     video: VideoSettings(codec: .hevc, quality: 28,
                                          size: .hd1080, preset: .slow),
                     audio: .aac(.kbps(192)),
                     streamMaps: [.video(ofInput: 0), .audio(ofInput: 0)],
                     metadata: ["title": "Example"])],
    filterGraph: .scale(width: 1920, height: 1080)
)
```

Ready-made settings: `.h264()`, `.hevc()`, `.copy`, `.disabled` on `VideoSettings`; `.aac()`,
`.copy`, `.disabled` on `AudioSettings`. A `TimeRange` on an `Input` seeks before decoding; on an
`Output` it trims what is written.

Note there is no `none` codec case — `AudioSettings(codec: .none)` would bind to `Optional.none`
and silently mean "unset". Dropping a stream is `.disabled`.

**Filters** go through `filterGraph`, which is `-filter_complex`. FFmpegTask rejects `-vf`, `-af`
and `-filter`, since a complex graph expresses everything they do. A graph generally needs explicit
`streamMaps` to say what reaches the output.

**Containers.** `Output.container` when set, otherwise inferred from the destination's path
extension. An unrecognised extension throws `FFmpegError.indeterminateContainer` rather than
guessing — see [Architecture](Architecture.md) for why this cannot be left to FFmpeg.

## Controlling the encode

**Rate control.** `bitrate` or `quality`, never both — a rate wins if you set both. A ceiling needs
a window to mean anything, so `maxBitrate` and `bufferSize` are only emitted together:

```swift
VideoSettings.streaming(bitrate: .mbps(5))      // fills in the ceiling and window for you
VideoSettings(codec: .h264, bitrate: .mbps(5),
              maxBitrate: .mbps(6), bufferSize: .mbps(12),
              keyframeInterval: 48, profile: "high", level: "4.1", tune: "film")
```

Anything the encoder takes that this does not name goes in `encoderOptions`, emitted as
`-<name> <value>` in a stable order:

```swift
VideoSettings(codec: .h264, encoderOptions: ["x264-params": "keyint=50:min-keyint=50"])
```

**Two-pass** is a flag, not a workflow:

```swift
VideoSettings(codec: .h264, bitrate: .mbps(4), isTwoPass: true)
```

`convert` then runs ffmpeg twice, keeps the statistics between the runs, and reports one continuous
`fractionCompleted` across both. Only worth setting with a `bitrate` — there is nothing for a
second pass to do when the target is a quality.

**Faststart.** `Output(optimizeForStreaming: true)` moves the index to the front so a player can
start before it has the whole file. Set it for anything served over HTTP. Emitted only for MP4 and
MOV, where it means something.

**Colour.** Carried across, or set outright:

```swift
let source = try await ffmpeg.probe(url)
let video = VideoSettings(codec: .hevc, colorProperties: source.videoStreams.first?.colorProperties)
// or .rec709, .rec2020PQ, .rec2020HLG
```

Worth doing whenever the source is not plain Rec. 709. ffmpeg carries these tags through some paths
and drops them on others, and an HDR source transcoded without them comes out washed out with
nothing in the log to say why. `MediaInfo.Stream.isHighDynamicRange` says whether it matters.

## Hardware

Never automatic. A hardware encoder is much faster and much cheaper in power, and at a given
bitrate usually worse than x264 at anything but the fastest presets — which of those you want is
not something this package should decide. What it will do is tell you whether one exists:

```swift
let codec = await ffmpeg.hardwareEncoder(for: .hevc) ?? .hevc
let settings = codec.isHardwareAccelerated
    ? VideoSettings.hevcVideoToolbox(bitrate: .mbps(8))   // hardware takes a rate, not a CRF
    : VideoSettings.hevc(quality: 28)
```

`VideoSettings.h264VideoToolbox(bitrate:)` is the H.264 equivalent, and `VideoCodec` answers both
directions: `isHardwareAccelerated` for what you have, `softwareEquivalent` for what to fall back
to.

Decoding is opt-in the same way, per input:

```swift
Input(url: source, hardwareAcceleration: .videoToolbox)
```

Also not free: a format the engine cannot handle falls back to software silently, and filters that
need frames in main memory pull them back out again, which can cost more than it saved.

## Streams and subtitles

`Output.video` and `.audio` apply to every video and every audio stream. When they should not,
`streamOverrides` names particular ones — emitted after the blanket settings, so the more specific
wins, which is ffmpeg's own rule:

```swift
Output(url: destination, container: .matroska,
       audio: .aac(.kbps(160)),
       subtitles: SubtitleSettings(codec: .movText, language: "eng"),
       streamOverrides: [StreamOverride(.audio(1), .audio(.aac(.kbps(64))))])
```

Subtitles are `SubtitleSettings`: `.copy` to carry them across, `.movText` for MP4 (nothing else
survives that container), `.disabled` to drop them. Note that burning subtitles *into* the picture
needs libass, which this build does not include — see [Building](Building.md).

**Channel layout** is separate from channel count, and usually the more useful of the two —
`2` and `stereo` are the same count but not the same request:

```swift
AudioSettings(codec: .aac, channels: 6, channelLayout: .surround51)
```

`AudioChannelLayout` has `.mono`, `.stereo`, `.surround51`, `.surround71`, and takes a string
literal for anything else `channelLayouts()` lists.

**Loudness** normalises to a target:

```swift
AudioSettings(codec: .aac, loudness: .streaming)     // -16 LUFS; also .broadcastEBU, .broadcastATSC
```

`LoudnessNormalization` also has `.broadcastEBU` (-23 LUFS) and `.broadcastATSC` (-24), or set the
target, true-peak ceiling and range yourself.

`loudnorm` is a filter, so this composes the filter graph for you — which means it cannot be
combined with a `filterGraph` or `streamMaps` you wrote yourself. Asking for both throws
`FFmpegError.conflictingFilterGraph` with the filter string, so you can put it in your own graph
instead. Two-pass by default: in one pass `loudnorm` works from what it has heard so far, so the
start of a file is normalised against nothing.

## Joining, and stills

```swift
Conversion.joining([first, second, third], to: destination, container: .mp4)
Conversion.thumbnail(of: source, to: pngURL, at: 12.5)
Conversion.contactSheet(of: source, to: pngURL, columns: 4, rows: 4, interval: 10)
```

`joining` uses the concat *filter*, so everything is decoded and re-encoded. The concat demuxer
would copy streams through untouched, but it takes a list file naming its inputs by path — and a
path is what cannot reach ffmpeg here. The sources have to agree on what they contain: concat will
not join a clip that has a soundtrack to one that does not.

`contactSheet` writes one tiled image rather than a numbered sequence, for the same reason:
`frame%03d.png` needs a filename pattern to fill in, and an output reached through a descriptor has
no name.

Both are ordinary `Conversion`s underneath — a still is `Output.frameLimit` of 1 with
`Container.image` — so anything you can set on a conversion you can set on these.

## Remote inputs

```swift
Conversion(inputs: [.remote(URL(string: "https://example.com/stream.m3u8")!)],
           outputs: [Output(url: destination, container: .mp4)])
```

The one input that is not opened here. `Input.source` is an `InputSource` — `.file(url)`, which is
opened in your process and travels as a descriptor, or `.remote(url)`, where there is nothing to
open, so the URL goes to ffmpeg and the fetch happens inside the sandboxed helper instead.
`protocols()` says which schemes the build understands.

Worth being deliberate about: a remote input is fetched by the helper, under its sandbox, not
yours — no security-scoped grant is involved in either direction.

## Errors

```swift
do {
    try await ffmpeg.convert(conversion)
} catch let error as FFmpegError {
    switch error {
    case .cancelled:                    break
    case .failed(_, let log):           show(log.last { $0.isError }?.message)
    case .inaccessibleFile(let url, _): show("\(url.lastPathComponent) could not be opened")
    case .indeterminateContainer:       show("Set Output.container")
    case .serviceUnavailable:           show("The FFmpeg service is not installed")
    case .unexpectedResponse:           break
    }
}
```

`localizedDescription` prefers FFmpeg's own last error over a generic service message, so
`error.localizedDescription` is usually the right thing to show a user directly.

## Capabilities

What this FFmpeg build can do is a question, not a job. These take no files, report no progress and
answer from a single round trip:

```swift
let version = try await ffmpeg.version()          // FFmpegVersion
let license = try await ffmpeg.license()          // the FFmpeg build's own licence text
```

Everything a conversion can name has a query behind it:

| Query | Returns | Names what |
|---|---|---|
| `codecs()` | `[Codec]` | the codecs this build knows |
| `encoders()` | `[Coder]` | `VideoCodec.other` / `AudioCodec.other` |
| `decoders()` | `[Coder]` | what it can read |
| `formats()` `muxers()` `demuxers()` `devices()` | `[ContainerFormat]` | `Container` |
| `filters()` | `[Filter]` | a `FilterGraph` |
| `pixelFormats()` | `[PixelFormat]` | `VideoSettings.pixelFormat` |
| `sampleFormats()` | `[SampleFormat]` | `-sample_fmt` |
| `channelLayouts()` | `ChannelLayouts` | channel arrangements |
| `protocols()` | `Protocols` | URL schemes (see the caveat below) |
| `bitstreamFilters()` | `[String]` | `-bsf` |
| `colors()` | `[NamedColor]` | colours in filter arguments |

Each row is typed rather than a string: a `Codec` knows its `kind` (a `MediaKind` — video, audio or
subtitle) and whether it is lossy, lossless or intra-frame-only; a `Coder` knows its threading and
whether it is experimental; a `ContainerFormat` knows whether it muxes, demuxes or is a device.

The distinction that matters is `codecs()` against `encoders()`. A codec being listed does not mean
this build can write it — mp3 is decode-only unless FFmpeg was configured with LAME — so
`canEncode` is the question to ask before offering a format to a user:

```swift
let writable = try await ffmpeg.codecs().filter { $0.canEncode && $0.kind == .audio }
```

And when you want a specific implementation rather than a codec — hardware over software, say —
`encoders()` is what lists the names:

```swift
let encoders = try await ffmpeg.encoders()
let hardware = encoders.contains { $0.name == "hevc_videotoolbox" }
let settings = VideoSettings(codec: hardware ? .other("hevc_videotoolbox") : .hevc)
```

`protocols()` reports what FFmpeg was compiled with, which is more than this API can currently
reach: a `Conversion` opens every file in the client and passes a descriptor, so `http` appearing
in that list does not make a URL usable as an `Input`.

## The escape hatch

For anything the typed model does not cover, pass raw arguments. Every file the request touches
must be listed in `files` — that is how the service is given access to it:

```swift
let job = try ffmpeg.run(request: "-ffprobe",
                         arguments: ["-show_packets", "-i", url.path],
                         files: [url])
```

Raw options are also available at each level without leaving the typed API:
`Input.additionalOptions`, `VideoSettings.additionalOptions`, `AudioSettings.additionalOptions`,
`Output.additionalOptions`, `Conversion.additionalGlobalOptions`.

## Under the App Sandbox

Pass `URL`s and it is handled — the package opens the files, because it runs in the process holding
the user's grant.

One rule follows from how the sandbox works, and it catches people out:
`com.apple.security.files.user-selected.read-write` grants the file the user **picked**, not the
folder it sits in. Choosing an input does not license writing a sibling beside it. Offer the
destination through an `NSSavePanel`, or have the user select the enclosing folder.

See [Integrating](Integrating.md) for installation and [Architecture](Architecture.md) for why file
access works the way it does.
