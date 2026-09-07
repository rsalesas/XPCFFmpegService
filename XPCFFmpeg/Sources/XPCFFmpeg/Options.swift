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
    /// H.264 on the media engine rather than the CPU.
    ///
    /// Separate cases rather than a flag on `.h264`, because nothing here should quietly pick one
    /// for you: hardware encoding is much faster and much cheaper in power, and at a given bitrate
    /// it is usually worse than x264 at anything but the fastest presets. Which of those matters
    /// is the caller's judgement, not this package's. `FFmpeg.hardwareEncoder(for:)` will tell you
    /// whether the build has one before you ask for it.
    case h264VideoToolbox
    case hevcVideoToolbox
    /// Still images, for thumbnails and contact sheets.
    case png
    case mjpeg
    /// Remux the stream without re-encoding it.
    case copy
    case other(String)

    var argument: String {
        switch self {
        case .h264:               return "libx264"
        case .hevc:               return "libx265"
        case .proRes:             return "prores_videotoolbox"
        case .h264VideoToolbox:   return "h264_videotoolbox"
        case .hevcVideoToolbox:   return "hevc_videotoolbox"
        case .png:                return "png"
        case .mjpeg:              return "mjpeg"
        case .copy:               return "copy"
        case .other(let s):       return s
        }
    }

    /// Whether this runs on the media engine. `-crf` and `-preset` mean nothing to those, which is
    /// why a hardware encoder needs a bitrate.
    public var isHardwareAccelerated: Bool {
        switch self {
        case .proRes, .h264VideoToolbox, .hevcVideoToolbox:
            return true
        case .other(let name):
            return name.hasSuffix("_videotoolbox")
        case .h264, .hevc, .png, .mjpeg, .copy:
            return false
        }
    }

    /// The software encoder for the same format, if this is a hardware one.
    public var softwareEquivalent: VideoCodec? {
        switch self {
        case .h264VideoToolbox:   return .h264
        case .hevcVideoToolbox:   return .hevc
        default:                  return nil
        }
    }
}


/// Subtitle handling for an output. Text and bitmap subtitles are not interchangeable: `mov_text`
/// and `webvtt` carry text, `dvdsub` carries images, and converting between them is not something
/// ffmpeg will do.
public enum SubtitleCodec: Equatable {
    /// The MP4/MOV text format - what an .mp4 with subtitles almost always holds.
    case movText
    case subrip
    case webVTT
    case ass
    case copy
    case other(String)

    var argument: String {
        switch self {
        case .movText:        return "mov_text"
        case .subrip:         return "subrip"
        case .webVTT:         return "webvtt"
        case .ass:            return "ass"
        case .copy:           return "copy"
        case .other(let s):   return s
        }
    }
}


/// Decoding on the media engine instead of the CPU.
///
/// Opt-in, like the hardware encoders. It is a large saving on long transcodes and it is not free:
/// a format the engine cannot handle falls back to software silently, and filters that need frames
/// in main memory force them back out again, which can cost more than it saved.
public enum HardwareAcceleration: Equatable {
    case videoToolbox
    case other(String)

    var argument: String {
        switch self {
        case .videoToolbox:   return "videotoolbox"
        case .other(let s):   return s
        }
    }
}


/// How the channels of an audio stream are arranged. `AudioSettings.channels` sets how many;
/// this says which. Ask `FFmpeg.channelLayouts()` for what the build accepts.
public struct AudioChannelLayout: Equatable, ExpressibleByStringLiteral {
    public let name: String

    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: String) { self.name = value }

    public static let mono = AudioChannelLayout("mono")
    public static let stereo = AudioChannelLayout("stereo")
    public static let surround51 = AudioChannelLayout("5.1")
    public static let surround71 = AudioChannelLayout("7.1")

    var argument: String { name }
}


/// The colour a stream is to be interpreted in.
///
/// Worth setting explicitly whenever the source is not plain Rec. 709. ffmpeg carries these tags
/// through some paths and drops them on others, and the failure is quiet: an HDR source transcoded
/// without them arrives washed out or over-saturated with nothing in the log to say why.
public struct ColorProperties: Equatable {
    public var space: String?
    public var primaries: String?
    /// The transfer characteristic - "bt709", "smpte2084" (PQ), "arib-std-b67" (HLG).
    public var transfer: String?
    /// "tv" (limited) or "pc" (full).
    public var range: String?

    public init(space: String? = nil, primaries: String? = nil,
                transfer: String? = nil, range: String? = nil) {
        self.space = space
        self.primaries = primaries
        self.transfer = transfer
        self.range = range
    }

    public static let rec709 = ColorProperties(space: "bt709", primaries: "bt709",
                                               transfer: "bt709", range: "tv")

    /// HDR10.
    public static let rec2020PQ = ColorProperties(space: "bt2020nc", primaries: "bt2020",
                                                  transfer: "smpte2084", range: "tv")

    /// Hybrid Log-Gamma.
    public static let rec2020HLG = ColorProperties(space: "bt2020nc", primaries: "bt2020",
                                                   transfer: "arib-std-b67", range: "tv")

    public var isEmpty: Bool {
        return space == nil && primaries == nil && transfer == nil && range == nil
    }

    /// Reads the tags off a probed stream, so a transcode can carry them across unchanged.
    public init(matching stream: MediaInfo.Stream) {
        self.init(space: stream.colorSpace, primaries: stream.colorPrimaries,
                  transfer: stream.colorTransfer, range: stream.colorRange)
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
    case webm
    case m4a
    case wav
    case mp3
    case flac
    case ogg
    /// A still image. The muxer does not decide which kind - the video codec does, so pair this
    /// with `.png` or `.mjpeg`.
    ///
    /// Muxes as `image2pipe`, not `image2`. `image2` treats its output as a filename pattern and
    /// writes to standard output when handed a protocol it does not recognise - which with a
    /// descriptor means the image is written somewhere other than the file asked for, and ffmpeg
    /// still exits successfully.
    case image
    case other(String)

    var argument: String {
        switch self {
        case .mp4:            return "mp4"
        case .mov:            return "mov"
        case .matroska:       return "matroska"
        case .webm:           return "webm"
        case .m4a:            return "ipod"
        case .wav:            return "wav"
        case .mp3:            return "mp3"
        case .flac:           return "flac"
        case .ogg:            return "ogg"
        case .image:          return "image2pipe"
        case .other(let s):   return s
        }
    }

    /// Whether `-movflags +faststart` means anything here.
    var supportsFaststart: Bool {
        switch self {
        case .mp4, .mov, .m4a:   return true
        case .other(let s):      return s == "mp4" || s == "mov" || s == "ipod"
        default:                 return false
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
