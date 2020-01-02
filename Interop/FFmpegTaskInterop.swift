//
//  ffprobe_classes.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  This file was generated from JSON Schema using quicktype, do not modify it directly.
//  To parse the JSON, add this file to your project and do:
//
//    let fFprobe = try? newJSONDecoder().decode(FFprobe.self, from: jsonData)

import Foundation

// MARK: - FFprobe
struct FFprobe: Codable {
    let programs: [Program]
    let packetsAndFrames: [PacketsAndFrame]
    let chapters: [Chapter]
    let streams: [Stream]
    let format: Format

    enum CodingKeys: String, CodingKey {
        case programs
        case packetsAndFrames = "packets_and_frames"
        case chapters, streams, format
    }
}

// MARK: - Chapter
struct Chapter: Codable {
    let id: Int
    let timeBase: TimeBase
    let start: Int
    let startTime: String
    let end: Int
    let endTime: String
    let tags: ChapterTags

    enum CodingKeys: String, CodingKey {
        case id
        case timeBase = "time_base"
        case start
        case startTime = "start_time"
        case end
        case endTime = "end_time"
        case tags
    }
}

// MARK: - ChapterTags
struct ChapterTags: Codable {
    let title: String
}

enum TimeBase: String, Codable {
    case the11000 = "1/1000"
}

// MARK: - Format
struct Format: Codable {
    let filename: String
    let nbStreams, nbPrograms: Int
    let formatName, formatLongName, startTime, duration: String
    let size, bitRate: String
    let probeScore: Int
    let tags: FormatTags

    enum CodingKeys: String, CodingKey {
        case filename
        case nbStreams = "nb_streams"
        case nbPrograms = "nb_programs"
        case formatName = "format_name"
        case formatLongName = "format_long_name"
        case startTime = "start_time"
        case duration, size
        case bitRate = "bit_rate"
        case probeScore = "probe_score"
        case tags
    }
}

// MARK: - FormatTags
struct FormatTags: Codable {
    let majorBrand, minorVersion, compatibleBrands, creationTime: String
    let encoder, locationEng, location: String

    enum CodingKeys: String, CodingKey {
        case majorBrand = "major_brand"
        case minorVersion = "minor_version"
        case compatibleBrands = "compatible_brands"
        case creationTime = "creation_time"
        case encoder
        case locationEng = "location-eng"
        case location
    }
}

// MARK: - PacketsAndFrame
struct PacketsAndFrame: Codable {
    let type: String
    let codecType: String?
    let streamIndex: Int
    let pts: Int?
    let ptsTime: String?
    let dts: Int?
    let dtsTime: String?
    let duration: Int?
    let durationTime, size, pos, flags: String?
    let mediaType: String?
    let keyFrame, pktPts: Int?
    let pktPtsTime: String?
    let bestEffortTimestamp: Int?
    let bestEffortTimestampTime: String?
    let pktDuration: Int?
    let pktDurationTime, pktPos, pktSize: String?
    let width, height: Int?
    let pixFmt, pictType: String?
    let codedPictureNumber, displayPictureNumber, interlacedFrame, topFieldFirst: Int?
    let repeatPict: Int?
    let colorRange: String?

    enum CodingKeys: String, CodingKey {
        case type
        case codecType = "codec_type"
        case streamIndex = "stream_index"
        case pts
        case ptsTime = "pts_time"
        case dts
        case dtsTime = "dts_time"
        case duration
        case durationTime = "duration_time"
        case size, pos, flags
        case mediaType = "media_type"
        case keyFrame = "key_frame"
        case pktPts = "pkt_pts"
        case pktPtsTime = "pkt_pts_time"
        case bestEffortTimestamp = "best_effort_timestamp"
        case bestEffortTimestampTime = "best_effort_timestamp_time"
        case pktDuration = "pkt_duration"
        case pktDurationTime = "pkt_duration_time"
        case pktPos = "pkt_pos"
        case pktSize = "pkt_size"
        case width, height
        case pixFmt = "pix_fmt"
        case pictType = "pict_type"
        case codedPictureNumber = "coded_picture_number"
        case displayPictureNumber = "display_picture_number"
        case interlacedFrame = "interlaced_frame"
        case topFieldFirst = "top_field_first"
        case repeatPict = "repeat_pict"
        case colorRange = "color_range"
    }
}

// MARK: - Program
struct Program: Codable {
    let programID, programNum, nbStreams, pmtPID: Int
    let pcrPID: Int
    let startPts: Int?
    let startTime: String?
    let endPts: Int?
    let endTime: String?
    let tags: ProgramTags
    let streams: [Stream]

    enum CodingKeys: String, CodingKey {
        case programID = "program_id"
        case programNum = "program_num"
        case nbStreams = "nb_streams"
        case pmtPID = "pmt_pid"
        case pcrPID = "pcr_pid"
        case startPts = "start_pts"
        case startTime = "start_time"
        case endPts = "end_pts"
        case endTime = "end_time"
        case tags, streams
    }
}

// MARK: - Stream
struct Stream: Codable {
    let index: Int
    let codecName, codecLongName, profile, codecType: String
    let codecTimeBase, codecTagString, codecTag: String
    let width, height, codedWidth, codedHeight: Int
    let hasBFrames: Int
    let sampleAspectRatio, displayAspectRatio: String?
    let pixFmt: String
    let level: Int
    let colorRange: String
    let chromaLocation: String?
    let fieldOrder: String
    let refs: Int
    let id: String?
    let rFrameRate, avgFrameRate, timeBase: String
    let startPts: Int
    let startTime: String
    let durationTs: Int
    let duration: String
    let disposition: [String: Int]
    let bitRate, nbFrames, nbReadFrames, nbReadPackets: String?
    let tags: StreamTags?

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecLongName = "codec_long_name"
        case profile
        case codecType = "codec_type"
        case codecTimeBase = "codec_time_base"
        case codecTagString = "codec_tag_string"
        case codecTag = "codec_tag"
        case width, height
        case codedWidth = "coded_width"
        case codedHeight = "coded_height"
        case hasBFrames = "has_b_frames"
        case sampleAspectRatio = "sample_aspect_ratio"
        case displayAspectRatio = "display_aspect_ratio"
        case pixFmt = "pix_fmt"
        case level
        case colorRange = "color_range"
        case chromaLocation = "chroma_location"
        case fieldOrder = "field_order"
        case refs, id
        case rFrameRate = "r_frame_rate"
        case avgFrameRate = "avg_frame_rate"
        case timeBase = "time_base"
        case startPts = "start_pts"
        case startTime = "start_time"
        case durationTs = "duration_ts"
        case duration, disposition
        case bitRate = "bit_rate"
        case nbFrames = "nb_frames"
        case nbReadFrames = "nb_read_frames"
        case nbReadPackets = "nb_read_packets"
        case tags
    }
}

// MARK: - StreamTags
struct StreamTags: Codable {
    let creationTime, language, handlerName: String

    enum CodingKeys: String, CodingKey {
        case creationTime = "creation_time"
        case language
        case handlerName = "handler_name"
    }
}

// MARK: - ProgramTags
struct ProgramTags: Codable {
    let serviceName, serviceProvider: String

    enum CodingKeys: String, CodingKey {
        case serviceName = "service_name"
        case serviceProvider = "service_provider"
    }
}
