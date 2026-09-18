//
//  MenuBarItemPersistenceIdentityPolicy.swift
//  FloeBar
//

import CoreGraphics
import Foundation

/// Unresolved ownership blocks matching titles until the next full snapshot.
struct MenuBarItemPersistenceIdentityPolicy {
    private(set) var provisionalDuplicateTitles: Set<String> = []

    /// Updates provisional ambiguity from an unfiltered menu bar snapshot.
    ///
    /// Filtered callers must use ``eligibleIdentity(for:)`` without changing
    /// this state, otherwise a hidden sibling can incorrectly clear the block.
    mutating func update(
        fromFullSnapshot items: [MenuBarItem]
    ) -> [MenuBarItemSectionStore.Identity] {
        let titles = Dictionary(grouping: items, by: { $0.info.title })
        provisionalDuplicateTitles = Set(titles.compactMap { title, group in
            group.count > 1 && group.contains(where: \.hasProvisionalIdentity) ? title : nil
        })
        // Keep confirmed duplicates available to the store even while a title is blocked.
        return items.compactMap(\.sectionIdentity)
    }

    func isAwaitingStableIdentity(_ item: MenuBarItem) -> Bool {
        item.hasProvisionalIdentity ||
            provisionalDuplicateTitles.contains(item.info.title)
    }

    func eligibleIdentity(for item: MenuBarItem) -> MenuBarItemSectionStore.Identity? {
        guard !isAwaitingStableIdentity(item) else {
            return nil
        }
        return item.sectionIdentity
    }
}

/// User intent captured after macOS has already performed a native drag.
struct MenuBarItemPendingSectionIntents {
    static let expirationInterval: TimeInterval = 30

    struct Resolution {
        let windowID: CGWindowID
        let identity: MenuBarItemSectionStore.Identity
        let section: MenuBarItemSectionStore.Section
    }

    private struct ProcessGeneration: Equatable {
        let processID: pid_t
        let launchDate: Date?
    }

    /// Stable while an item moves horizontally, but changes for common
    /// WindowServer ID reuse cases.
    private struct ContinuityFingerprint: Equatable {
        let owner: ProcessGeneration
        let semanticTitle: String
        let layer: Int
        let width: Int
        let height: Int
        let lane: Int

        init(_ item: MenuBarItem) {
            owner = ProcessGeneration(
                processID: item.ownerPID,
                launchDate: item.owningApplication?.launchDate
            )
            semanticTitle = item.info.title
            layer = item.window.layer
            width = Self.units(item.frame.width)
            height = Self.units(item.frame.height)
            lane = Self.units(item.frame.minY)
        }

        private static func units(_ value: CGFloat) -> Int {
            Int((value * 8).rounded())
        }
    }

    private struct Intent {
        let fingerprint: ContinuityFingerprint
        let section: MenuBarItemSectionStore.Section
        let expiresAt: TimeInterval
        var source: ProcessGeneration?
        var observedUnresolvedAfterRecording = false
    }

    private var intents = [CGWindowID: Intent]()

    var isEmpty: Bool {
        intents.isEmpty
    }

    mutating func record(
        postDragItem item: MenuBarItem,
        section: MenuBarItemSectionStore.Section,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        intents[item.windowID] = Intent(
            fingerprint: ContinuityFingerprint(item),
            section: section,
            expiresAt: now + Self.expirationInterval,
            source: Self.sourceGeneration(of: item)
        )
    }

    func contains(
        _ item: MenuBarItem,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard
            let intent = intents[item.windowID],
            now < intent.expiresAt,
            intent.fingerprint == ContinuityFingerprint(item)
        else {
            return false
        }
        guard let source = intent.source else {
            return true
        }
        return source == Self.sourceGeneration(of: item)
    }

    /// Removes expired or discontinuous windows and returns live intents whose
    /// identity is now stable.
    mutating func reconcile(
        withFullSnapshot items: [MenuBarItem],
        policy: MenuBarItemPersistenceIdentityPolicy,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [Resolution] {
        let itemsByWindowID = Dictionary(
            items.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var resolutions = [Resolution]()
        var retained = [CGWindowID: Intent]()
        for (windowID, var intent) in intents {
            guard
                now < intent.expiresAt,
                let item = itemsByWindowID[windowID],
                intent.fingerprint == ContinuityFingerprint(item)
            else {
                continue
            }
            let currentSource = Self.sourceGeneration(of: item)
            if let source = intent.source {
                guard source == currentSource else {
                    continue
                }
            } else if let currentSource {
                // A source that appears before a later full snapshot has
                // confirmed the provisional window cannot be tied to the
                // dragged incarnation. Discard rather than transfer intent.
                guard intent.observedUnresolvedAfterRecording else {
                    continue
                }
                intent.source = currentSource
            } else {
                intent.observedUnresolvedAfterRecording = true
            }
            if let identity = policy.eligibleIdentity(for: item) {
                resolutions.append(Resolution(
                    windowID: windowID,
                    identity: identity,
                    section: intent.section
                ))
            }
            retained[windowID] = intent
        }
        intents = retained
        return resolutions
    }

    mutating func finish(windowID: CGWindowID) {
        intents[windowID] = nil
    }

    private static func sourceGeneration(
        of item: MenuBarItem
    ) -> ProcessGeneration? {
        guard let sourcePID = item.sourcePID else {
            return nil
        }
        return ProcessGeneration(
            processID: sourcePID,
            launchDate: item.sourceApplication?.launchDate
        )
    }
}

enum MenuBarItemMoveFailureKind {
    case noResponse
    case terminal
}

enum MenuBarItemMoveRetryPolicy {
    static func shouldWake(
        item: MenuBarItem,
        failure: MenuBarItemMoveFailureKind,
        attemptsRemain: Bool
    ) -> Bool {
        attemptsRemain && failure == .noResponse && item.isMovable
    }
}

extension MenuBarItem {
    var sectionIdentity: MenuBarItemSectionStore.Identity? {
        guard
            isMovable, canBeHidden,
            !hasProvisionalIdentity, !isTransientControlCenterItem,
            info.namespace != .ice, info.namespace != .special,
            let namespace = info.namespace.optional,
            !namespace.rawValue.isEmpty, !info.title.isEmpty
        else {
            return nil
        }
        return .init(
            bundleIdentifier: namespace.rawValue,
            title: info.title,
            instanceIndex: instanceIndex
        )
    }
}
