//
//  FFmpegError.swift
//  XPCFFmpeg
//

import Foundation
import XPCFFmpegServiceFramework


public enum FFmpegError: Error {
    /// The job was cancelled by the caller.
    case cancelled
    /// ffmpeg or ffprobe failed. `log` carries whatever it said on the way down.
    case failed(ServiceError, log: [LogMessage])
    /// A file could not be bookmarked, so the service would have had no way to reach it.
    case inaccessibleFile(URL, underlying: Error)
    /// An output reached through a descriptor has no filename, so the container cannot be guessed
    /// from an extension. Set `Output.container`.
    case indeterminateContainer(URL)
    /// The reply did not look like what the request should have produced.
    case unexpectedResponse(String)
    /// Two requests that both need to own the filter graph. Loudness normalisation is built out of
    /// a filter, so it cannot be combined with a graph or with stream maps the caller wrote.
    case conflictingFilterGraph(String)
    /// A measuring pass produced no measurements, so the second pass has nothing to work from.
    case measurementFailed(String)
    /// The XPC connection itself failed.
    case serviceUnavailable(Error)
}

extension FFmpegError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The operation was cancelled."

        case .failed(let error, let log):
            // The last thing ffmpeg complained about is almost always the useful part; the service
            // error on its own rarely says why.
            if let last = log.last(where: { $0.isError }) {
                return last.message
            }
            return error.localizedDescription

        case .inaccessibleFile(let url, let underlying):
            // Worth distinguishing: under the App Sandbox, user-selected.read-write grants the
            // file the user actually picked, not the folder it sits in. Choosing an input does not
            // license writing a sibling next to it, and "could not be reached" sends people
            // looking in the wrong place.
            if (underlying as? CocoaError)?.code == .fileWriteNoPermission {
                return "\(url.lastPathComponent) could not be created. Under the App Sandbox a "
                     + "destination needs a grant of its own - offer it through an NSSavePanel, or "
                     + "have the user select the enclosing folder."
            }

            return "\(url.lastPathComponent) could not be reached."

        case .indeterminateContainer(let url):
            return "The output format for \(url.lastPathComponent) could not be determined; set Output.container."

        case .unexpectedResponse(let detail):
            return "The service returned an unexpected response (\(detail))."

        case .conflictingFilterGraph(let detail):
            return detail

        case .measurementFailed(let detail):
            return "The measuring pass produced no usable result (\(detail))."

        case .serviceUnavailable(let underlying):
            return "The FFmpeg service is unavailable (\(underlying.localizedDescription))."
        }
    }
}
