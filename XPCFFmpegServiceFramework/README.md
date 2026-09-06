# XPCFFmpegServiceFramework

The types both ends of the XPC connection have to agree on: the `XPCFFmpegInvokeProtocol` and
`XPCFFmpegStatusProtocol` interfaces, `FFmpegRequest`, `ServiceError`, and the progress, status and
version objects that cross the wire.

It is shared plumbing, not the API you call — apps link [`XPCFFmpeg`](../XPCFFmpeg) instead. See
**[docs/Architecture.md](../docs/Architecture.md)**.
