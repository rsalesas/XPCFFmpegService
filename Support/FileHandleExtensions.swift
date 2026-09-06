//
//  FileHandleExtensions.swift
//  Support
//
//  Vendored from SwiftExtensions (https://github.com/rsalesas/SwiftExtensions),
//  trimmed to just the pieces this project actually uses: non-blocking reads
//  and redirecting one FileHandle's underlying descriptor into another's.
//

import Foundation

extension FileHandle {

    /// Creates a duplicate handle (using `dup`) from the FileHandle provided
    convenience init(fileHandle: FileHandle) {
        self.init(fileDescriptor: dup(fileHandle.fileDescriptor))
    }

    private func poll(timeout: TimeInterval) -> Int {
        var p = pollfd()
        p.fd = fileDescriptor
        p.events = Int16(POLLIN)
        return Int(Darwin.poll(&p, 1, Int32(timeout * 1000)))
    }

    /// Reads whatever is currently available without blocking, returning nil if nothing is
    /// available within `timeout` seconds. Throws only for a genuine, unexpected I/O failure -
    /// the ordinary "nothing to read yet" case (EAGAIN) is swallowed and returns nil.
    @inline(never)
    func availableData(timeout: TimeInterval) throws -> Data? {
        if poll(timeout: timeout) == 1 {
            let fcntlFlags = fcntl(fileDescriptor, F_GETFL)

            let ret = fcntl(fileDescriptor, F_SETFL, fcntlFlags | O_NONBLOCK)
            assert(ret == 0, "unexpectedly, fcntl(\(fileDescriptor), F_SETFL, \(fcntlFlags) | O_NONBLOCK) returned \(ret)")

            defer {
                let ret = fcntl(fileDescriptor, F_SETFL, fcntlFlags)
                assert(ret == 0, "unexpectedly, fcntl(\(fileDescriptor), F_SETFL, \(fcntlFlags)) returned \(ret)")
            }

            do {
                return try NSException(availableData)
            } catch {
                if errno != EAGAIN {
                    throw error
                }
            }
        }

        return nil
    }

    /// Redirects `into`'s underlying file descriptor to point at the same open file
    /// description as `self` (via dup2) - e.g. `pipe.duplicate(into: .standardOutput)`
    /// makes the process's real stdout write into `pipe` from then on.
    @discardableResult
    func duplicate(into: FileHandle) -> Bool {
        let ret = dup2(fileDescriptor, into.fileDescriptor)
        return ret >= 0
    }
}
