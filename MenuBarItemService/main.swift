//
//  main.swift
//  FloeBar
//

import AXSwift
import Foundation

// Bound each Accessibility IPC call. A slow third-party process must not hold
// the serial resolver indefinitely.
UIElement.globalMessagingTimeout = 1

let listener = NSXPCListener.service()
listener.delegate = Listener.shared
listener.resume()
