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
    static let OpenBracket: UInt8 = 91
    static let CloseBracket: UInt8 = 93
    static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
}

extension Data {
    // Uses JSONSerialization to determine if the JSON is valid or not
    // This function is relatively expensive so it should be used with care
    var isValidJSON: Bool {
        get {
            return (try? JSONSerialization.jsonObject(with: self, options: [.allowFragments])) != nil
        }
    }

    /// Whether the record is an empty object or array - `{}` or `[]` - and so carries no answer.
    ///
    /// This used to strip everything except braces and check the first two were `{` then `}`,
    /// which is true of any flat object whose values happen to contain no braces of their own.
    /// `{"license": "...text with no braces..."}` reduced to `{}` and was discarded as empty, so
    /// the caller was told the job had simply succeeded and got no answer at all - silently, since
    /// discarding a record is not an error anywhere on this path.
    ///
    /// Whitespace is dropped because a record may be pretty-printed; nothing else is, so anything
    /// with content in it fails the comparison.
    var isEmptyJSON: Bool {
        get {
            let stripped = self.filter { !JSONCharacters.whitespace.contains($0) }

            return stripped.elementsEqual([JSONCharacters.OpenBrace, JSONCharacters.CloseBrace])
                || stripped.elementsEqual([JSONCharacters.OpenBracket, JSONCharacters.CloseBracket])
        }
    }
}
