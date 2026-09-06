# XPCFFmpeg

The package an app links. FFmpeg as Swift values — no `NSXPCConnection`, no listener endpoints, no
job IDs, no descriptors.

```swift
import XPCFFmpeg

let ffmpeg = FFmpeg()

let info = try await ffmpeg.probe(sourceURL)

try await ffmpeg.convert(
    Conversion(from: sourceURL, to: destinationURL,
               video: .h264(quality: 23, preset: .veryfast),
               audio: .aac())
) { progress in
    print(progress.fractionCompleted ?? 0)
}

// Or hold the job, to follow it and cancel it
let job = try ffmpeg.startConversion(conversion)
for await event in job.events { ... }
job.cancel()
```

Full documentation lives in [`docs/`](../docs/README.md):

- **[Usage](../docs/Usage.md)** — the API in detail
- **[Integrating](../docs/Integrating.md)** — adding it to an app, including the Copy Files phase
  the package cannot do for you, and how file access works under the App Sandbox
- **[Architecture](../docs/Architecture.md)** — why the work happens in another process, and why
  files travel as descriptors

Two things worth knowing before you start:

**Installing needs two steps.** The package gives you the API; `XPCFFmpegService.xpc` has to be
copied into your app's `Contents/XPCServices/` by an Xcode build phase. Without it every call fails
with `FFmpegError.serviceUnavailable`.

**A destination needs its own sandbox grant.** `files.user-selected.read-write` covers the file the
user picked, not the folder it sits in, so you cannot derive an output path from an input. Offer the
destination through an `NSSavePanel`.
