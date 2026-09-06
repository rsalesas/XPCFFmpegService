# XPCFFmpegService

## An FFmpeg XPC Service for macOS

FFmpeg for sandboxed macOS apps: a Swift package you link, an XPC service behind it, and FFmpeg
itself in a separate process per job so a conversion can be cancelled and a crash on a malformed
file takes nothing with it.

```swift
import XPCFFmpeg

let ffmpeg = FFmpeg()
let info = try await ffmpeg.probe(url)
try await ffmpeg.convert(Conversion(from: source, to: destination, video: .h264()))
```

**[Documentation is in `docs/`](docs/README.md)** — [Usage](docs/Usage.md),
[Integrating](docs/Integrating.md), [Building](docs/Building.md),
[Architecture](docs/Architecture.md), [Testing](docs/Testing.md).

## Building, briefly

```bash
git submodule update --init
brew install nasm pkg-config x264 x265
xcodebuild -project XPCFFmpegService.xcodeproj -scheme TestXPCFFmpegService -configuration Debug
```

The first build compiles FFmpeg from source and takes a few minutes. See
[Building](docs/Building.md) for what that phase does and the pitfalls it has.

## Layout

| | |
|---|---|
| `XPCFFmpeg/` | The package an app links — the whole public API. |
| `XPCFFmpegService/` | The XPC service. Spawns FFmpegTask per job. |
| `FFmpegTask/` | The executable that links FFmpeg and FFprobe. |
| `XPCFFmpegServiceFramework/` | Protocol types shared by both sides of the connection. |
| `XPCServiceFramework/` | Generic XPC listener and proxy plumbing. |
| `TestXPCFFmpegService/` | Sample app, and the target that builds the whole stack. |
| `Scripts/` | Coverage gate, FFmpeg fixture regeneration, end-to-end checks. |
| `EndToEndTests/` | Harnesses that drive the real service and FFmpegTask. |

## Licensing

This project's source is **MIT** — see [LICENSE](LICENSE). A built `FFmpegTask` binary statically
links FFmpeg, x264 and x265 and is therefore GPL v3; nothing else in the project contains FFmpeg
code. Keeping FFmpeg in its own process is what makes that true, and means an app using this service
does not have to publish its own source. See [NOTICE](NOTICE) for the boundary, and
[FFmpegTask/README.md](FFmpegTask/README.md#licensing--and-why-ffmpeg-lives-in-its-own-process) for
the reasoning.
