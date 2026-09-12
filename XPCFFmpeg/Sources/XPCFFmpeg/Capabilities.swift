//
//  Capabilities.swift
//  XPCFFmpeg
//
//  What this FFmpeg build can actually do. These are the questions that are not jobs: they take no
//  files, report no progress and cannot be cancelled in any meaningful sense, but they go down the
//  same path as everything else because FFmpegTask is the only thing that knows the answers.
//
//  Each of these maps to one of FFmpegTask's query verbs, which parse ffmpeg's own listings into
//  records. The shapes below mirror those records; the flag letters ffmpeg prints in a column
//  ("DEV.LS") arrive as names and are re-exposed here as properties, since a caller asking "can
//  this build encode webm" should not have to know the column order.
//

import Foundation
import XPCFFmpegServiceFramework


/// Which of the three stream kinds something applies to.
public enum MediaKind: String, Equatable {
    case video, audio, subtitle, unknown
}


/// A codec: a format that streams are stored in, independent of the coders implementing it.
public struct Codec: Equatable {
    public let name: String
    public let description: String
    public let kind: MediaKind
    /// Whether this build can read it, and whether it can write it. Neither implies the other.
    public let canDecode: Bool
    public let canEncode: Bool
    public let isIntraFrameOnly: Bool
    public let isLossy: Bool
    public let isLossless: Bool
}


/// A concrete encoder or decoder. Several usually implement one `Codec` - h264 is decoded by
/// `h264` and encoded by `libx264`, `libx264rgb` and `h264_videotoolbox` - which is why choosing
/// one by name is different from choosing a codec.
public struct Coder: Equatable {
    public let name: String
    public let description: String
    public let kind: MediaKind
    public let supportsFrameLevelThreading: Bool
    public let supportsSliceLevelThreading: Bool
    /// Refuses to run without `-strict experimental`.
    public let isExperimental: Bool
    public let supportsDrawHorizontalBand: Bool
    public let supportsDirectRendering: Bool
}


/// A container format, and which directions it works in.
public struct ContainerFormat: Equatable {
    public let name: String
    public let description: String
    public let canMux: Bool
    public let canDemux: Bool
    /// A capture or playback device rather than a file format.
    public let isDevice: Bool
}


public struct Filter: Equatable {
    public let name: String
    public let description: String
    /// The filter's shape, as ffmpeg prints it - "V->V", "N->N" and so on.
    public let workflow: String
    /// Accepts `enable=` to be switched on and off over time.
    public let supportsTimeline: Bool
    public let supportsSliceThreading: Bool
}


public struct PixelFormat: Equatable {
    public let name: String
    public let componentCount: Int
    public let bitsPerPixel: Int
    /// Bits per component, as ffmpeg prints it: "8", or "8-8-8" when they differ.
    public let bitDepths: String
    public let canInput: Bool
    public let canOutput: Bool
    public let isHardwareAccelerated: Bool
    public let isPaletted: Bool
    public let isBitstream: Bool
}


public struct SampleFormat: Equatable {
    public let name: String
    public let bitDepth: Int
}


public struct ChannelLayout: Equatable {
    public let name: String
    public let description: String
}


/// ffmpeg lists layouts in two groups: the individual speakers, and the named arrangements of them.
public struct ChannelLayouts: Equatable {
    public let individual: [ChannelLayout]
    public let standard: [ChannelLayout]
}


/// Which URL schemes this build understands, by direction.
///
/// A protocol listed here is reached through `Input.remote`, which hands ffmpeg the URL to open
/// for itself. `InputSource.file` cannot use one: it is opened in the client and travels as a
/// descriptor, which is what makes it work under the App Sandbox.
public struct Protocols: Equatable {
    public let input: [String]
    public let output: [String]
}


public struct NamedColor: Equatable {
    public let name: String
    /// "#RRGGBB".
    public let rgb: String
}


// MARK: - Queries

extension FFmpeg {

    /// Every codec this build knows, whether or not it can encode it.
    public func codecs() async throws -> [Codec] {
        return try await query("-codecs", key: "codecs", as: [Wire.Codec].self).map {
            Codec(name: $0.format, description: $0.description, kind: $0.support.kind,
                  canDecode: $0.support.contains("decoding"),
                  canEncode: $0.support.contains("encoding"),
                  isIntraFrameOnly: $0.support.contains("intraFrameOnlyCodec"),
                  isLossy: $0.support.contains("lossyCompression"),
                  isLossless: $0.support.contains("losslessCompression"))
        }
    }

    /// The encoders available by name, which is what `VideoCodec.other` / `AudioCodec.other` take.
    public func encoders() async throws -> [Coder] {
        return try await coders("-encoders", key: "encoders")
    }

    public func decoders() async throws -> [Coder] {
        return try await coders("-decoders", key: "decoders")
    }

    /// Container formats, muxing and demuxing together.
    public func formats() async throws -> [ContainerFormat] {
        return try await containerFormats("-formats")
    }

    /// The formats that can be written - the ones a `Container` can name.
    public func muxers() async throws -> [ContainerFormat] {
        return try await containerFormats("-muxers")
    }

    /// The formats that can be read.
    public func demuxers() async throws -> [ContainerFormat] {
        return try await containerFormats("-demuxers")
    }

    public func devices() async throws -> [ContainerFormat] {
        return try await containerFormats("-devices")
    }

    /// The filters a `FilterGraph` may name.
    public func filters() async throws -> [Filter] {
        return try await query("-filters", key: "filters", as: [Wire.Filter].self).map {
            Filter(name: $0.filter, description: $0.description, workflow: $0.workflow,
                   supportsTimeline: $0.support.contains("timeline"),
                   supportsSliceThreading: $0.support.contains("slice"))
        }
    }

    /// The pixel formats `VideoSettings.pixelFormat` may name.
    public func pixelFormats() async throws -> [PixelFormat] {
        return try await query("-pix_fmts", key: "pixelFormats", as: [Wire.PixelFormat].self).map {
            PixelFormat(name: $0.filter, componentCount: $0.components,
                        bitsPerPixel: $0.bitsPerPixel, bitDepths: $0.bitDepths,
                        canInput: $0.support.contains("input"),
                        canOutput: $0.support.contains("output"),
                        isHardwareAccelerated: $0.support.contains("hardwareAccelerated"),
                        isPaletted: $0.support.contains("paletted"),
                        isBitstream: $0.support.contains("bitstream"))
        }
    }

    public func sampleFormats() async throws -> [SampleFormat] {
        return try await query("-sample_fmts", key: "sampleFormats", as: [Wire.SampleFormat].self).map {
            SampleFormat(name: $0.name, bitDepth: $0.depth)
        }
    }

    public func channelLayouts() async throws -> ChannelLayouts {
        let wire = try await query("-layouts", key: "layouts", as: Wire.Layouts.self)
        let mapped = { (layouts: [Wire.Layout]) in
            layouts.map { ChannelLayout(name: $0.name, description: $0.description) }
        }

        return ChannelLayouts(individual: mapped(wire.individual), standard: mapped(wire.standard))
    }

    public func protocols() async throws -> Protocols {
        let wire = try await query("-protocols", key: "protocols", as: Wire.Protocols.self)
        return Protocols(input: wire.input, output: wire.output)
    }

    /// Bitstream filters, by name. These have no flags to report, so they arrive as bare strings.
    public func bitstreamFilters() async throws -> [String] {
        return try await query("-bsfs", key: "bitstreamFilters", as: [String].self)
    }

    /// The colour names ffmpeg accepts wherever a filter takes a colour.
    public func colors() async throws -> [NamedColor] {
        return try await query("-colors", key: "colors", as: [Wire.Color].self).map {
            NamedColor(name: $0.name, rgb: $0.rgb)
        }
    }

    /// The licence of the FFmpeg build behind the service, in its own words.
    ///
    /// Worth surfacing rather than assuming: what this returns depends on how FFmpeg was
    /// configured, and an application shipping the result has to honour it. See NOTICE.
    public func license() async throws -> String {
        return try await query("-license", key: "license", as: String.self)
    }

    // MARK: - Plumbing

    private func coders(_ verb: String, key: String) async throws -> [Coder] {
        return try await query(verb, key: key, as: [Wire.Coder].self).map {
            Coder(name: $0.format, description: $0.description, kind: $0.support.kind,
                  supportsFrameLevelThreading: $0.support.contains("frameLevelMultithreading"),
                  supportsSliceLevelThreading: $0.support.contains("sliceLevelMultithreading"),
                  isExperimental: $0.support.contains("experimentalCodec"),
                  supportsDrawHorizontalBand: $0.support.contains("drawHorizontalBandSupported"),
                  supportsDirectRendering: $0.support.contains("directRenderingMethod1Supported"))
        }
    }

    private func containerFormats(_ verb: String) async throws -> [ContainerFormat] {
        return try await query(verb, key: "formats", as: [Wire.Format].self).map {
            ContainerFormat(name: $0.format, description: $0.description,
                            canMux: $0.support.contains("muxing"),
                            canDemux: $0.support.contains("demuxing"),
                            isDevice: $0.support.contains("device"))
        }
    }

    /// Runs a query verb and decodes the single-keyed object FFmpegTask replies with.
    ///
    /// The round trip through Data is deliberate: the service hands back whatever
    /// JSONSerialization produced, and re-encoding it is what lets Codable do the decoding rather
    /// than fifteen hand-written readers.
    private func query<T: Decodable>(_ verb: String, key: String, as type: T.Type) async throws -> T {
        let request = FFmpegRequest(request: verb, arguments: [])
        let job = start(RequestBuilder.Built(request: request, tokens: [], handles: [], placeholders: []),
                        totalDuration: nil)

        guard let response = try await job.value() else {
            throw FFmpegError.unexpectedResponse("\(verb) returned nothing")
        }

        guard JSONSerialization.isValidJSONObject(response) else {
            throw FFmpegError.unexpectedResponse("\(verb) returned \(Swift.type(of: response)), not JSON")
        }

        let data = try JSONSerialization.data(withJSONObject: response)

        do {
            guard let value = try JSONDecoder().decode([String : T].self, from: data)[key] else {
                throw FFmpegError.unexpectedResponse("\(verb) returned no \"\(key)\"")
            }
            return value
        } catch let error as DecodingError {
            throw FFmpegError.unexpectedResponse("\(verb) did not decode as \(T.self): \(error)")
        }
    }
}


/// The JSON as FFmpegTask writes it, kept apart from the public types.
///
/// These are separate on purpose. FFmpegTask's field names follow ffmpeg's own listings - a pixel
/// format arrives under "filter" - and its flags arrive as an array of names. Decoding straight
/// into the public shapes would either leak those quirks into the API or need custom decoders for
/// every one of them.
private enum Wire {

    struct Codec: Decodable {
        let format: String
        let description: String
        let support: [String]
    }

    struct Coder: Decodable {
        let format: String
        let description: String
        let support: [String]
    }

    struct Format: Decodable {
        let format: String
        let description: String
        let support: [String]
    }

    struct Filter: Decodable {
        let filter: String
        let description: String
        let workflow: String
        let support: [String]
    }

    struct PixelFormat: Decodable {
        let filter: String
        let components: Int
        let bitsPerPixel: Int
        let bitDepths: String
        let support: [String]
    }

    struct SampleFormat: Decodable {
        let name: String
        let depth: Int
    }

    struct Layout: Decodable {
        let name: String
        let description: String
    }

    struct Layouts: Decodable {
        let individual: [Layout]
        let standard: [Layout]
    }

    struct Protocols: Decodable {
        let input: [String]
        let output: [String]
    }

    struct Color: Decodable {
        let name: String
        let rgb: String
    }
}


private extension Array where Element == String {

    /// The stream kind, whichever vocabulary the verb used: -codecs says "videoCodec" where
    /// -encoders and -decoders say "video".
    var kind: MediaKind {
        if contains("video") || contains("videoCodec") { return .video }
        if contains("audio") || contains("audioCodec") { return .audio }
        if contains("subtitle") || contains("subtitleCodec") { return .subtitle }
        return .unknown
    }
}
