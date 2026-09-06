# Integrating XPCFFmpeg into an app

Two steps, because a Swift package cannot carry the service.

## 1. The API

Add the package:

```swift
.package(path: "../XPCFFmpeg")
```

or drag `XPCFFmpeg` into your Xcode project as a local package. It brings
`XPCFFmpegServiceFramework` and `XPCServiceFramework` with it.

## 2. The service

`XPCFFmpegService.xpc` — which itself embeds `FFmpegTask` — has to end up in your app at
`Contents/XPCServices/`. SwiftPM has no build phase that can put it there, so add an Xcode **Copy
Files** phase with destination *XPC Services* and drop the built `.xpc` in.

Build the `XPCFFmpegService` target of this project to produce it.

Without this step every call fails with `FFmpegError.serviceUnavailable`: the API is present and
nothing is behind it.

## Service name

`FFmpeg()` looks for `com.siliconink.XPCFFmpegService`. If you rebrand the service, pass the new
identifier:

```swift
let ffmpeg = FFmpeg(serviceName: "com.example.MyFFmpegService")
```

## Entitlements

The service and FFmpegTask ship sandboxed, and should stay that way — a helper that is not
sandboxed would let a sandboxed app reach files it could not otherwise, which is a sandbox escape
and will not survive App Review.

| Component | Entitlements |
|---|---|
| Your app | `app-sandbox`, plus whatever grants your file picking needs — typically `files.user-selected.read-write` |
| `XPCFFmpegService.xpc` | `app-sandbox` |
| `FFmpegTask` | `app-sandbox`, `inherit` |

Your app needs no special entitlement for the *service* to reach files: it opens them itself and
passes descriptors, so its own grant is the only one involved. See
[Architecture](Architecture.md#file-access-descriptors-not-paths).

## Getting file access right

The rule that catches people out:
`com.apple.security.files.user-selected.read-write` grants the file the user **picked**, not the
folder it sits in.

```swift
// Works: the user picked this file.
let info = try await ffmpeg.probe(pickedURL)

// Fails: nothing granted this destination.
let out = pickedURL.deletingLastPathComponent().appendingPathComponent("out.mp4")
try await ffmpeg.convert(Conversion(from: pickedURL, to: out))   // .inaccessibleFile
```

Offer the destination through an `NSSavePanel`, or have the user select the enclosing folder. This
is real sandbox behaviour, not a limitation of the package — and it is why `Output` takes a URL you
have a grant for rather than deriving one.

## Licensing

The source of this project is **MIT** (`LICENSE`). What you link decides what you ship under:

- **A built `FFmpegTask` is GPL v3** — it statically links FFmpeg, x264 and x265. Shipping the
  `.xpc` inside your app means redistributing it, so preserve its notices, include the licence text,
  and point at this repository as the corresponding source.
- **Nothing else contains FFmpeg code.** Your app, the XPC service and `XPCFFmpeg.framework` have
  zero FFmpeg symbols. That separation is why **an app using this service does not have to publish
  its own source**.
- **Building FFmpeg under the LGPL removes the GPL entirely** — drop `--enable-gpl`,
  `--enable-version3`, `--enable-libx264` and `--enable-libx265` and use the VideoToolbox encoders.
  The MIT sources are unchanged; only what they link against is.

What is left is yours rather than the service's: understand the licence you are redistributing under
and how it sits with your distribution channel. Direct or notarised, it does not arise. Through an
App Store, a GPL build with x264/x265 is the contested case — common in practice, never checked at
review, enforced only if a copyright holder complains.

See `NOTICE`, and
[FFmpegTask/README.md](../FFmpegTask/README.md#licensing--and-why-ffmpeg-lives-in-its-own-process)
for the full reasoning.
