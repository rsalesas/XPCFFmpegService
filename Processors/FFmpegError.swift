//
//  ffprobestdout.swift
//  FFmpegTask
//
//  Created by Robert Salesas on 28/12/19.
//  Copyright © 2019 Robert Salesas. All rights reserved.
//
//  These classes process the output of ffprobe into Swift classes compatible with Codable


import Foundation

/*
 func processProxyStandardError(fileHandle: FileHandle) {
     exitGroup.enter()
     defer { exitGroup.leave() }

     let data = fileHandle.availableData
     guard let message = String(data: data, encoding: .utf8), let regEx = try? NSRegularExpression(pattern: FFmpegTask.ErrorPattern, options: .anchorsMatchLines) else {
         let dataString = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
         os_log("Unable to process stderr output (%@)", type: .error, dataString)
         return
     }
     
     // TODO: Consider making "info" output into a collection of collections when indents occur.
     let values = regEx.matches(in: message, options: [], range: NSMakeRange(0, message.count))
     values.forEach { value in
         if let range = Range(value.range(withName: "Type"), in: message) {
             let type = String(message[range])
             
             if let range = Range(value.range(withName: "Description"), in: message) {
                 let description = String(message[range])
                 
                 struct ErrorJSON: Codable {
                     let type: String
                     let description: String
                 }
                 
                 writeAsJSON(ErrorJSON(type: type, description: description), fileHandle: defaultStandardErrorPipe.fileHandleForWriting)
             }
         }
     }
     
     // If we fall through, it means we failed to output
     let dataString = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
     os_log("Unable to process stderr output (%@)", type: .error, dataString)
 }

 */
struct FFmpegError: Encodable {
    private static let ErrorPattern = #"^.*\[(?<Type>(?:info)|(?:error)|(?:warning))\]\s(?:\:\s)*(?<Description>.*?)\s*$"#

    struct Error: Encodable {
        public let type: String
        public let description: String
    }
    
    public let errors: [Error]
        
    // TODO: This should be able to handle errors that don't match the above, by creating an entry that is "error" with all the text as a description
    init(from: Data) {
        guard let data = String(data: from, encoding: .utf8) else {
            fatalError("Invalid ffmpeg output")
        }
        
        // Must have at least 1 match group
        let matchRegEx = MatchRegularExpression(in: data, pattern: FFmpegError.ErrorPattern, options: .anchorsMatchLines)
        precondition(matchRegEx.matches.count >= 1, "Invalid ffmpeg error; unexpected format")
        
        var errors: [Error] = []
        
        for index in 0...matchRegEx.matches.count - 1 {
            let type = matchRegEx.matches[index, "Type"]
            let description = matchRegEx.matches[index, "Description"]
                        
            errors.append(Error(type: type, description: description))
        }
        
        self.errors = errors
    }
}
