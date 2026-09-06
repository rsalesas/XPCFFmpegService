//
//  Conversion.swift
//  XPCFFmpeg
//
//  A conversion described as values rather than as a string array. Anything this model cannot
//  express can be appended raw at the level it belongs to, so the typed surface never becomes a
//  ceiling.
//

import Foundation


public struct VideoSettings: Equatable {
    public var codec: VideoCodec?
    public var bitrate: Bitrate?
    /// Constant quality (x264/x265 -crf). Lower is better; ignored when `bitrate` is set.
    public var quality: Int?
    public var size: FrameSize?
    public var frameRate: Double?
    public var preset: EncoderPreset?
    public var pixelFormat: String?
    /// Drop video from the output entirely (-vn). Everything else here is ignored when set.
    public var isDisabled: Bool
    public var additionalOptions: [String]

    public init(codec: VideoCodec? = nil, bitrate: Bitrate? = nil, quality: Int? = nil,
                size: FrameSize? = nil, frameRate: Double? = nil, preset: EncoderPreset? = nil,
                pixelFormat: String? = nil, isDisabled: Bool = false,
                additionalOptions: [String] = []) {
        self.codec = codec
        self.bitrate = bitrate
        self.quality = quality
        self.size = size
        self.frameRate = frameRate
        self.preset = preset
        self.pixelFormat = pixelFormat
        self.isDisabled = isDisabled
        self.additionalOptions = additionalOptions
    }

    public static func h264(quality: Int = 23, preset: EncoderPreset = .medium) -> VideoSettings {
        return VideoSettings(codec: .h264, quality: quality, preset: preset)
    }

    public static func hevc(quality: Int = 28, preset: EncoderPreset = .medium) -> VideoSettings {
        return VideoSettings(codec: .hevc, quality: quality, preset: preset)
    }

    public static let copy = VideoSettings(codec: .copy)

    /// No video in the output.
    public static let disabled = VideoSettings(isDisabled: true)
}


public struct AudioSettings: Equatable {
    public var codec: AudioCodec?
    public var bitrate: Bitrate?
    public var sampleRate: Int?
    public var channels: Int?
    /// Drop audio from the output entirely (-an). Everything else here is ignored when set.
    public var isDisabled: Bool
    public var additionalOptions: [String]

    public init(codec: AudioCodec? = nil, bitrate: Bitrate? = nil, sampleRate: Int? = nil,
                channels: Int? = nil, isDisabled: Bool = false, additionalOptions: [String] = []) {
        self.codec = codec
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.isDisabled = isDisabled
        self.additionalOptions = additionalOptions
    }

    public static func aac(_ bitrate: Bitrate = .kbps(160)) -> AudioSettings {
        return AudioSettings(codec: .aac, bitrate: bitrate)
    }

    public static let copy = AudioSettings(codec: .copy)

    /// No audio in the output.
    public static let disabled = AudioSettings(isDisabled: true)
}


public struct Input: Equatable {
    public var url: URL
    /// Seek and/or limit before decoding.
    public var timeRange: TimeRange?
    /// Read at wall-clock speed (-re). Mostly useful for simulating a live source.
    public var readAtNativeRate: Bool
    /// Force a demuxer instead of letting ffmpeg probe (-f).
    public var format: String?
    public var additionalOptions: [String]

    public init(url: URL, timeRange: TimeRange? = nil, readAtNativeRate: Bool = false,
                format: String? = nil, additionalOptions: [String] = []) {
        self.url = url
        self.timeRange = timeRange
        self.readAtNativeRate = readAtNativeRate
        self.format = format
        self.additionalOptions = additionalOptions
    }
}


public struct Output: Equatable {
    public var url: URL
    public var container: Container?
    public var video: VideoSettings?
    public var audio: AudioSettings?
    /// Trim what is written, as opposed to seeking the input.
    public var timeRange: TimeRange?
    public var streamMaps: [StreamMap]
    public var metadata: [String : String]
    public var additionalOptions: [String]

    public init(url: URL, container: Container? = nil, video: VideoSettings? = nil,
                audio: AudioSettings? = nil, timeRange: TimeRange? = nil,
                streamMaps: [StreamMap] = [], metadata: [String : String] = [:],
                additionalOptions: [String] = []) {
        self.url = url
        self.container = container
        self.video = video
        self.audio = audio
        self.timeRange = timeRange
        self.streamMaps = streamMaps
        self.metadata = metadata
        self.additionalOptions = additionalOptions
    }
}


/// A -filter_complex graph.
///
/// Simple per-stream filters (-vf/-af) are deliberately not reachable: FFmpegTask rejects them,
/// because a complex graph can express everything they can and having one path is less to get
/// wrong.
public struct FilterGraph: Equatable, ExpressibleByStringLiteral {
    public var description: String

    public init(_ description: String) { self.description = description }
    public init(stringLiteral value: String) { self.description = value }

    /// Joins stages with "," - a single chain.
    public static func chain(_ stages: [String]) -> FilterGraph {
        return FilterGraph(stages.joined(separator: ","))
    }

    /// Joins chains with ";" - a graph of them.
    public static func graph(_ chains: [String]) -> FilterGraph {
        return FilterGraph(chains.joined(separator: ";"))
    }

    public static func scale(width: Int, height: Int) -> FilterGraph {
        return FilterGraph("scale=\(width):\(height)")
    }
}


public struct Conversion {
    public var inputs: [Input]
    public var outputs: [Output]
    public var filterGraph: FilterGraph?
    /// Overwrite an existing output (-y). On by default: without it ffmpeg blocks on a prompt that
    /// nothing can answer, since FFmpegTask runs with stdin closed.
    public var overwriteExisting: Bool
    public var additionalGlobalOptions: [String]

    public init(inputs: [Input], outputs: [Output], filterGraph: FilterGraph? = nil,
                overwriteExisting: Bool = true, additionalGlobalOptions: [String] = []) {
        self.inputs = inputs
        self.outputs = outputs
        self.filterGraph = filterGraph
        self.overwriteExisting = overwriteExisting
        self.additionalGlobalOptions = additionalGlobalOptions
    }

    /// The common case: one file in, one file out.
    public init(from source: URL, to destination: URL, video: VideoSettings? = nil,
                audio: AudioSettings? = nil, container: Container? = nil) {
        self.init(inputs: [Input(url: source)],
                  outputs: [Output(url: destination, container: container, video: video, audio: audio)])
    }
}
