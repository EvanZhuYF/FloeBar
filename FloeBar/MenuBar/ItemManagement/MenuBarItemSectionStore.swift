//
//  MenuBarItemSectionStore.swift
//  FloeBar
//

import Foundation

/// User intent is stored separately from the menu bar's observed positions.
final class MenuBarItemSectionStore {
    enum Section: String, Codable, Hashable {
        case visible, hidden, alwaysHidden
    }

    struct Identity: Codable, Hashable {
        let bundleIdentifier: String
        let title: String
    }

    struct Item: Equatable {
        let identity: Identity
        let windowID: UInt32
        let processID: Int32
        let section: Section
    }

    struct Restore {
        let item: Item
        let section: Section
    }

    struct Observation {
        let isSettled: Bool
        let restore: Restore?
    }

    private struct Record: Codable {
        let identity: Identity
        let section: Section
    }

    private struct Document: Codable {
        let version: Int
        let records: [Record]
    }

    private struct Attempts {
        let windowID: UInt32
        let processID: Int32
        var count: Int
        var nextDate: TimeInterval
    }

    enum StoreError: Error {
        case unsupportedVersion
        case invalidRecords
    }

    static let defaultsKey = "MenuBarItemSectionsV1"
    static let maxAutomaticallyLearnedItems = 256

    private let defaults: UserDefaults
    private var sections: [Identity: Section] = [:]
    private var attempts: [Identity: Attempts] = [:]
    private var snapshot: [Item]?
    private var snapshotDate: TimeInterval = 0

    init(defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw StoreError.unsupportedVersion
            }
            for record in document.records {
                guard
                    !record.identity.bundleIdentifier.isEmpty,
                    sections[record.identity] == nil
                else {
                    throw StoreError.invalidRecords
                }
                sections[record.identity] = record.section
            }
        } else if defaults.object(forKey: Self.defaultsKey) != nil {
            throw StoreError.invalidRecords
        }
    }

    func section(for identity: Identity) -> Section? {
        sections[identity]
    }

    var savedItemCount: Int {
        sections.count
    }

    /// Called only for an explicit user move, or before a temporary move.
    func remember(_ identity: Identity, in section: Section) throws {
        guard !identity.bundleIdentifier.isEmpty else {
            return
        }
        var updated = sections
        updated[identity] = section
        try persist(updated)
        attempts.removeValue(forKey: identity)
        invalidateSnapshot()
    }

    func invalidateSnapshot() {
        snapshot = nil
    }

    /// A stable observation may learn new items, but must never overwrite known intent.
    /// A returned restore reserves one of three attempts for this window's lifetime.
    func observe(
        _ items: [Item],
        now: TimeInterval,
        excludedWindowIDs: Set<UInt32> = [],
        userChangedIdentities: Set<Identity> = [],
        acceptAllChanges: Bool = false,
        alwaysHiddenEnabled: Bool = true,
        allowRestore: Bool = true
    ) throws -> Observation {
        let current = items.sorted { $0.windowID < $1.windowID }
        guard snapshot == current else {
            snapshot = current
            snapshotDate = now
            return Observation(isSettled: false, restore: nil)
        }
        guard now - snapshotDate >= 1 else {
            return Observation(isSettled: false, restore: nil)
        }

        // Never guess which of two identically named icons owns a saved setting.
        let groups = Dictionary(grouping: current, by: \.identity)
        let currentIdentities = Set(groups.keys)
        attempts = attempts.filter { currentIdentities.contains($0.key) }
        let eligible = current.filter {
            !$0.identity.bundleIdentifier.isEmpty &&
            groups[$0.identity]?.count == 1 &&
            !excludedWindowIDs.contains($0.windowID)
        }
        var updated = sections
        for item in eligible {
            if acceptAllChanges || userChangedIdentities.contains(item.identity) {
                updated[item.identity] = item.section
                attempts.removeValue(forKey: item.identity)
            } else if
                updated[item.identity] == nil,
                updated.count < Self.maxAutomaticallyLearnedItems
            {
                updated[item.identity] = item.section
            }
        }
        try persist(updated)

        guard allowRestore else {
            return Observation(isSettled: true, restore: nil)
        }
        for item in eligible {
            guard let desired = sections[item.identity], desired != item.section else {
                continue
            }
            if desired == .alwaysHidden && !alwaysHiddenEnabled {
                continue
            }
            var retry = attempts[item.identity] ?? Attempts(
                windowID: item.windowID, processID: item.processID, count: 0, nextDate: 0
            )
            if retry.windowID != item.windowID || retry.processID != item.processID {
                retry = Attempts(windowID: item.windowID, processID: item.processID, count: 0, nextDate: 0)
            }
            guard retry.count < 3, now >= retry.nextDate else {
                continue
            }
            retry.count += 1
            retry.nextDate = now + (retry.count == 1 ? 5 : 15)
            attempts[item.identity] = retry
            return Observation(isSettled: true, restore: Restore(item: item, section: desired))
        }
        return Observation(isSettled: true, restore: nil)
    }

    private func persist(_ updated: [Identity: Section]) throws {
        guard updated != sections else {
            return
        }
        let records = updated.map { Record(identity: $0.key, section: $0.value) }.sorted {
            if $0.identity.bundleIdentifier != $1.identity.bundleIdentifier {
                return $0.identity.bundleIdentifier < $1.identity.bundleIdentifier
            }
            return $0.identity.title < $1.identity.title
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, records: records))
        defaults.set(data, forKey: Self.defaultsKey)
        sections = updated
    }
}
