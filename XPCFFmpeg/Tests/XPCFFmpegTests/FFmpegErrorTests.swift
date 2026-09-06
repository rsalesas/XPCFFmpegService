import XCTest
import XPCFFmpegServiceFramework
@testable import XPCFFmpeg

final class FFmpegErrorTests: XCTestCase {

    func testCancelled() {
        XCTAssertEqual(FFmpegError.cancelled.localizedDescription, "The operation was cancelled.")
    }

    func testFailedPrefersFFmpegsLastError() {
        let log = [LogMessage(Fixture.status(domain: "info", message: "opening file")),
                   LogMessage(Fixture.status(domain: "error", message: "Invalid data found")),
                   LogMessage(Fixture.status(domain: "warning", message: "deprecated option"))]

        XCTAssertEqual(FFmpegError.failed(.failure, log: log).localizedDescription,
                       "Invalid data found",
                       "the last real error is more use than the generic service message")
    }

    func testFailedFallsBackToTheServiceErrorWhenNothingWasLogged() {
        XCTAssertEqual(FFmpegError.failed(.unknownRequest, log: []).localizedDescription,
                       ServiceError.unknownRequest.localizedDescription)

        // Warnings alone are not an explanation of a failure.
        let benign = [LogMessage(Fixture.status(domain: "warning", message: "deprecated"))]
        XCTAssertEqual(FFmpegError.failed(.failure, log: benign).localizedDescription,
                       ServiceError.failure.localizedDescription)
    }

    func testAnUnwritableDestinationSaysWhatToDoAboutIt() {
        // The sandbox grants the file the user picked, not its folder, so this is the error a
        // caller hits when they derive an output path from an input. It should point at the fix.
        let error = FFmpegError.inaccessibleFile(URL(fileURLWithPath: "/tmp/out.mp4"),
                                                 underlying: CocoaError(.fileWriteNoPermission))
        let text = error.localizedDescription

        XCTAssertTrue(text.contains("out.mp4"), text)
        XCTAssertTrue(text.contains("NSSavePanel"), text)
    }

    func testInaccessibleFileNamesTheFile() {
        let error = FFmpegError.inaccessibleFile(URL(fileURLWithPath: "/tmp/some/clip.mov"),
                                                 underlying: CocoaError(.fileNoSuchFile))
        XCTAssertEqual(error.localizedDescription, "clip.mov could not be reached.")
    }

    func testUnexpectedResponseCarriesTheDetail() {
        let text = FFmpegError.unexpectedResponse("expected ffprobe JSON, got NSNull").localizedDescription
        XCTAssertTrue(text.contains("expected ffprobe JSON, got NSNull"), text)
    }

    func testServiceUnavailableCarriesTheUnderlyingCause() {
        let underlying = NSError(domain: NSCocoaErrorDomain, code: 4097,
                                 userInfo: [NSLocalizedDescriptionKey: "connection interrupted"])
        let text = FFmpegError.serviceUnavailable(underlying).localizedDescription
        XCTAssertTrue(text.contains("connection interrupted"), text)
    }

    /// Every ServiceError the service can send has to come back out as something a person can read;
    /// the enum crosses the wire as an NSError, where an unmapped case reads as "error 11".
    func testEveryServiceErrorHasAMessage() {
        for raw in Int32(1)...Int32(11) {
            guard let serviceError = ServiceError(rawValue: raw) else {
                return XCTFail("ServiceError \(raw) is unmapped")
            }
            let description = FFmpegError.failed(serviceError, log: []).localizedDescription
            XCTAssertFalse(description.isEmpty)
            XCTAssertFalse(description.contains("error \(raw)"), "unhelpful message: \(description)")
        }
    }
}
