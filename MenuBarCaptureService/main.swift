//
//  main.swift
//  FloeBar
//

import Foundation

let listener = NSXPCListener.service()
listener.delegate = Listener.shared
listener.resume()
