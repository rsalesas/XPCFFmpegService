// MyServiceProtocol.swift
import Foundation

@objc public protocol MyServiceProtocol {
    func upperCaseString(_ string: String, withReply reply: @escaping (String) -> Void)
}
