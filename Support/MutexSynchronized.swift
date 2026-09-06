//
//  MutexSynchronized.swift
//  Support
//
//  Vendored from SwiftExtensions (https://github.com/rsalesas/SwiftExtensions),
//  trimmed to just the pieces this project actually uses.
//

import Foundation

final class PThreadMutexLock {

    enum MutexType {
        case normal
        case recursive
    }

    private var mutex: pthread_mutex_t

    init(type: MutexType = .normal) {
        mutex = pthread_mutex_t()

        if type == .recursive {
            var attr = pthread_mutexattr_t()
            precondition(pthread_mutexattr_init(&attr) == 0)
            precondition(pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE) == 0)
            precondition(pthread_mutex_init(&mutex, &attr) == 0)
            precondition(pthread_mutexattr_destroy(&attr) == 0)
        } else {
            precondition(pthread_mutex_init(&mutex, nil) == 0)
        }
    }

    deinit {
        pthread_mutex_destroy(&mutex)
    }

    @inline(__always)
    func lock() {
        precondition(pthread_mutex_lock(&mutex) == 0)
    }

    @inline(__always)
    func unlock() {
        precondition(pthread_mutex_unlock(&mutex) == 0)
    }
}

/// Re-entrant synchronized mutex based class.
///
/// The mutex really is recursive: callers nest synchronize() blocks (a readability handler taking
/// the lock and then calling into a completion path that takes it again), which would deadlock
/// against a PTHREAD_MUTEX_NORMAL lock on the same thread.
final class MutexSynchronized {

    private let mutex = PThreadMutexLock(type: .recursive)

    init() {
    }

    /// Runs `execute` under the lock, returning whatever it returns.
    ///
    /// One generic entry point rather than a value-returning @autoclosure alongside a Void-returning
    /// block: with those two overloads, `synchronize { someValue }` bound the closure *itself* as
    /// the autoclosure's value and quietly handed back a `() -> R` instead of an `R`.
    @inline(__always)
    @discardableResult
    func synchronize<R>(_ execute: () throws -> R) rethrows -> R {
        mutex.lock()
        defer { mutex.unlock() }
        return try execute()
    }
}
