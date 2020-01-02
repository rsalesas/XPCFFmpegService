//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegFilters: Encodable {
    private static let FilterPattern = #"^\s(?<Support>[TSCAVNI\.]{3})\s+(?<Filter>\S+)\s+(?<Workflow>\S+)\s+(?<Description>.+)$"#  // -filters

    /*
     Values for "Support"
     
     T.. = Timeline support
     .S. = Slice threading
     ..C = Command support
     A = Audio input/output
     V = Video input/output
     N = Dynamic number and/or type of input/output
     | = Source or sink filter
     */
    
    enum Support : String, Encodable {
        case timeline = "Timeline"
        case slice = "Slice"
        case command = "Command"
    }
    
    struct Filter: Encodable {
        let filter: String
        let description: String
        let workflow: String
        let support: [Support]
    }
    
    public let filters: [Filter]
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegFilters.FilterPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg filter output; unexpected format")
        
        var filters: [Filter] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let filter = matchRegEx.matches[index, "Filter"]
            let description = matchRegEx.matches[index, "Description"]
            let workflow = matchRegEx.matches[index, "Workflow"]
            let support = Array(matchRegEx.matches[index, "Support"])

            let supportFlags: [Support] = (support[0] == "T" ? [.timeline] : []) + ((support[1] == "S") ? [.slice] : []) + ((support[2] == "C") ? [.command] : [])
             
            filters.append(Filter(filter: filter, description: description, workflow: workflow, support: supportFlags))
        }
        
        self.filters = filters
    }
}
