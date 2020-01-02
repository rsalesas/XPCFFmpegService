//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation


struct FFmpegProtocols: Encodable {
    private static let ProtocolPattern = #"(?:(?:(?<Input>Input):\n)+|(?:(?<Output>Output):\n)+)|^\s\s(?<Protocol>\S+)*$"#  // -protocols, a bit different in that Input/Output are states
    
    public let input: [String]
    public let output: [String]
    
    enum AddToProtocolList {
        case none
        case input
        case output
    }
    
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 2 match groups
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegProtocols.ProtocolPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 2, "Invalid ffmpeg protocol output; unexpected format")
        
        var inputProtocols: [String] = []
        var outputProtocols: [String] = []
        var addToProtocolList: AddToProtocolList = .none
        
        for index in 0...matchRegEx.matches.count - 1 {
            if matchRegEx.matches.contains(index: index, group: "Input") {
                addToProtocolList = .input;
            } else if matchRegEx.matches.contains(index: index, group: "Output") {
                addToProtocolList = .output;
            } else if addToProtocolList != .none {
                let protocolName = matchRegEx.matches[index, "Protocol"]
                if addToProtocolList == .input {
                    inputProtocols.append(protocolName)
                } else if addToProtocolList == .output {
                    outputProtocols.append(protocolName)
                }
            }
        }
        
        input = inputProtocols
        output = outputProtocols
    }
}
