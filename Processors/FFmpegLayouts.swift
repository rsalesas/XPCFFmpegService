//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegLayouts: Encodable {
    private static let LayoutPattern = #"^(?:(?<Individual>Individual)|(?<Standard>Standard))+|^(?:(?<Name>(?!NAME|Individual|Standard)\S+)\s+(?<Description>(?!DESCRIPTION).+))$"#  // -layouts, a bit different in that Individual/Standard are states
    
    struct Layout: Encodable {
        let name: String
        let description: String
    }
    
    public let individual: [Layout]
    public let standard: [Layout]

    enum AddToLayoutList {
        case none
        case individual
        case standard
    }

    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegLayouts.LayoutPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg layout output; unexpected format")
        
        var individual: [Layout] = []
        var standard: [Layout] = []
        var addToLayoutList: AddToLayoutList = .none

        for index in 0...matchRegEx.matches.count - 1 {
            if matchRegEx.matches.contains(index: index, group: "Individual") {
                addToLayoutList = .individual;
            } else if matchRegEx.matches.contains(index: index, group: "Standard") {
                addToLayoutList = .standard;
            } else if addToLayoutList != .none {
                let name = matchRegEx.matches[index, "Name"]
                let description = matchRegEx.matches[index, "Description"]
            
                if addToLayoutList == .individual {
                    individual.append(Layout(name: name, description: description))
                } else if addToLayoutList == .standard {
                    standard.append(Layout(name: name, description: description))
                }
            }
        }
        
        self.individual = individual
        self.standard = standard
    }
}
