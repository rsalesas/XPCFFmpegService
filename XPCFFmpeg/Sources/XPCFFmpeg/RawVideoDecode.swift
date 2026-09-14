//
//  RawVideoDecode.swift
//  XPCFFmpeg
//
//  A bounded, zero-copy path from FFmpeg's decoder to a native video pipeline.
//

import Foundation

/// The video stream and frame layout for a raw RGB decode.
///
/// `streamIndex` is the global stream index reported by ``MediaInfo.Stream/index``. Frames are
/// emitted as tightly packed RGB24 records, one after another, on ``RawVideoDecode/reader``.
public struct RawVideoDecodeOptions: Sendable {
    public let streamIndex: Int
    public let frameSize: FrameSize
    public let frameRate: Double

    public init(streamIndex: Int, frameSize: FrameSize, frameRate: Double) {
        precondition(streamIndex >= 0, "A stream index cannot be negative")
        precondition(frameSize.width > 0 && frameSize.height > 0, "Frame dimensions must be positive")
        precondition(frameRate > 0 && frameRate.isFinite, "Frame rate must be finite and positive")

        self.streamIndex = streamIndex
        self.frameSize = frameSize
        self.frameRate = frameRate
    }

    /// Bytes in one complete frame read from ``RawVideoDecode/reader``.
    public var bytesPerFrame: Int { frameSize.width * frameSize.height * 3 }
}

/// A running FFmpeg decode that writes fixed-size RGB24 frames to a pipe.
///
/// Keep this value alive while draining ``reader``. Draining the pipe concurrently with
/// ``wait()`` prevents FFmpeg from blocking once the kernel's pipe buffer is full.
public final class RawVideoDecode {
    public let options: RawVideoDecodeOptions
    public let reader: FileHandle
    public let job: Job

    init(options: RawVideoDecodeOptions, reader: FileHandle, job: Job) {
        self.options = options
        self.reader = reader
        self.job = job
    }

    /// Cancels the decode. The pending ``wait()`` then throws `FFmpegError.cancelled`.
    public func cancel() { job.cancel() }

    /// Waits until FFmpeg closes the pipe and completes the decode.
    public func wait() async throws { _ = try await job.value() }
}
