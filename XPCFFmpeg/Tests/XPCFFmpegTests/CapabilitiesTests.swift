//
//  CapabilitiesTests.swift
//  XPCFFmpegTests
//
//  The capability queries against a stubbed service.
//
//  What is worth testing here is the translation, not the round trip: FFmpegTask's records name
//  their flags in its vocabulary and put a pixel format's name under "filter", and the point of
//  these types is that a caller never sees either. The JSON below is shaped exactly as
//  FFmpegTask's Encodable structs write it - FFmpegTaskTests is what proves it still parses real
//  FFmpeg output into that shape.
//

import XCTest
@testable import XPCFFmpeg
import XPCFFmpegServiceFramework


final class CapabilitiesTests: XCTestCase {

    private var transport: FakeTransport!
    private var ffmpeg: FFmpeg!

    override func setUp() {
        super.setUp()
        transport = FakeTransport()
        ffmpeg = FFmpeg(transport: transport)
    }

    /// Answers whatever verb is asked with `json`, and records the verb.
    private func answer(with json: [String : Any]) {
        transport.automaticReply = { _ in (json, nil) }
    }

    private var askedVerbs: [String] {
        return transport.invocations.map { $0.request.request }
    }

    // MARK: - Codecs

    func testCodecsSeparatesDecodingFromEncoding() async throws {
        answer(with: ["codecs" : [
            ["format" : "h264", "description" : "H.264",
             "support" : ["decoding", "encoding", "videoCodec", "lossyCompression"]],
            ["format" : "mp3", "description" : "MP3",
             "support" : ["decoding", "audioCodec", "lossyCompression"]],
            ["format" : "ffv1", "description" : "FFmpeg video codec #1",
             "support" : ["decoding", "encoding", "videoCodec", "intraFrameOnlyCodec", "losslessCompression"]],
        ]])

        let codecs = try await ffmpeg.codecs()

        XCTAssertEqual(askedVerbs, ["-codecs"])
        XCTAssertEqual(codecs.count, 3)

        let h264 = try XCTUnwrap(codecs.first { $0.name == "h264" })
        XCTAssertEqual(h264.kind, .video)
        XCTAssertTrue(h264.canDecode)
        XCTAssertTrue(h264.canEncode)
        XCTAssertTrue(h264.isLossy)
        XCTAssertFalse(h264.isLossless)

        // The whole reason -codecs is not enough on its own: a codec this build can read but not
        // write looks identical to one it can do both with unless the flags are kept apart.
        let mp3 = try XCTUnwrap(codecs.first { $0.name == "mp3" })
        XCTAssertEqual(mp3.kind, .audio)
        XCTAssertTrue(mp3.canDecode)
        XCTAssertFalse(mp3.canEncode)

        let ffv1 = try XCTUnwrap(codecs.first { $0.name == "ffv1" })
        XCTAssertTrue(ffv1.isIntraFrameOnly)
        XCTAssertTrue(ffv1.isLossless)
    }

    // MARK: - Encoders and decoders

    func testEncodersReportsTheNamesAConversionCanUse() async throws {
        answer(with: ["encoders" : [
            ["format" : "libx264", "description" : "libx264 H.264",
             "support" : ["video", "frameLevelMultithreading", "sliceLevelMultithreading"]],
            ["format" : "h264_videotoolbox", "description" : "VideoToolbox H.264",
             "support" : ["video"]],
            ["format" : "opus", "description" : "Opus", "support" : ["audio", "experimentalCodec"]],
        ]])

        let encoders = try await ffmpeg.encoders()

        XCTAssertEqual(askedVerbs, ["-encoders"])
        XCTAssertEqual(encoders.map { $0.name }, ["libx264", "h264_videotoolbox", "opus"])

        let x264 = try XCTUnwrap(encoders.first { $0.name == "libx264" })
        XCTAssertEqual(x264.kind, .video)
        XCTAssertTrue(x264.supportsFrameLevelThreading)
        XCTAssertTrue(x264.supportsSliceLevelThreading)
        XCTAssertFalse(x264.isExperimental)

        let opus = try XCTUnwrap(encoders.first { $0.name == "opus" })
        XCTAssertEqual(opus.kind, .audio)
        XCTAssertTrue(opus.isExperimental)
    }

    func testDecodersAskTheDecoderVerb() async throws {
        answer(with: ["decoders" : [
            ["format" : "h264", "description" : "H.264",
             "support" : ["video", "drawHorizontalBandSupported", "directRenderingMethod1Supported"]],
        ]])

        let decoders = try await ffmpeg.decoders()

        XCTAssertEqual(askedVerbs, ["-decoders"])
        XCTAssertTrue(decoders[0].supportsDrawHorizontalBand)
        XCTAssertTrue(decoders[0].supportsDirectRendering)
    }

    // MARK: - Formats

    func testMuxersAndDemuxersShareAShapeButNotAVerb() async throws {
        let payload: [String : Any] = ["formats" : [
            ["format" : "mp4", "description" : "MP4", "support" : ["muxing"]],
            ["format" : "matroska,webm", "description" : "Matroska / WebM", "support" : ["demuxing"]],
            ["format" : "avfoundation", "description" : "AVFoundation input",
             "support" : ["demuxing", "device"]],
        ]]

        answer(with: payload)
        let muxers = try await ffmpeg.muxers()
        XCTAssertEqual(askedVerbs, ["-muxers"])
        XCTAssertTrue(muxers[0].canMux)
        XCTAssertFalse(muxers[0].canDemux)

        answer(with: payload)
        _ = try await ffmpeg.demuxers()
        _ = try await ffmpeg.formats()
        _ = try await ffmpeg.devices()
        XCTAssertEqual(askedVerbs, ["-muxers", "-demuxers", "-formats", "-devices"])

        let device = try XCTUnwrap(muxers.first { $0.name == "avfoundation" })
        XCTAssertTrue(device.isDevice)
    }

    // MARK: - The rest

    func testFiltersCarryTheirWorkflowAndFlags() async throws {
        answer(with: ["filters" : [
            ["filter" : "scale", "description" : "Scale the input video size.",
             "workflow" : "V->V", "support" : []],
            ["filter" : "overlay", "description" : "Overlay a video source on top of the input.",
             "workflow" : "VV->V", "support" : ["timeline", "slice"]],
        ]])

        let filters = try await ffmpeg.filters()

        XCTAssertEqual(askedVerbs, ["-filters"])
        XCTAssertEqual(filters[0].workflow, "V->V")
        XCTAssertFalse(filters[0].supportsTimeline)
        XCTAssertTrue(filters[1].supportsTimeline)
        XCTAssertTrue(filters[1].supportsSliceThreading)
    }

    /// FFmpegTask puts a pixel format's name under "filter", following ffmpeg's own column head.
    /// It reaches the caller as `name`.
    func testPixelFormatsAreRenamedOutOfFFmpegsVocabulary() async throws {
        answer(with: ["pixelFormats" : [
            ["filter" : "yuv420p", "components" : 3, "bitsPerPixel" : 12, "bitDepths" : "8-8-8",
             "support" : ["input", "output"]],
            ["filter" : "videotoolbox_vld", "components" : 0, "bitsPerPixel" : 0, "bitDepths" : "0",
             "support" : ["hardwareAccelerated"]],
        ]])

        let formats = try await ffmpeg.pixelFormats()

        XCTAssertEqual(askedVerbs, ["-pix_fmts"])
        XCTAssertEqual(formats[0].name, "yuv420p")
        XCTAssertEqual(formats[0].componentCount, 3)
        XCTAssertEqual(formats[0].bitsPerPixel, 12)
        XCTAssertEqual(formats[0].bitDepths, "8-8-8")
        XCTAssertTrue(formats[0].canInput)
        XCTAssertTrue(formats[0].canOutput)

        XCTAssertTrue(formats[1].isHardwareAccelerated)
        XCTAssertFalse(formats[1].canInput)
    }

    func testSampleFormatsCarryTheirDepth() async throws {
        answer(with: ["sampleFormats" : [["name" : "s16", "depth" : 16],
                                         ["name" : "fltp", "depth" : 32]]])

        let formats = try await ffmpeg.sampleFormats()

        XCTAssertEqual(askedVerbs, ["-sample_fmts"])
        XCTAssertEqual(formats.map { $0.name }, ["s16", "fltp"])
        XCTAssertEqual(formats.map { $0.bitDepth }, [16, 32])
    }

    func testChannelLayoutsKeepTheirTwoGroups() async throws {
        answer(with: ["layouts" : [
            "individual" : [["name" : "FL", "description" : "front left"]],
            "standard" : [["name" : "stereo", "description" : "FL+FR"]],
        ]])

        let layouts = try await ffmpeg.channelLayouts()

        XCTAssertEqual(askedVerbs, ["-layouts"])
        XCTAssertEqual(layouts.individual.map { $0.name }, ["FL"])
        XCTAssertEqual(layouts.standard.map { $0.name }, ["stereo"])
        XCTAssertEqual(layouts.standard.first?.description, "FL+FR")
    }

    func testProtocolsKeepTheirDirection() async throws {
        answer(with: ["protocols" : ["input" : ["file", "http", "pipe"],
                                     "output" : ["file", "pipe"]]])

        let protocols = try await ffmpeg.protocols()

        XCTAssertEqual(askedVerbs, ["-protocols"])
        XCTAssertEqual(protocols.input, ["file", "http", "pipe"])
        XCTAssertEqual(protocols.output, ["file", "pipe"])
    }

    func testBitstreamFiltersArriveAsBareStrings() async throws {
        answer(with: ["bitstreamFilters" : ["h264_mp4toannexb", "null"]])

        let filters = try await ffmpeg.bitstreamFilters()

        XCTAssertEqual(askedVerbs, ["-bsfs"])
        XCTAssertEqual(filters, ["h264_mp4toannexb", "null"])
    }

    func testColorsCarryTheirHexValue() async throws {
        answer(with: ["colors" : [["name" : "AliceBlue", "rgb" : "#f0f8ff"]]])

        let colors = try await ffmpeg.colors()

        XCTAssertEqual(askedVerbs, ["-colors"])
        XCTAssertEqual(colors.first?.name, "AliceBlue")
        XCTAssertEqual(colors.first?.rgb, "#f0f8ff")
    }

    func testLicenseComesBackAsText() async throws {
        answer(with: ["license" : "FFmpeg is free software..."])

        let license = try await ffmpeg.license()

        XCTAssertEqual(askedVerbs, ["-license"])
        XCTAssertEqual(license, "FFmpeg is free software...")
    }

    // MARK: - Failure

    func testAQueryThatComesBackEmptyIsAnError() async throws {
        transport.automaticReply = { _ in (nil, nil) }

        await XCTAssertThrowsFFmpegError(try await ffmpeg.codecs()) { error in
            guard case .unexpectedResponse = error else {
                return XCTFail("expected unexpectedResponse, got \(error)")
            }
        }
    }

    func testAQueryAnsweredWithTheWrongKeyIsAnError() async throws {
        answer(with: ["decoders" : []])

        await XCTAssertThrowsFFmpegError(try await ffmpeg.codecs()) { error in
            guard case .unexpectedResponse = error else {
                return XCTFail("expected unexpectedResponse, got \(error)")
            }
        }
    }

    /// A record that no longer has the fields the type needs has to be a loud failure. Left to
    /// decode leniently this is exactly the silent-drift case FFmpegTaskTests exists to catch.
    func testAQueryAnsweredWithTheWrongShapeIsAnError() async throws {
        answer(with: ["codecs" : [["name" : "h264"]]])

        await XCTAssertThrowsFFmpegError(try await ffmpeg.codecs()) { error in
            guard case .unexpectedResponse = error else {
                return XCTFail("expected unexpectedResponse, got \(error)")
            }
        }
    }

    func testAServiceFailureSurfacesAsItself() async throws {
        transport.automaticReply = { _ in (nil, ServiceError.failure) }

        await XCTAssertThrowsFFmpegError(try await ffmpeg.encoders()) { error in
            guard case .failed = error else {
                return XCTFail("expected failed, got \(error)")
            }
        }
    }
}


/// XCTAssertThrowsError has no async form that also inspects the error, so this stands in.
func XCTAssertThrowsFFmpegError<T>(_ expression: @autoclosure () async throws -> T,
                                   file: StaticString = #filePath, line: UInt = #line,
                                   _ inspect: (FFmpegError) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("expected an error, none was thrown", file: file, line: line)
    } catch let error as FFmpegError {
        inspect(error)
    } catch {
        XCTFail("expected an FFmpegError, got \(error)", file: file, line: line)
    }
}
