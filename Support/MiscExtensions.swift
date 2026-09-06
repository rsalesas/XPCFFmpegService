//
//  MiscExtensions.swift
//  Support
//
//  Vendored from SwiftExtensions (https://github.com/rsalesas/SwiftExtensions),
//  trimmed to just the pieces this project actually uses.
//

import Foundation

extension ProcessInfo {
    var isSandboxed: Bool {
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}

extension LosslessStringConvertible {
    var string: String {
        .init(self)
    }
}
