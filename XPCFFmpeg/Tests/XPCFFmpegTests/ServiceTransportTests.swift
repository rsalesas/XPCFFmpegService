import XCTest
import XPCFFmpegServiceFramework
@testable import XPCFFmpeg

/// The real transport, against a service that is not there.
///
/// This is not a contrived case: it is exactly what a consumer gets when they add the package but
/// skip the Xcode Copy Files phase that embeds the .xpc, so it had better fail cleanly rather than
/// hang or trap.
final class ServiceTransportTests: XCTestCase {

    private let missingService = "com.siliconink.XPCFFmpegService.does-not-exist"

    func testInvokeAgainstAMissingServiceReportsFailure() {
        let transport = XPCServiceTransport(serviceName: missingService)
        defer { transport.invalidate() }

        let listener = JobStatusListener(totalDuration: nil)
        listener.resume()
        defer { listener.invalidate() }

        let failed = expectation(description: "connection failure reported")
        let replied = expectation(description: "no reply expected")
        replied.isInverted = true

        transport.invoke(jobID: UUID().uuidString,
                         endpoint: listener.endpoint,
                         request: FFmpegRequest(request: "-version", arguments: []),
                         fileTokens: [], fileHandles: [],
                         reply: { _, _ in replied.fulfill() },
                         failure: { _ in failed.fulfill() })

        wait(for: [failed, replied], timeout: 10)
    }

    func testASessionOnAMissingServiceSurfacesItAsAnError() async throws {
        let ffmpeg = FFmpeg(serviceName: missingService)
        let sandbox = Fixture.Sandbox()

        do {
            _ = try await ffmpeg.probe(sandbox.existingFile)
            XCTFail("expected a throw")
        } catch FFmpegError.serviceUnavailable {
            // The README's "you forgot the Copy Files phase" case.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCancelAndInvalidateAreSafeWithNoServiceBehindThem() {
        let transport = XPCServiceTransport(serviceName: missingService)

        // One-way, so there is nothing to deliver and nothing to fail.
        transport.cancel(jobID: UUID().uuidString)
        transport.invalidate()
        transport.invalidate()
    }
}
