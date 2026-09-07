# Building

The project builds FFmpeg from source as part of the Xcode build. The first build is slow — several
minutes — because it configures and compiles all of FFmpeg. Later builds reuse that work.

## Prerequisites

Xcode and its command line tools, plus four Homebrew packages. The build refuses to start with a
message naming whichever is missing, so you do not have to get this right in advance:

```bash
brew install nasm pkg-config x264 x265 lame libvpx opus libogg libvorbis aom libvmaf
```

The FFmpeg submodule must be present:

```bash
git submodule update --init
```

Homebrew's prefix differs between Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`). The
build asks `brew --prefix` rather than assuming, so both work.

## Building

```bash
xcodebuild -project XPCFFmpegService.xcodeproj -scheme TestXPCFFmpegService -configuration Debug
```

That scheme is the one to use day to day: it builds everything, because the app embeds the XPC
service, which embeds FFmpegTask.

| Target | What it is |
|---|---|
| `FFmpegTask` | The executable that actually links FFmpeg. Built first, embedded in the service. |
| `XPCFFmpegService` | The XPC service. Spawns FFmpegTask per job. |
| `TestXPCFFmpegService` | The sample app, and the only target that builds the whole stack. |
| `XPCFFmpegServiceTests` | Unit tests for the service. |
| `FFmpegTaskTests` | Unit tests for FFmpegTask's output parsers. Links no FFmpeg. |

There are also SwiftPM schemes for the three packages — `XPCFFmpeg`, `XPCFFmpegServiceFramework`,
`XPCServiceFramework` — which build without touching FFmpeg at all.

## What the FFmpeg build phase does

`FFmpegTask` carries a *Make FFmpeg* shell phase that runs before compilation. It checks the
prerequisites, copies each codec library's static archive out of Homebrew into `lib/`, then
configures and builds FFmpeg with:

```
--disable-shared --enable-static --enable-pthreads --enable-gpl --enable-version3
--enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libvpx
--enable-libopus --enable-libvorbis --enable-libaom
--disable-programs --disable-doc --disable-sdl2 --disable-xlib --disable-libxcb
```

The codec libraries are listed once, in `CODEC_LIBRARIES` at the top of that phase, as
`formula:archive` pairs. Adding one means three edits, not one: the pair goes in that list, the
`--enable-` flag goes in the configure line, and `-l<name>` goes in `OTHER_LDFLAGS` on the
`FFmpegTask` target so the final link can resolve it. It also belongs in `NOTICE`, since what you
may ship is decided by what you link.

Two details in that phase are worth knowing about if you change it. Not every formula ships a
pkg-config file — `lame` does not — so the phase passes each prefix to configure as `-I` and `-L`
in addition to building `PKG_CONFIG_PATH`. And `configure` and `make` are checked explicitly: a
failing configure used to be ignored, which meant the phase quietly rebuilt against whatever
configuration was left over from the previous run and reported success.

`--disable-programs` matters: no `ffmpeg` or `ffprobe` binary is produced. FFmpegTask links the
libraries and compiles `fftools/*.c` directly, which is why the header search path points at the
FFmpeg source tree rather than at `include/` — several fftools sources reach for internal headers
that `make install` does not export.

The phase also regenerates two C files that FFmpeg's own Makefile would normally produce with its
`bin2c` tool (`generated/graph_html.c`, `generated/graph_css.c`), since this target bypasses that
Makefile.

Everything it produces — `lib/`, `include/`, `generated/`, `Frameworks/` — is ignored by git and
rebuilt on demand.

## Current versions

FFmpeg **n9.0.1**, deployment target **macOS 11.0**, Swift 5 language mode.

## Things that have bitten before

**Metal.framework must stay linked to FFmpegTask.** FFmpeg 9's `vf_yadif_videotoolbox` calls
`MTLCreateSystemDefaultDevice`. Nothing referenced it before FFmpeg was rebuilt, so its absence
only showed up as a link failure once `libavfilter.a` was regenerated — which every clean clone
does.

**A clean clone rebuilds FFmpeg.** If you want to be sure the tree really builds from nothing:

```bash
rm -rf lib include generated Frameworks
xcodebuild -project XPCFFmpegService.xcodeproj -scheme TestXPCFFmpegService -configuration Debug
```

**Sandbox entitlements are not optional for running FFmpegTask by hand.** It carries
`com.apple.security.inherit`, which requires a sandboxed parent; run it straight from a shell and
it dies with SIGTRAP. To use it standalone, copy it and re-sign without entitlements:

```bash
cp "$BUILT_PRODUCTS_DIR/FFmpegTask" /tmp/FFmpegTask && codesign -f -s - /tmp/FFmpegTask
/tmp/FFmpegTask -ffprobe -show_format -i /path/to/clip.mp4
```
