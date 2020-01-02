//
//  MatchRegularExpression.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  Simplifies use of NSRegularExpression for processing ffmpeg output


import Foundation


class MatchRegularExpression {
    
    struct Matches {
        internal let data: String
        internal let matches: [NSTextCheckingResult]

        public var count: Int {
            get {
                return matches.count
            }
        }
        
        public func count(of: Int) -> Int {
            precondition(of < matches.count, "Index out of range")
            return matches[of].numberOfRanges
        }
        
        public func contains(index: Int, group: String) -> Bool {
            precondition(index < matches.count, "Index out of range")
            let range = Range(matches[index].range(withName: group), in: data)
            return range != nil
        }
        
        public subscript(index: Int, group: String) -> String {
            get {
                precondition(index < matches.count, "Index out of range")
                guard let range = Range(matches[index].range(withName: group), in: data) else {
                    fatalError("Group name does not exist")
                }
                
                return String(data[range])
            }
        }
            
        public subscript(index: Int, at: Int) -> String {
            get {
                precondition(index < matches.count, "Index out of range")
                guard let range = Range(matches[index].range(at: at), in: data) else {
                    fatalError("Index out of range")
                }
                
                return String(data[range])
            }
        }
        
        internal init(data: String, regEx: NSRegularExpression, matchingOptions: NSRegularExpression.MatchingOptions) {
            self.data = data
            self.matches = regEx.matches(in: data, options: matchingOptions, range: NSMakeRange(0, data.count))
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

    init(in data: String, pattern: String, options: NSRegularExpression.Options = [], matchingOptions: NSRegularExpression.MatchingOptions = []) {
        guard let regEx = try? NSRegularExpression(pattern: pattern, options: options) else {
            fatalError("Invalid NSRegularExpression arguments")
        }
        
        self.regEx = regEx
        self.matches = Matches(data: data, regEx: self.regEx, matchingOptions: matchingOptions)
    }
}

