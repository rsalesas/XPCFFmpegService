//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


class MatchRegularExpression {
    
    private let regEx: NSRegularExpression
    private let data: String
    
    private var innerMatches: [[String: String]] = [[:]]
    
    public var pattern: String {
        get {
            return regEx.pattern
        }
    }
    
    public var options: NSRegularExpression.Options {
        get {
            return regEx.options
        }
    }
    
    public var numberOfCaptureGroups: Int {
        get {
            return regEx.numberOfCaptureGroups
        }
    }

    init?(_ data: String, pattern: String, options: NSRegularExpression.Options = [], matchingOptions: NSRegularExpression.MatchingOptions = []) {
        
        // Do not support reporting options during matching
        precondition(!matchingOptions.contains(.reportCompletion), "Invalid value in matchingOptions (.reportCompletion)")
        precondition(!matchingOptions.contains(.reportProgress), "Invalid value in matchingOptions (.reportProgress)")

        guard let regEx = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        
        self.regEx = regEx
        self.data = data
        
        self.regEx.enumerateMatches(in: data, options: matchingOptions, range: NSMakeRange(0, data.count)) { result, _, _  in
            guard let result = result else {
                fatalError("Unexpected nil argument for NSTextCheckingResult")
            }
            
            let matches: [String: String] = [:]
            for i in  0 ..< result.numberOfRanges
            {
                if let range = Range(result.range(at: i), in: data) {
                    matches[result.]
                }
            }
            self.innerMatches.append(matches)
            
//            if let range = Range(result.range(withName: "Version"), in: message) {
//            }
        }
        
//        self.results = self.regEx.matches(in: data, options: matchingOptions, range: NSMakeRange(0, data.count))
//        matches = self.results.map { result in
//            result.
//
//
//            if let range = Range(result.range(withName: "Version"), in: message) {
//                version = String(message[range])
//            } else {
//                version = nil
//            }
//
//            return "t"
//        }
        
                
    }
    
    static public func ecapedPattern(for pattern: String) -> String {
        return NSRegularExpression.escapedPattern(for: pattern)
    }

    static public func escapedTemplate(for template: String) -> String {
        return NSRegularExpression.escapedTemplate(for: template)
    }
    
    
}


struct FFmpegVersion: Codable {
    private static let VersionPattern = #"^(?:FFmpegTask version (?<Version>\S+)\s(?<FFmpegCopyright>.*)\nbuilt with (?<Compiler>.*)\nconfiguration: (?<Configuration>.*)\n)|(?:(?<Library>lib\S+)\s*(?<Major>\d+)\.\s*(?<Minor>\d+)\.\s*(?<Build>\d+))"#  // -version
    
    let version: String?
    let compiler: String?
    let ffmpegCopyright: String?
    let configuration: String?
    //var libraries: String
    
    static func stringFromRange(message: String, range: Range<String.Index>?) {
        
    }
    
    init?(from data: Data) {
        guard let message = String(data: data, encoding: .utf8), let regEx = try? NSRegularExpression(pattern: FFmpegVersion.VersionPattern, options: .anchorsMatchLines) else {
            return nil
        }
        
        let values = regEx.matches(in: message, options: [], range: NSMakeRange(0, message.count))
        guard let first = values.first else {
            return nil
        }
        
        if let range = Range(first.range(withName: "Version"), in: message) {
            version = String(message[range])
        } else {
            version = nil
        }
        
       if let range = Range(first.range(withName: "Compiler"), in: message) {
           compiler = String(message[range])
       }

        if let range = Range(first.range(withName: "FFmpegCopyright"), in: message) {
            ffmpegCopyright = String(message[range])
        }

        if let range = Range(first.range(withName: "Configuration"), in: message) {
            configuration = String(message[range])
        }
        
        values.forEach { value in
        }
    }
}
