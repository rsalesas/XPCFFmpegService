// main.swift
import Foundation

let delegate = MyServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
