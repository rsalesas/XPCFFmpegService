# Architecture

Three processes:

```
your app ──XPC──▶ XPCFFmpegService ──spawn──▶ FFmpegTask
 (XPCFFmpeg)       one per app,               one per job,
                   long-lived                 links FFmpeg
```

## Why a separate process per job

FFmpeg is a library here, not a subprocess of convenience, so the isolation has to be justified.
Three reasons, all still true of FFmpeg 9:

**Concurrency.** `fftools/ffmpeg.c` keeps its state in file-scope globals — `input_files`,
`output_files`, `filtergraphs`, `decoders` and friends. Two conversions cannot share a process.
FFmpegTask layers more process-wide state on top: it `dup2`s the process's own stdout and stderr
onto pipes to intercept them.

**Cancellation.** FFmpeg offers no way to stop a transcode from another thread.
`decode_interrupt_cb` reads a flag only the signal handler sets, so cancelling means signalling —
which is process-wide. A job you can abandon has to be a process you can signal.

**Crash isolation.** `ffprobe.c` still calls `exit(1)` outright on some failures, and a codec fault
on a malformed file takes down whatever process it is in. One job per process means one job dies.

Worth noting what changed: in FFmpeg 4.2, `exit_program()` was called from everywhere and made the
"it takes the whole process down" argument overwhelming. FFmpeg 9 deleted it —`ffmpeg`'s `main()`
now returns an int cleanly. The concurrency and cancellation arguments are what carry the design
today.

## File access: descriptors, not paths

This is the part that is easy to get wrong, and the reason is structural.

A sandbox extension — what a security-scoped bookmark carries — is a **right that must be exercised
by whoever opens the file**. It can cross one process hop. There are two here, and FFmpegTask, the
process that actually calls `open()`, is the furthest away.

Measured rather than assumed:

- A plain bookmark resolves to the right path and grants nothing.
- A security-scoped bookmark **cannot even be resolved** by FFmpegTask — it is keyed to the
  creating app's container identity, and FFmpegTask runs under the service's. This held after
  signing all three with one Developer ID so they shared a team.
- Resolving and consuming one in the *service* is worse than useless: it grants the service access
  the child never sees, while removing the ambient access the child had.

So the client opens the files — it is the process holding the grant — and the **descriptors** travel
over XPC. A descriptor is access already exercised, so it goes as far as it is passed. Neither the
service nor FFmpegTask ever reaches a file by name.

FFmpeg is told to use them through its own protocol: `-fd N -i fd:` for an input, `-f mp4 -fd N fd:`
for an output. Two consequences:

1. **The muxer must be explicit.** `fd:` has no filename, so FFmpeg cannot infer the container from
   an extension. `XPCFFmpeg` supplies `-f` from `Output.container`, or from the destination's path
   extension, and refuses rather than guessing when neither says.
2. **`Process` could not be used.** Foundation's `Process` maps only stdin, stdout and stderr, and
   closes every other descriptor across the exec regardless of `FD_CLOEXEC` — verified by reading
   fd 3 in a child and getting `EBADF`. `ChildProcess` spawns with `posix_spawn_file_actions`
   instead, and resets signal dispositions with `SETSIGDEF`/`SETSIGMASK`, without which the child
   inherits the service's and a cancel's SIGTERM lands on `SIG_IGN`.

## The pipe between the service and FFmpegTask

Length-prefixed records: four bytes big-endian, then that many bytes. The payload is opaque.

It used to recover boundaries by counting braces and tracking quote and escape state, which
re-derives something the writer already knew and only works when the payload looks like JSON. The
encoding is still JSON — ffprobe emits it natively, and a progress record measures 177 bytes as JSON
against 243 as a binary plist — so the win was the framing, not the format.

Writes go out under a lock. stderr carries two producers, status lines and progress records, on one
descriptor; a frame torn across two interleaved writes would desynchronise the reader permanently,
where the old scanner could at least resynchronise on the next brace.

## The layers

| Package / target | Role |
|---|---|
| `XPCFFmpeg` | What an app links. Typed conversions, jobs, events, errors. Opens files. |
| `XPCFFmpegServiceFramework` | Shared protocol types both sides need — `FFmpegRequest`, `ServiceError`, progress and status. |
| `XPCServiceFramework` | Generic XPC listener/proxy plumbing, not FFmpeg-specific. |
| `XPCFFmpegService` | The service. Maps descriptors into the child, owns the job registry, one reply per job. |
| `FFmpegTask` | Links FFmpeg. Intercepts its stdio, parses its output into JSON. |

`Support/` holds the pieces compiled into more than one target — the mutex, the pipe framing, the
JSON checks.

## Reading FFmpeg's output

FFmpeg's list output (`-codecs`, `-formats`, `-filters` …) is human-formatted text. FFmpegTask
parses it with regular expressions into JSON. That is the most fragile thing in the project: three
of those parsers had silently drifted against FFmpeg 9 before a test suite existed for them, two
producing nothing at all and one dropping every device row while looking healthy.

[Testing](Testing.md) covers how that is now guarded.
