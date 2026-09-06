//
//  ChildProcess.swift
//  XPCFFmpegService
//
//  A spawn that can hand descriptors to the child.
//
//  Foundation's Process cannot: it maps only stdin, stdout and stderr, and every other descriptor
//  is closed across the exec regardless of FD_CLOEXEC. Verified by reading fd 3 in a child - "Bad
//  file descriptor". That matters here because a descriptor is the only form of file access that
//  survives two process hops. A sandbox extension is a right that has to be exercised by whoever
//  opens the file, and it cannot be handed from the app, through the service, to FFmpegTask. A
//  descriptor is access already exercised, so it travels as far as it is passed.
//
//  So the granted files are dup2'd into place with posix_spawn_file_actions, and FFmpegTask is
//  told to use them with ffmpeg's own "-fd N ... fd:" protocol.
//

import Foundation
import os.log


final class ChildProcess {

    struct Termination {
        /// The child's exit status, or the signal number when `wasSignalled`.
        let status: Int32
        let wasSignalled: Bool
    }

    enum SpawnError: Error {
        case failed(code: Int32)
    }

    /// Where granted files start landing in the child. Clear of the standard three, and of
    /// anything Foundation happens to have open in this process.
    static let firstMappedDescriptor: Int32 = 10

    let executableURL: URL
    var arguments: [String] = []
    var standardOutput: Pipe?
    var standardError: Pipe?

    /// Descriptors to place in the child, keyed by the number the child should see.
    var mappedDescriptors: [Int32 : Int32] = [:]

    var terminationHandler: ((Termination) -> Void)?

    private let mutex = MutexSynchronized()
    private var pid: pid_t = 0
    private var running = false

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    var processIdentifier: pid_t {
        return mutex.synchronize { pid }
    }

    var isRunning: Bool {
        return mutex.synchronize { running }
    }

    func run() throws {
        try mutex.synchronize {
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }

            // stdin is closed to a null device: FFmpegTask runs with -nostdin and must never be
            // able to block waiting on a terminal.
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)

            if let out = standardOutput {
                posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
            }
            if let err = standardError {
                posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, 2)
            }

            for (childDescriptor, parentDescriptor) in mappedDescriptors {
                // dup2 onto itself is a no-op that leaves FD_CLOEXEC set, which would close the
                // descriptor at exec - the one case where the mapping silently does nothing.
                if childDescriptor == parentDescriptor {
                    let relocated = dup(parentDescriptor)
                    posix_spawn_file_actions_adddup2(&actions, relocated, childDescriptor)
                } else {
                    posix_spawn_file_actions_adddup2(&actions, parentDescriptor, childDescriptor)
                }
            }

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }

            // Reset every signal to its default in the child, and unblock the lot. Without this
            // the child inherits this process's dispositions - and an XPC service ignores signals
            // the child must not - so a cancel's SIGTERM would land on SIG_IGN and be discarded.
            // Foundation's Process does this for you; posix_spawn does not.
            var defaulted = sigset_t()
            sigfillset(&defaulted)
            posix_spawnattr_setsigdefault(&attributes, &defaulted)

            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            posix_spawnattr_setsigmask(&attributes, &unblocked)

            posix_spawnattr_setflags(&attributes,
                                     Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

            let argv = [executableURL.path] + arguments
            var carguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            carguments.append(nil)
            defer { carguments.forEach { free($0) } }

            var spawned: pid_t = 0
            let result = posix_spawn(&spawned, executableURL.path, &actions, &attributes,
                                     &carguments, environ)

            guard result == 0 else {
                os_log("ChildProcess.run->posix_spawn failed (%d)", result)
                throw SpawnError.failed(code: result)
            }

            pid = spawned
            running = true

            // Our copies of the write ends have to go, or the reader never sees EOF.
            try? standardOutput?.fileHandleForWriting.close()
            try? standardError?.fileHandleForWriting.close()

            reap(spawned)
        }
    }

    /// Waits for the child on a background queue and reports how it ended.
    private func reap(_ spawned: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(spawned, &status, 0) < 0 && errno == EINTR { }

            let signalled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
            let code = signalled ? (status & 0x7f) : ((status >> 8) & 0xff)

            guard let self = self else { return }

            self.mutex.synchronize { self.running = false }
            self.terminationHandler?(Termination(status: code, wasSignalled: signalled))
        }
    }

    func terminate() {
        let target = processIdentifier
        if target > 0 && isRunning { kill(target, SIGTERM) }
    }

    func forceKill() {
        let target = processIdentifier
        if target > 0 && isRunning { kill(target, SIGKILL) }
    }
}
