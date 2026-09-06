//
//  Options.swift
//  XPCFFmpeg
//
//  The typed vocabulary a conversion is described in. Every one of these has an `other`/raw case
//  so that an option this package does not know about is inconvenient rather than impossible.
//

import Foundation


public enum VideoCodec: Equatable {
    case h264
    case hevc
    case proRes
    /// Remux the stream without re-encoding it.
    case copy
    case other(String)

    var argument: String {
        switch self {
        case .h264:           return "libx264"
        case .hevc:           return "libx265"
        case .proRes:         return "prores_videotoolbox"
        case .copy:           return "copy"
        case .other(let s):   return s
        }
    }
}

/// Note the absence of a `none` case on either codec: a parameter of type `AudioCodec?` would make
/// `AudioSettings(codec: .none)` mean nil rather than "drop the audio", and the compiler only
/// warns about it. Dropping a stream is `VideoSettings.disabled` / `AudioSettings.disabled`.
public enum AudioCodec: Equatable {
    case aac
    case alac
    case flac
    case copy
    case other(String)

    var argument: String {
        switch self {
        case .aac:            return "aac"
        case .alac:           return "alac"
        case .flac:           return "flac"
        case .copy:           return "copy"
        case .other(let s):   return s
        }
    }
}

public enum Container: Equatable {
    case mp4
    case mov
    case matroska
    case m4a
    case wav
    case other(String)

    var argument: String {
        switch self {
        case .mp4:            return "mp4"
        case .mov:            return "mov"
        case .matroska:       return "matroska"
        case .m4a:            return "ipod"
        case .wav:            return "wav"
        case .other(let s):   return s
        }
    }
}

/// x264/x265 speed-vs-size tradeoff.
public enum EncoderPreset: String {
    case ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow
}

public struct Bitrate: Equatable {
    public let bitsPerSecond: Int

    public init(bitsPerSecond: Int) { self.bitsPerSecond = bitsPerSecond }
    public static func kbps(_ k: Int) -> Bitrate { Bitrate(bitsPerSecond: k * 1000) }
    public static func mbps(_ m: Double) -> Bitrate { Bitrate(bitsPerSecond: Int(m * 1_000_000)) }

    var argument: String { "\(bitsPerSecond)" }
}

public struct FrameSize: Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) { self.width = width; self.height = height }

    public static let hd720 = FrameSize(width: 1280, height: 720)
    public static let hd1080 = FrameSize(width: 1920, height: 1080)
    public static let uhd4K = FrameSize(width: 3840, height: 2160)

    var argument: String { "\(width)x\(height)" }
}

/// A start offset and/or a duration. Applied to whichever side it is set on: on an Input it seeks
/// before decoding, on an Output it trims what is written.
public struct TimeRange: Equatable {
    public var start: TimeInterval?
    public var duration: TimeInterval?

    public init(start: TimeInterval? = nil, duration: TimeInterval? = nil) {
        self.start = start
        self.duration = duration
    }

    public static func from(_ start: TimeInterval) -> TimeRange { TimeRange(start: start) }
    public static func first(_ duration: TimeInterval) -> TimeRange { TimeRange(duration: duration) }
}

/// Which streams of which input end up in an output. Maps to ffmpeg's -map.
public enum StreamMap: Equatable {
    case allStreams(ofInput: Int)
    case video(ofInput: Int, index: Int? = nil)
    case audio(ofInput: Int, index: Int? = nil)
    case subtitles(ofInput: Int, index: Int? = nil)
    /// A raw -map specifier, for anything the cases above cannot say.
    case specifier(String)

    var argument: String {
        func spec(_ input: Int, _ kind: String, _ index: Int?) -> String {
            return index.map { "\(input):\(kind):\($0)" } ?? "\(input):\(kind)"
        }

        switch self {
        case .allStreams(let i):            return "\(i)"
        case .video(let i, let n):          return spec(i, "v", n)
        case .audio(let i, let n):          return spec(i, "a", n)
        case .subtitles(let i, let n):      return spec(i, "s", n)
        case .specifier(let s):             return s
        }
    }
}
