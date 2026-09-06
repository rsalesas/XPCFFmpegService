//
//  URLExtensions.swift
//  Support
//
//  Vendored from SwiftExtensions (https://github.com/rsalesas/SwiftExtensions),
//  trimmed to just the piece this project actually uses.
//

import Foundation

private let BookmarkDataIsStaleKey = URLResourceKey("BookmarkDataIsStale")

extension URL {
    /// Convenience over URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)
    /// that stashes the staleness flag as a temporary resource value instead of requiring
    /// an inout parameter at the call site.
    init(resolvingBookmarkData bookmarkData: Data, options: NSURL.BookmarkResolutionOptions = [], relativeTo relativeURL: URL? = nil) throws {
        var bookmarkDataIsStale: Bool = false
        self = try URL(resolvingBookmarkData: bookmarkData, options: options, relativeTo: relativeURL, bookmarkDataIsStale: &bookmarkDataIsStale)
        setTemporaryResourceValue(bookmarkDataIsStale, forKey: BookmarkDataIsStaleKey)
    }
}
