//
//  MatchRegularExpression.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  Simplifies use of NSRegularExpression for processing ffmpeg output


import Foundation
import os.log  // https://tinyurl.com/y9t97fqs and https://tinyurl.com/ybtbks5j


class MatchRegularExpression {
    
    struct Matches {
        internal let output: String
        internal let matches: [NSTextCheckingResult]

        public var count: Int {
            get {
                return matches.count
            }
        }
        
        public func count(of: Int) -> Int {
            precondition(of >= 0 && of < matches.count, "Index out of range")
            return matches[of].numberOfRanges
        }
        
        public func contains(index: Int, group: String) -> Bool {
            precondition(index >= 0 && index < matches.count, "Index out of range")
            let range = Range(matches[index].range(withName: group), in: output)
            return range != nil
        }
        
        /// Non-trapping lookup. Optional groups in the ffmpeg output patterns routinely fail to
        /// participate in a match - that is not an error, it just means ffmpeg did not emit that
        /// field in this particular report - so the caller needs a way to ask without trapping.
        public func value(_ index: Int, _ group: String) -> String? {
            precondition(index >= 0 && index < matches.count, "Index out of range")
            guard let range = Range(matches[index].range(withName: group), in: output) else {
                return nil
            }

            return String(output[range])
        }

        public subscript(index: Int, group: String) -> String {
            get {
                precondition(index >= 0 && index < matches.count, "Index out of range")
                guard let range = Range(matches[index].range(withName: group), in: output) else {
                    fatalError("Group name does not exist")
                }
                
                return String(output[range])
            }
        }
            
        public subscript(index: Int, at: Int) -> String {
            get {
                precondition(index >= 0 && index < matches.count, "Index out of range")
                guard let range = Range(matches[index].range(at: at), in: output) else {
                    fatalError("Index out of range")
                }
                
                return String(output[range])
            }
        }
        
        internal init(from: String, regEx: NSRegularExpression, matchingOptions: NSRegularExpression.MatchingOptions) {
            self.output = from
            self.matches = regEx.matches(in: output, options: matchingOptions, range: NSMakeRange(0, output.utf16.count))
        }
    }
    

    internal let regEx: NSRegularExpression
    public let matches: Matches
        
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
    
    public var fullMatch: NSRange? {
        get {
            if matches.count == 0 {
                return nil
            }
            
            return NSIntersectionRange(matches.matches[0].range, matches.matches[matches.matches.count - 1].range)
        }
    }

    init?(in data: Data, pattern: String, options: NSRegularExpression.Options = [], matchingOptions: NSRegularExpression.MatchingOptions = []) {
        guard let output = String(data: data, encoding: .utf8), let regEx = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        
        self.regEx = regEx
        self.matches = Matches(from: output, regEx: self.regEx, matchingOptions: matchingOptions)
    }
}

