import CoreGraphics
import Foundation

/// CoreGraphics uses pointer-sized raw window IDs, not boxed NSNumber objects.
enum WindowDescriptionQuery {
    static func descriptions(for windowIDs: [CGWindowID]) -> [CFDictionary] {
        guard !windowIDs.isEmpty else {
            return []
        }
        var values = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        return values.withUnsafeMutableBufferPointer { buffer in
            guard
                let array = CFArrayCreate(kCFAllocatorDefault, buffer.baseAddress, buffer.count, nil),
                let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [CFDictionary]
            else {
                return []
            }
            return descriptions
        }
    }
}
