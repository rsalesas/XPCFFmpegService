//
//  PipeFraming.swift
//  Support
//
//  The record format on the pipe between FFmpegTask and XPCFFmpegService.
//
//  Records used to be recovered by scanning for balanced braces, tracking quote and escape state
//  as it went. That works, but it re-derives a boundary the writer already knew and threw away,
//  and it can only recover records that happen to look like JSON. A length prefix is cheaper,
//  unambiguous, and says nothing about what the payload contains.
//
//  A frame is a four-byte big-endian length followed by exactly that many bytes.
//

import Foundation


enum PipeFraming {

    /// Anything larger is taken as a desynchronised stream rather than a real record. ffprobe on a
    /// large file is the biggest legitimate payload and runs to a few hundred kilobytes.
    static let maximumPayloadSize = 64 * 1024 * 1024

    static let headerSize = 4

    /// Wraps `payload` in its length header. Empty payloads are not framed - there is nothing to
    /// deliver, and a zero-length frame would only make the reader's job harder.
    static func frame(_ payload: Data) -> Data? {
        guard !payload.isEmpty, payload.count <= maximumPayloadSize else { return nil }

        let length = UInt32(payload.count).bigEndian
        var framed = Data(capacity: headerSize + payload.count)
        withUnsafeBytes(of: length) { framed.append(contentsOf: $0) }
        framed.append(payload)

        return framed
    }
}


/// Reassembles frames from a byte stream that arrives in arbitrary chunks.
///
/// A pipe splits and coalesces writes as it pleases, so a read can land mid-header, mid-payload, or
/// carry several whole records at once. All three are ordinary.
struct FrameReader {

    enum Failure: Error {
        /// A length header that cannot be right, which means the stream is no longer aligned and
        /// nothing further can be trusted.
        case desynchronised(length: Int)
    }

    private var buffer = Data()

    /// Bytes held back waiting for the rest of their record.
    var pending: Int { return buffer.count }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Takes every complete record currently buffered, leaving any partial one behind.
    mutating func drain() throws -> [Data] {
        var records: [Data] = []

        while buffer.count >= PipeFraming.headerSize {
            let header = buffer.prefix(PipeFraming.headerSize)
            let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })

            guard length > 0, length <= PipeFraming.maximumPayloadSize else {
                throw Failure.desynchronised(length: length)
            }

            let total = PipeFraming.headerSize + length
            guard buffer.count >= total else { break }

            records.append(buffer.dropFirst(PipeFraming.headerSize).prefix(length))
            buffer.removeFirst(total)
        }

        return records
    }
}
