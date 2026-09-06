//
//  NSException.swift
//  Support
//
//  Vendored from SwiftExtensions (https://github.com/rsalesas/SwiftExtensions).
//  Wraps the _nsexception Obj-C shim so Swift can catch NSException as an Error.
//

import Foundation

extension NSException: Error {
}

/// Wraps _nsexception to throw NSException if the body throws NSException.
/// Can be called without a closure with a return (i.e., try NSException(a = 1 + 2))
@inlinable
@discardableResult
func NSException<R>(_ body: @autoclosure () throws -> R) throws -> R {
    var result: R?
    var exception: NSException?

    let _error = _nsexception.catchException({
        do {
            result = try body()
            return nil
        } catch {
            return error
        }
    }, exception: &exception)

    if _error != nil {
        throw _error!
    }

    if exception != nil {
        throw exception!
    }

    // This makes sure that the result was set (it could be set to nil, this just checks if it's set)
    if result == nil {
        fatalError("NSException: Result is never initialized")
    }

    return result!
}
