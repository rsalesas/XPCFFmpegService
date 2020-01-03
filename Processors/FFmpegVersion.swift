//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation

protocol FFmpegDataHandler {
    init(from: Data)
}

struct FFmpegVersion: Encodable {
    private static let VersionPattern = #"^(?:FFmpegTask version (?<Version>\S+)\s(?<FFmpegCopyright>.*)\nbuilt with (?<Compiler>.*)\nconfiguration: (?<Configuration>.*)\n)|(?:(?<Library>lib\S+)\s*(?<Major>\d+)\.\s*(?<Minor>\d+)\.\s*(?<Build>\d+))"#  // -version
    
    public let version: String
    public let compiler: String
    public let ffmpegCopyright: String
    public let configuration: String
    public var libraries: [String : String] = [:]

    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegVersion.VersionPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 2, "Invalid ffmpeg version output; unexpected format")
        
        self.version = matchRegEx.matches[0, "Version"]
        self.compiler = matchRegEx.matches[0, "Compiler"]
        self.ffmpegCopyright = matchRegEx.matches[0, "FFmpegCopyright"]
        self.configuration = matchRegEx.matches[0, "Configuration"]
        
        for index in 2...matchRegEx.matches.count - 1 {
            let library = matchRegEx.matches[index, "Library"]
            let major = matchRegEx.matches[index, "Major"]
            let minor = matchRegEx.matches[index, "Minor"]
            let build = matchRegEx.matches[index, "Build"]

            libraries[library] = "\(major).\(minor).\(build)"
        }
    }
}
