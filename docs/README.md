# Documentation

FFmpeg for sandboxed macOS apps, as a Swift package with an XPC service behind it.

```swift
let ffmpeg = FFmpeg()
let info = try await ffmpeg.probe(url)
try await ffmpeg.convert(Conversion(from: source, to: destination, video: .h264()))
```

| | |
|---|---|
| **[Usage](Usage.md)** | The Swift API — probing, converting, jobs, progress, cancellation, errors. |
| **[Integrating](Integrating.md)** | Adding it to an app: the package, the Copy Files phase, entitlements, licensing. |
| **[Building](Building.md)** | Prerequisites, targets, what the FFmpeg build phase does, known pitfalls. |
| **[Architecture](Architecture.md)** | Why three processes, how file access crosses them, the pipe protocol. |
| **[Testing](Testing.md)** | The four suites, the coverage gate, and guarding against FFmpeg output drift. |
| **[Review](Review.md)** | A full code review: confirmed bugs, design concerns, hygiene, and what to fix first. |

## The shape of it

```
your app ──XPC──▶ XPCFFmpegService ──spawn──▶ FFmpegTask
 (XPCFFmpeg)       one per app                one per job, links FFmpeg
```

A job runs in its own process so it can be cancelled, so a crash on a malformed file takes nothing
with it, and because FFmpeg's command-line layer keeps its state in globals and cannot run two
conversions at once.

Files reach FFmpeg as **open descriptors**, not paths. Your app holds the user's grant, so your app
opens the file; a descriptor is access already exercised, and it survives both process hops where a
bookmark survives neither. That is what makes this work under the App Sandbox.

## If you are picking this up cold

Read [Usage](Usage.md) if you want to call it, [Architecture](Architecture.md) if you want to know
why it is built this way. [Building](Building.md) is worth a skim first either way — the first build
compiles all of FFmpeg and takes a few minutes.

Current: FFmpeg **n9.0.1**, macOS **11.0** and later.
