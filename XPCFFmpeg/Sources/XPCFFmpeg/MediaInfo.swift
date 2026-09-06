//
//  MediaInfo.swift
//  XPCFFmpeg
//
//  ffprobe's JSON, typed.
//

import Foundation


public struct MediaInfo {

    public struct Format {
        public let formatName: String
        public let formatLongName: String?
        public let duration: TimeInterval?
        public let size: Int?
        public let bitrate: Bitrate?
        public let tags: [String : String]
    }

    public struct Stream {
        public enum Kind: String {
            case video, audio, subtitle, data, attachment, unknown
        }

        public let index: Int
        public let kind: Kind
        public let codecName: String?
        public let codecLongName: String?
        public let width: Int?
        public let height: Int?
        /// Frames per second, from ffprobe's r_frame_rate ("30000/1001").
        public let frameRate: Double?
        public let sampleRate: Int?
        public let channels: Int?
        public let duration: TimeInterval?
        public let bitrate: Bitrate?
        public let tags: [String : String]

        public var frameSize: FrameSize? {
            guard let width = width, let height = height else { return nil }
            return FrameSize(width: width, height: height)
        }
    }

    public let format: Format?
    public let streams: [Stream]

    /// The container duration, falling back to the longest stream when the container does not
    /// declare one - which some formats genuinely do not.
    public var duration: TimeInterval? {
        return format?.duration ?? streams.compactMap { $0.duration }.max()
    }

    public var videoStreams: [Stream] { streams.filter { $0.kind == .video } }
    public var audioStreams: [Stream] { streams.filter { $0.kind == .audio } }

    // MARK: - Decoding

    init(response: Any?, log: [LogMessage]) throws {
        let root: [String : Any]

        // The service hands back whatever it parsed; accept the raw bytes too so that the escape
        // hatch and this path can share a decoder.
        if let dictionary = response as? [String : Any] {
            root = dictionary
        } else if let data = response as? Data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String : Any] {
            root = parsed
        } else {
            throw FFmpegError.unexpectedResponse("expected ffprobe JSON, got \(type(of: response))")
        }

        format = (root["format"] as? [String : Any]).map(MediaInfo.format(from:))
        streams = (root["streams"] as? [[String : Any]] ?? []).map(MediaInfo.stream(from:))

        if format == nil && streams.isEmpty {
            throw FFmpegError.unexpectedResponse("ffprobe returned neither format nor streams")
        }
    }

    private static func format(from json: [String : Any]) -> Format {
        return Format(formatName: json["format_name"] as? String ?? "",
                      formatLongName: json["format_long_name"] as? String,
                      duration: seconds(json["duration"]),
                      size: int(json["size"]),
                      bitrate: int(json["bit_rate"]).map { Bitrate(bitsPerSecond: $0) },
                      tags: tags(json["tags"]))
    }

    private static func stream(from json: [String : Any]) -> Stream {
        return Stream(index: int(json["index"]) ?? 0,
                      kind: Stream.Kind(rawValue: json["codec_type"] as? String ?? "") ?? .unknown,
                      codecName: json["codec_name"] as? String,
                      codecLongName: json["codec_long_name"] as? String,
                      width: int(json["width"]),
                      height: int(json["height"]),
                      frameRate: rational(json["r_frame_rate"]),
                      sampleRate: int(json["sample_rate"]),
                      channels: int(json["channels"]),
                      duration: seconds(json["duration"]),
                      bitrate: int(json["bit_rate"]).map { Bitrate(bitsPerSecond: $0) },
                      tags: tags(json["tags"]))
    }

    private static func tags(_ value: Any?) -> [String : String] {
        guard let raw = value as? [String : Any] else { return [:] }
        return raw.compactMapValues { $0 as? String ?? ($0 as? NSNumber)?.stringValue }
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// FFmpegTask runs ffprobe with -sexagesimal, so durations arrive as "0:00:40.000000" rather
    /// than as a number of seconds. Both forms are accepted, since the escape hatch lets a caller
    /// turn that flag off.
    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }

        guard let string = value as? String else { return nil }
        if let plain = TimeInterval(string) { return plain }

        let parts = string.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }

        var total: TimeInterval = 0
        for part in parts {
            guard let component = TimeInterval(part) else { return nil }
            total = total * 60 + component
        }

        return total
    }

    /// ffprobe reports frame rates as "30000/1001".
    private static func rational(_ value: Any?) -> Double? {
        guard let string = value as? String else { return nil }

        let parts = string.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
            return n / d
        }

        return Double(string)
    }
}
