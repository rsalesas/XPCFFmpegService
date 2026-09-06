import XCTest

/// Exact values, decoded from real FFmpeg output.
///
/// The drift tests prove every row still matches; these prove the fields land in the right places.
/// Both are needed - a column shifted by one still matches a loose pattern, and only an assertion
/// on a known entry catches it.
final class OutputHandlerTests: XCTestCase {

    // MARK: - Pixel formats

    func testPixelFormat() throws {
        let json = try parsed(FFmpegPixelFormats(from: try Fixture.data("pix_fmts"))?.JSON)
        // IO... yuv420p                3             12      8-8-8
        let yuv = try entry("yuv420p", in: json, list: "pixelFormats", key: "filter")

        XCTAssertEqual(yuv["components"] as? Int, 3)
        XCTAssertEqual(yuv["bitsPerPixel"] as? Int, 12)
        XCTAssertEqual(yuv["bitDepths"] as? String, "8-8-8")
        XCTAssertEqual(yuv["support"] as? [String], ["input", "output"])
    }

    func testPixelFormatFlagsAreReadIndividually() throws {
        let json = try parsed(FFmpegPixelFormats(from: try Fixture.data("pix_fmts"))?.JSON)
        let all = try XCTUnwrap(json["pixelFormats"] as? [[String : Any]])

        XCTAssertTrue(all.contains { ($0["support"] as? [String])?.contains("hardwareAccelerated") == true },
                      "no hardware-accelerated format found; the H column may have moved")
        XCTAssertTrue(all.contains { ($0["support"] as? [String])?.contains("paletted") == true },
                      "no paletted format found; the P column may have moved")
    }

    // MARK: - Filters

    func testFilter() throws {
        let json = try parsed(FFmpegFilters(from: try Fixture.data("filters"))?.JSON)
        // .. scale             V->V       Scale the input video size and/or convert the image format.
        let scale = try entry("scale", in: json, list: "filters", key: "filter")

        XCTAssertEqual(scale["workflow"] as? String, "V->V")
        XCTAssertEqual(scale["description"] as? String,
                       "Scale the input video size and/or convert the image format.")
    }

    func testFilterFlags() throws {
        let json = try parsed(FFmpegFilters(from: try Fixture.data("filters"))?.JSON)
        // TS aap               AA->A      ...
        let aap = try entry("aap", in: json, list: "filters", key: "filter")

        XCTAssertEqual(aap["support"] as? [String], ["timeline", "slice"])
        XCTAssertEqual(aap["workflow"] as? String, "AA->A")
    }

    func testSourceAndSinkFiltersParse() throws {
        // Their workflow field uses | rather than a media type, which is easy to exclude by accident.
        let json = try parsed(FFmpegFilters(from: try Fixture.data("filters"))?.JSON)
        let all = try XCTUnwrap(json["filters"] as? [[String : Any]])

        XCTAssertTrue(all.contains { ($0["workflow"] as? String)?.hasPrefix("|") == true },
                      "no source filter parsed")
        XCTAssertTrue(all.contains { ($0["workflow"] as? String)?.hasSuffix("|") == true },
                      "no sink filter parsed")
    }

    // MARK: - Formats

    func testFormat() throws {
        let json = try parsed(FFmpegFormats(from: try Fixture.data("formats"))?.JSON)
        //   E  mp4             MP4 (MPEG-4 Part 14)
        let mp4 = try entry("mp4", in: json, list: "formats", key: "format")

        XCTAssertEqual(mp4["description"] as? String, "MP4 (MPEG-4 Part 14)")
        XCTAssertEqual(mp4["support"] as? [String], ["muxing"])
    }

    func testFormatWithBothDirections() throws {
        let json = try parsed(FFmpegFormats(from: try Fixture.data("formats"))?.JSON)
        let matroska = try entry("matroska", in: json, list: "formats", key: "format")
        XCTAssertTrue((matroska["support"] as? [String])?.contains("muxing") == true)
    }

    func testDeviceFormatsCarryTheDeviceFlag() throws {
        // These were dropped entirely: FFmpeg added a third flag column and the pattern took two.
        let json = try parsed(FFmpegFormats(from: try Fixture.data("formats"))?.JSON)
        let avf = try entry("avfoundation", in: json, list: "formats", key: "format")

        XCTAssertEqual(avf["description"] as? String, "AVFoundation input device")
        XCTAssertEqual(avf["support"] as? [String], ["demuxing", "device"])
    }

    func testDevicesVerbHasNoDeviceColumn() throws {
        // -devices omits the column, so the same rows must parse without gaining the flag.
        let json = try parsed(FFmpegFormats(from: try Fixture.data("devices"))?.JSON)
        let avf = try entry("avfoundation", in: json, list: "formats", key: "format")

        XCTAssertEqual(avf["support"] as? [String], ["demuxing"])
    }

    // MARK: - Codecs and decoders

    func testCodec() throws {
        let json = try parsed(FFmpegCodecs(from: try Fixture.data("codecs"))?.JSON)
        let h264 = try entry("h264", in: json, list: "codecs", key: "format")
        let support = try XCTUnwrap(h264["support"] as? [String])

        XCTAssertTrue(support.contains("decoding"))
        XCTAssertTrue(support.contains("videoCodec"))
    }

    func testDecoder() throws {
        let json = try parsed(FFmpegDecoders(from: try Fixture.data("decoders"))?.JSON)
        let decoders = try XCTUnwrap(json["decoders"] as? [[String : Any]])
        XCTAssertTrue(decoders.contains { $0["format"] as? String == "h264" })
    }

    // MARK: - The grouped ones

    func testProtocolsSplitIntoInputAndOutput() throws {
        let json = try parsed(FFmpegProtocols(from: try Fixture.data("protocols"))?.JSON)
        let protocols = try XCTUnwrap(json["protocols"] as? [String : Any])
        let input = try XCTUnwrap(protocols["input"] as? [String])
        let output = try XCTUnwrap(protocols["output"] as? [String])

        XCTAssertTrue(input.contains("file"))
        XCTAssertTrue(output.contains("file"))
        XCTAssertTrue(input.contains("concat"), "concat is input-only")
        XCTAssertFalse(output.contains("concat"), "the Input/Output state machine has slipped")
    }

    func testLayoutsSplitIntoIndividualAndStandard() throws {
        let json = try parsed(FFmpegLayouts(from: try Fixture.data("layouts"))?.JSON)
        let layouts = try XCTUnwrap(json["layouts"] as? [String : Any])
        let individual = try XCTUnwrap(layouts["individual"] as? [[String : Any]])
        let standard = try XCTUnwrap(layouts["standard"] as? [[String : Any]])

        let fl = try XCTUnwrap(individual.first { $0["name"] as? String == "FL" })
        XCTAssertEqual(fl["description"] as? String, "front left")
        XCTAssertTrue(standard.contains { $0["name"] as? String == "stereo" })
    }

    // MARK: - The simple lists

    func testBitstreamFilters() throws {
        let json = try parsed(FFmpegBitstreamFilters(from: try Fixture.data("bsfs"))?.JSON)
        let filters = try XCTUnwrap(json["bitstreamFilters"] as? [String])

        XCTAssertTrue(filters.contains("aac_adtstoasc"))
        XCTAssertFalse(filters.contains("Bitstream filters:"), "the heading is being parsed as data")
    }

    func testSampleFormats() throws {
        let json = try parsed(FFmpegSampleFormats(from: try Fixture.data("sample_fmts"))?.JSON)
        let formats = try XCTUnwrap(json["sampleFormats"] as? [[String : Any]])

        let s16 = try XCTUnwrap(formats.first { $0["name"] as? String == "s16" })
        XCTAssertEqual(s16["depth"] as? Int, 16)
    }

    func testColors() throws {
        let json = try parsed(FFmpegColors(from: try Fixture.data("colors"))?.JSON)
        let colors = try XCTUnwrap(json["colors"] as? [[String : Any]])

        let alice = try XCTUnwrap(colors.first { $0["name"] as? String == "AliceBlue" })
        XCTAssertEqual(alice["rgb"] as? String ?? alice["value"] as? String, "#f0f8ff")
    }

    // MARK: - Version and licence

    func testVersion() throws {
        let json = try parsed(FFmpegVersion(from: try Fixture.data("version"))?.JSON)
        let version = try XCTUnwrap(json["version"] as? [String : Any])

        XCTAssertEqual(version["version"] as? String, "n9.0.1")
        XCTAssertTrue((version["compiler"] as? String)?.contains("clang") == true)
        XCTAssertTrue((version["ffmpegCopyright"] as? String)?.contains("FFmpeg developers") == true)

        let libraries = try XCTUnwrap(version["libraries"] as? [String : String])
        XCTAssertNotNil(libraries["libavcodec"], "the per-library versions were not collected")
    }

    func testVersionStripsLocalPathsFromConfiguration() throws {
        // The configuration line carries the build machine's directory layout; it is not
        // information the caller should be handed.
        let json = try parsed(FFmpegVersion(from: try Fixture.data("version"))?.JSON)
        let version = try XCTUnwrap(json["version"] as? [String : Any])
        let configuration = try XCTUnwrap(version["configuration"] as? String)

        XCTAssertFalse(configuration.contains("--prefix=/"), configuration)
        XCTAssertTrue(configuration.contains("--enable-gpl"))
    }

    func testLicense() throws {
        let json = try parsed(FFmpegLicense(from: try Fixture.data("license"))?.JSON)
        let license = try XCTUnwrap(json["license"] as? String)
        XCTAssertTrue(license.contains("GNU General Public License"), license.prefix(80).description)
    }
}
