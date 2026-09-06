# FFmpegTask

The executable that actually links FFmpeg. One process per job: the XPC service spawns it, hands it
descriptors for the files it may touch, and reads framed JSON back off its pipes.

It is a wrapper around the `ffmpeg` and `ffprobe` entry points rather than a copy of them — it links
`libav*` and compiles `fftools/*.c` directly, then intercepts the stdio those tools write to and
converts their human-readable output into JSON.

It is **not runnable from a shell as built**: it carries `com.apple.security.inherit`, which needs a
sandboxed parent, so it dies with SIGTRAP if you launch it directly. To try it by hand, copy it and
re-sign without entitlements:

```bash
cp "$BUILT_PRODUCTS_DIR/FFmpegTask" /tmp/FFmpegTask && codesign -f -s - /tmp/FFmpegTask
/tmp/FFmpegTask -ffprobe -show_format -i clip.mp4
```

Build instructions, prerequisites and what the FFmpeg build phase does are in
**[docs/Building.md](../docs/Building.md)**. The output parsers and how they are guarded against
FFmpeg changing its formatting are in **[docs/Testing.md](../docs/Testing.md)**.


## Licensing — and why FFmpeg lives in its own process

This is the reason FFmpegTask is a separate executable rather than a library linked into the
service or the app. The process boundary is a licensing boundary, and it was chosen deliberately.

### Source and binary are licensed differently

The source in this directory is **MIT**, like the rest of the repository — see `LICENSE`. Most of
it never touches FFmpeg at all: `OutputHandlers.swift`, `PipeConnector.swift`,
`MatchRegularExpression.swift` and `main.swift` compile with no FFmpeg present, which is exactly
what `FFmpegTaskTests` does on every run. Only `FFmpegTask.swift` and `bridging.h` reach for it.

The **built binary** is a different matter. It statically links FFmpeg, x264 and x265, so it is a
combined work and is **GPL v3**. Ask it yourself:

```
$ FFmpegTask -license
FFmpegTask is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.
```

MIT is GPL-compatible, so there is no conflict in that: permissive sources combined with GPL
libraries produce a GPL work. It does mean the licence you ship under is decided by what you link,
not by what is written here — and that building against an LGPL FFmpeg instead produces a binary
with no GPL obligations at all.

### The position

**The GPL code is confined to this one executable.** Nothing else in the project contains a byte of
it. That is not an assertion about intent, it is a property of the build you can check on the
binaries:

| binary | FFmpeg / x264 / x265 symbols |
|---|---|
| your app | 0 |
| `XPCFFmpegService.xpc` | 0 |
| `XPCFFmpeg.framework` | 0 |
| `FFmpegTask` | 3,317 |

```bash
nm -U YourApp.app/Contents/MacOS/YourApp | grep -cE '_av_|_avcodec_|_x264_|_x265_'   # 0
```

An app talks to FFmpegTask at arm's length, and only ever at arm's length: an XPC message reaches
the service, which spawns FFmpegTask as a child with a command line and a set of file descriptors,
and reads back length-prefixed JSON. No shared address space, no shared data structures, no
FFmpeg headers or types anywhere in the client. The interface is the same one you would get from a
shell script driving the `ffmpeg` binary.

That is the distinction the GPL itself turns on. The FSF's own account of where one program ends
and another begins puts the line at the address space: modules in one executable, or designed to
run linked together, are one program; pipes, sockets and command-line arguments are "communication
mechanisms normally used between two separate programs". This project is squarely on the second
side of that line, and it is built that way on purpose.

**So an application that uses this service does not have to publish its own source.** It ships a
GPL program alongside a proprietary one, which is the ordinary case of shipping any GPL tool with
your software.

### What you must still do

Being on the right side of that line does not make the GPL go away for FFmpegTask itself. If you
ship the `.xpc` inside your app, you are distributing GPL software. In practice that comes to very
little here:

- **Source availability is already satisfied** — this repository is public, and it is the corresponding
  source: the FFmpeg revision, its configure flags, and every modification. Linking to it is enough.
  Worth tagging what you shipped, only so you can answer *which* revision later.
- **Licence and copyright notices must be preserved.** Do not strip them from the bundle.
- **The GPL text must accompany the distribution.**
- x264 and x265 carry their own GPL terms; they are inside this binary too.

GPL **v3** specifically does not add anything here. Its Installation Information conditions apply to
"User Products" — GPL software conveyed *as part of* hardware whose possession transfers to the
buyer, the router-and-television case the anti-tivoisation clause was written for. An app installed
on a Mac the user already owns is not that transaction, so the clause is not engaged. v3 versus v2
makes no practical difference to shipping this.

### One thing for the apps that use this, not for this

Everything above is about FFmpegTask and this repository: GPL, public, source available. Settled,
with nothing left to weigh.

What remains is a question for **an application that ships the service**, and it is that
application's to answer: understand the licence you are redistributing under and how it sits with
the way you distribute. Shipping direct or notarised, it does not arise. Through an App Store it is
the contested case — Apple does not review licence compliance and many apps ship FFmpeg, but store
terms and the GPL are a poor fit, and enforcement when it comes is a copyright holder complaining
rather than a review failing. VLC was pulled that way in 2011 and returned in 2013 only after
relicensing off the GPL.

None of that is a reason to avoid this service. It is a reason to make the choice deliberately, and
to know that the LGPL build below removes the question entirely.

### What would undo it

The separation is only worth what the boundary is worth. It stops holding if you:

- link `libav*`, x264 or x265 into your app or into the XPC service;
- copy FFmpeg headers, structs or types into the client;
- make the interface intimate rather than arm's-length — the same FSF account notes that
  communication "exchanging complex internal data structures" can be a basis for treating two parts
  as one program, no matter how many processes they run in.

The current design keeps all three of those true by construction, which is why the client speaks in
`Conversion` values and descriptors and never sees an `AVFormatContext`.

### If you would rather not ship GPL at all

Drop `--enable-gpl`, `--enable-version3`, `--enable-libx264` and `--enable-libx265` from the
*Make FFmpeg* phase in [docs/Building.md](../docs/Building.md). FFmpeg then builds under the LGPL,
and you use the VideoToolbox encoders for H.264 and HEVC instead of x264/x265 — which on Apple
silicon is often the better choice anyway. Static LGPL linking has its own relinking obligation, so
that route is a different trade rather than a free one.

### The usual caveat, stated once

This section explains the reasoning behind the project's structure. It is not legal advice, and the
IPC boundary — while long relied upon and consistent with the FSF's own description of it — has not
been settled by a court. If you are shipping commercially, have counsel confirm it against how you
actually distribute.
