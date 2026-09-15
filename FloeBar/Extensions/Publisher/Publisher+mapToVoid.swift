//
//  Publisher+mapToVoid.swift
//  FloeBar
//

import Combine

extension Publisher {
    /// Transforms all elements from the upstream publisher into `Void` values.
    func mapToVoid() -> some Publisher<Void, Failure> {
        map { _ in () }
    }
}
