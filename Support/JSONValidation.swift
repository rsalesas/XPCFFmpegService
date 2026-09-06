//
//  JSONValidation.swift
//  Support
//
//  Vendored from SwiftExtensions (https://github.com/rsalesas/SwiftExtensions).
//
//  This used to carry JSONStreamValidator, which recovered record boundaries out of a byte stream
//  by counting braces. The pipe between FFmpegTask and the service is length-prefixed now (see
//  PipeFraming), so the boundaries arrive stated rather than inferred and the scanner is gone.
//  What remains are the two cheap checks the service still makes on a record once it has one.
//

import Foundation

fileprivate enum JSONCharacters {
    static let OpenBrace: UInt8 = 123
    static let CloseBrace: UInt8 = 125
}

extension Data {
    // Uses JSONSerialization to determine if the JSON is valid or not
    // This function is relatively expensive so it should be used with care
    var isValidJSON: Bool {
        get {
            return (try? JSONSerialization.jsonObject(with: self, options: [.allowFragments])) != nil
        }
    }

    // NB: This strips everything but the braces, but will return true for invalid JSON surrounded by braces. Should be used only on validated JSON
    var isEmptyJSON: Bool {
        get {
            let json = self.filter { c in
                return c == JSONCharacters.OpenBrace || c == JSONCharacters.CloseBrace
            }

            // Guarded: a record carrying no braces at all used to index straight off the end.
            guard json.count >= 2 else { return false }

            return (json.first == JSONCharacters.OpenBrace) && (json[json.index(after: json.startIndex)] == JSONCharacters.CloseBrace)
        }
    }
}
