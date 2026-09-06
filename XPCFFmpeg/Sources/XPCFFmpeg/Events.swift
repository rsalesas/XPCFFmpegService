//
//  Events.swift
//  XPCFFmpeg
//
//  What a running job reports as it goes.
//

import Foundation
import XPCFFmpegServiceFramework


public struct Progress: Equatable {
    public let frame: Int
    public let framesPerSecond: Double
    public let quality: Double
    public let bitrate: Bitrate?
    public let bytesWritten: Int?
    /// How far into the output we have got.
    public let encodedDuration: TimeInterval?
    public let duplicateFrames: Int
    public let droppedFrames: Int
    /// Encoding speed as a multiple of realtime, when ffmpeg reports it.
    public let speed: Double?
    public let isFinished: Bool

    /// 0...1, but only when the total duration is known - which it is if the job was started from
    /// a Conversion whose input we could probe. Nil otherwise rather than a guess.
    public let fractionCompleted: Double?

    init(_ raw: FFmpegProgress, totalDuration: TimeInterval?) {
        frame = raw.frame
        framesPerSecond = raw.fps
        quality = raw.quality
        bitrate = raw.bitrate.map { Bitrate(bitsPerSecond: Int($0 * 1000)) }
        bytesWritten = raw.totalSize
        encodedDuration = raw.outTime
        duplicateFrames = raw.duplicateFrames
        droppedFrames = raw.droppedFrames
        speed = raw.speed.map { Double($0) }
        isFinished = raw.finished

        if let total = totalDuration, total > 0, let encoded = raw.outTime {
            fractionCompleted = min(max(encoded / total, 0), 1)
        } else {
            fractionCompleted = nil
        }
    }
}


extension Progress: CustomStringConvertible {
    public var description: String {
        var parts = ["frame \(frame)", String(format: "%.1f fps", framesPerSecond)]

        if let fraction = fractionCompleted {
            parts.append(String(format: "%.0f%%", fraction * 100))
        }
        if let encoded = encodedDuration {
            parts.append(String(format: "%.2fs", encoded))
        }
        if let bitrate = bitrate {
            parts.append(String(format: "%.1f kbits/s", Double(bitrate.bitsPerSecond) / 1000))
        }
        if droppedFrames > 0 {
            parts.append("\(droppedFrames) dropped")
        }
        if isFinished {
            parts.append("finished")
        }

        return parts.joined(separator: ", ")
    }
}


public struct LogMessage: Equatable {
    public enum Level: String {
        case unknown, quiet, panic, fatal, error, warning, info, verbose, debug, trace
    }

    public let level: Level
    public let message: String

    public var isError: Bool {
        switch level {
        case .panic, .fatal, .error: return true
        default: return false
        }
    }

    init(_ raw: FFmpegStatus) {
        level = Level(rawValue: raw.domain.rawValue) ?? .unknown
        message = raw.message
    }
}


public enum JobEvent {
    case progress(Progress)
    case log(LogMessage)
}
