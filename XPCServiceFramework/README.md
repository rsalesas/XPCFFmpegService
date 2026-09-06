# XPCServiceFramework

Generic XPC listener and proxy plumbing, with nothing FFmpeg-specific in it: a listener delegate for
service and anonymous connections, and a proxy that resolves against the current connection so it
survives a reconnect.

See **[docs/Architecture.md](../docs/Architecture.md)**.
