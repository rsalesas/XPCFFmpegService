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

Ask for less, or more, with `ProbeOptions`:

```swift
try await ffmpeg.probe(url, options: ProbeOptions(showFormat: true,
                                                  showStreams: false,
                                                  showChapters: true))
```

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

## Capabilities and the escape hatch

```swift
let version = try await ffmpeg.version()      // FFmpegVersion
```

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
