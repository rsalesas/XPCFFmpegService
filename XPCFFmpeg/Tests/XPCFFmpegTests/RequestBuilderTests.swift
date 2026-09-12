import XCTest
@testable import XPCFFmpeg
import XPCFFmpegServiceFramework

/// These exercise the argument construction, which is pure - no XPC service required. Everything
/// that needs the service lives in the end-to-end harness instead.
final class RequestBuilderTests: XCTestCase {

    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        source = directory.appendingPathComponent("in.mov")
        destination = directory.appendingPathComponent("out.mp4")
        try Data("not really a movie".utf8).write(to: source)
    }

    /// Replaces descriptor tokens with a marker so an argument vector can be asserted on readably.
    private func readable(_ request: FFmpegRequest) -> [String] {
        return request.arguments.map { $0.hasPrefix(FFmpegRequest.tokenPrefix) ? "<fd>" : $0 }
    }

    func testSimpleTranscode() throws {
        let conversion = Conversion(from: source, to: destination,
                                    video: .h264(quality: 20, preset: .fast),
                                    audio: .aac(.kbps(128)))
        let built = try RequestBuilder.request(for: conversion)
        let request = built.request

        XCTAssertEqual(request.request, "-ffmpeg")
        // Both files are named only as descriptors, and the output carries an explicit muxer
        // because fd: has no extension to infer one from.
        XCTAssertEqual(readable(request),
                       ["-y", "-fd", "<fd>", "-i", "fd:",
                        "-c:v", "libx264", "-crf:v", "20", "-preset:v", "fast",
                        "-c:a", "aac", "-b:a", "128000",
                        "-f", "mp4", "-fd", "<fd>", "fd:"])
    }

    func testInputOptionsPrecedeTheirInput() throws {
        let input = Input(url: source, timeRange: TimeRange(start: 5, duration: 10), readAtNativeRate: true)
        let conversion = Conversion(inputs: [input], outputs: [Output(url: destination)])

        XCTAssertEqual(readable(try RequestBuilder.request(for: conversion).request),
                       ["-y", "-re", "-ss", "5.0", "-t", "10.0", "-fd", "<fd>", "-i", "fd:",
                        "-f", "mp4", "-fd", "<fd>", "fd:"])
    }

    func testEveryFileGetsItsOwnBookmark() throws {
        let second = source.deletingLastPathComponent().appendingPathComponent("in2.mov")
        try Data("also not a movie".utf8).write(to: second)

        let conversion = Conversion(inputs: [Input(url: source), Input(url: second)],
                                    outputs: [Output(url: destination)])
        let built = try RequestBuilder.request(for: conversion)
        let request = built.request

        // Two inputs and one output - the old single-URL protocol could only ever describe one.
        XCTAssertEqual(built.handles.count, 3)
        XCTAssertEqual(built.tokens.count, 3)
    }

    func testBitrateWinsOverQuality() throws {
        var settings = VideoSettings.h264(quality: 18)
        settings.bitrate = .mbps(5)
        let conversion = Conversion(from: source, to: destination, video: settings)

        let arguments = readable(try RequestBuilder.request(for: conversion).request)
        XCTAssertTrue(arguments.contains("-b:v"))
        XCTAssertFalse(arguments.contains("-crf"))
    }

    func testDroppingStreams() throws {
        let conversion = Conversion(from: source, to: destination,
                                    video: .disabled,
                                    audio: .copy)
        let arguments = readable(try RequestBuilder.request(for: conversion).request)

        XCTAssertTrue(arguments.contains("-vn"))
        XCTAssertEqual(arguments.firstIndex(of: "-c:a").map { arguments[$0 + 1] }, "copy")
    }

    func testFilterGraphAndMaps() throws {
        var output = Output(url: destination)
        output.streamMaps = [.video(ofInput: 0), .audio(ofInput: 1, index: 2)]
        let conversion = Conversion(inputs: [Input(url: source)], outputs: [output],
                                    filterGraph: .scale(width: 1280, height: 720))

        let arguments = readable(try RequestBuilder.request(for: conversion).request)
        XCTAssertTrue(arguments.contains("-filter_complex"))
        XCTAssertTrue(arguments.contains("scale=1280:720"))
        XCTAssertEqual(arguments.firstIndex(of: "-map").map { arguments[$0 + 1] }, "0:v")
        XCTAssertTrue(arguments.contains("1:a:2"))
    }

    func testProbeRequest() throws {
        let request = try RequestBuilder.probeRequest(for: source, options: .default).request

        XCTAssertEqual(request.request, "-ffprobe")
        XCTAssertEqual(readable(request), ["-show_format", "-show_streams", "-fd", "<fd>", "-i", "fd:"])
    }

    func testTheDestinationIsOpenedByTheClient() throws {
        // The client is the process holding the user's grant, so it is the only one that can open
        // the file. The service and FFmpegTask only ever see the descriptor.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let built = try RequestBuilder.request(for: Conversion(from: source, to: destination))

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
                      "the destination should have been created and opened")
        XCTAssertEqual(built.placeholders, [destination])
        XCTAssertEqual(built.handles.count, 2, "one descriptor per file")
        XCTAssertEqual(built.tokens.count, 2)

        // The output is named only as a descriptor.
        XCTAssertEqual(built.request.arguments.suffix(3).first, "-fd")
        XCTAssertEqual(built.request.arguments.last, "fd:")
        XCTAssertFalse(built.request.arguments.contains(destination.path),
                       "no path should reach the service")
    }

    func testAnOutputWithNoRecognisableContainerIsRejected() {
        // fd: carries no filename, so ffmpeg cannot infer the muxer from an extension.
        let odd = destination.deletingPathExtension().appendingPathExtension("wat")
        XCTAssertThrowsError(try RequestBuilder.request(for: Conversion(from: source, to: odd))) { error in
            guard case FFmpegError.indeterminateContainer = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testTheContainerIsTakenFromTheExtensionWhenNotGiven() throws {
        XCTAssertEqual(try RequestBuilder.container(for: Output(url: URL(fileURLWithPath: "/tmp/a.mkv"))), "matroska")
        XCTAssertEqual(try RequestBuilder.container(for: Output(url: URL(fileURLWithPath: "/tmp/a.mov"))), "mov")
        XCTAssertEqual(try RequestBuilder.container(for: Output(url: URL(fileURLWithPath: "/tmp/a.m4a"))), "ipod")
        // An explicit container always wins.
        XCTAssertEqual(try RequestBuilder.container(for: Output(url: URL(fileURLWithPath: "/tmp/a.mkv"), container: .mp4)), "mp4")
    }

    func testAnExistingOutputIsNotTreatedAsAPlaceholder() throws {
        try Data("already here".utf8).write(to: destination)
        let built = try RequestBuilder.request(for: Conversion(from: source, to: destination))

        XCTAssertTrue(built.placeholders.isEmpty, "an existing file must not be deleted on failure")
    }

    func testAnUnwritableDestinationIsReported() {
        let unreachable = source.appendingPathComponent("nested/deeper/out.mp4")
        XCTAssertThrowsError(try RequestBuilder.request(for: Conversion(from: source, to: unreachable))) { error in
            guard case FFmpegError.inaccessibleFile = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - What a refused request leaves behind

    func testAFailedBuildLeavesAnExistingDestinationAsItWas() throws {
        // The second output cannot name a muxer, so the whole request is refused - but only after
        // the first has been opened, and opening a destination used to empty it. A conversion that
        // never ran destroyed a file it never wrote a byte of.
        try Data("precious bytes".utf8).write(to: destination)
        let unnameable = destination.deletingLastPathComponent().appendingPathComponent("second.wat")

        let conversion = Conversion(inputs: [Input(url: source)],
                                    outputs: [Output(url: destination), Output(url: unnameable)])

        XCTAssertThrowsError(try RequestBuilder.request(for: conversion))
        XCTAssertEqual(try Data(contentsOf: destination), Data("precious bytes".utf8),
                       "a destination has to survive a request that was refused")
    }

    func testAFailedBuildTakesAwayTheDestinationItCreated() throws {
        let unnameable = destination.deletingLastPathComponent().appendingPathComponent("second.wat")
        let conversion = Conversion(inputs: [Input(url: source)],
                                    outputs: [Output(url: destination), Output(url: unnameable)])

        XCTAssertThrowsError(try RequestBuilder.request(for: conversion))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a file created only to be written to should not outlive a refused request")
    }

    func testASuccessfulBuildEmptiesAnExistingDestination() throws {
        // ffmpeg reaches the output through a descriptor and cannot truncate it, so anything left
        // beyond what it writes is the tail of whatever was there before.
        try Data(repeating: 0xAB, count: 4096).write(to: destination)

        _ = try RequestBuilder.request(for: Conversion(from: source, to: destination))

        XCTAssertEqual(try Data(contentsOf: destination).count, 0)
    }

    func testRefusingToOverwriteLeavesTheFileUntouched() throws {
        try Data("precious bytes".utf8).write(to: destination)
        let conversion = Conversion(inputs: [Input(url: source)],
                                    outputs: [Output(url: destination)],
                                    overwriteExisting: false)

        XCTAssertThrowsError(try RequestBuilder.request(for: conversion)) { error in
            guard case FFmpegError.destinationExists = error else {
                return XCTFail("wrong error: \(error)")
            }
        }

        // ffmpeg is handed a descriptor, never a filename, so -n has nothing to refuse: enforced
        // here or not at all. It used to be neither - the flag only decided whether -y was sent,
        // while the file was emptied regardless.
        XCTAssertEqual(try Data(contentsOf: destination), Data("precious bytes".utf8))
    }

    func testRefusingToOverwriteIsFineWhenThereIsNothingThere() {
        let conversion = Conversion(inputs: [Input(url: source)],
                                    outputs: [Output(url: destination)],
                                    overwriteExisting: false)

        XCTAssertNoThrow(try RequestBuilder.request(for: conversion))
    }

    func testAWebmExtensionUsesTheWebmMuxer() throws {
        // matroska writes a Matroska DocType and holds to no codec subset, which is a file a
        // browser refuses however it is named.
        XCTAssertEqual(try RequestBuilder.container(for: Output(url: URL(fileURLWithPath: "/tmp/a.webm"))),
                       "webm")
        XCTAssertEqual(try RequestBuilder.container(for: Output(url: URL(fileURLWithPath: "/tmp/a.mkv"))),
                       "matroska")
    }

    // MARK: - The escape hatch

    func testRawOpensItsDestinationsForWriting() throws {
        // Every file named used to be opened read-only, so the escape hatch could not write one:
        // ffmpeg failed on its first write to it.
        let output = destination.deletingLastPathComponent().appendingPathComponent("raw.mp4")
        let built = try RequestBuilder.raw(verb: "-ffmpeg",
                                           arguments: ["-i", source.path, "-f", "mp4", output.path],
                                           reading: [source], writing: [output])

        let handle = try XCTUnwrap(built.handles.last)
        let written = Array("written".utf8).withUnsafeBytes {
            write(handle.fileDescriptor, $0.baseAddress, $0.count)
        }

        XCTAssertEqual(written, 7, "the destination's descriptor has to be writable")
        XCTAssertEqual(try Data(contentsOf: output), Data("written".utf8))
        XCTAssertEqual(built.placeholders, [output],
                       "a destination created here is tidied away like any other")
    }

    func testRawSubstitutesBothSidesOfTheCommandLine() throws {
        let output = destination.deletingLastPathComponent().appendingPathComponent("raw.mp4")
        let built = try RequestBuilder.raw(verb: "-ffmpeg",
                                           arguments: ["-i", source.path, "-f", "mp4", output.path],
                                           reading: [source], writing: [output])

        // The input's token is hoisted ahead of its -i; the output's takes the place of the bare
        // path it stood at.
        XCTAssertEqual(readable(built.request),
                       ["-fd", "<fd>", "-i", "fd:", "-f", "mp4", "-fd", "<fd>", "fd:"])
        XCTAssertFalse(built.request.arguments.contains(source.path))
        XCTAssertFalse(built.request.arguments.contains(output.path))
    }
}
