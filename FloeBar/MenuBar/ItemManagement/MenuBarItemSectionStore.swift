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
        let instanceIndex: Int

        init(
            bundleIdentifier: String,
            title: String,
            instanceIndex: Int = 0
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.title = title
            self.instanceIndex = instanceIndex
        }

        private enum CodingKeys: String, CodingKey {
            case bundleIdentifier, title, instanceIndex
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
            title = try container.decode(String.self, forKey: .title)
            instanceIndex = try container.decodeIfPresent(
                Int.self,
                forKey: .instanceIndex
            ) ?? 0
        }
    }

    /// An ordinal is not evidence that two same-title windows survive a relaunch.
    private struct Group: Codable, Hashable {
        let bundleIdentifier: String
        let title: String

        init(_ identity: Identity) {
            bundleIdentifier = identity.bundleIdentifier
            title = identity.title
        }
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
        var ambiguousGroups: Set<Group>?
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
    private var ambiguousGroups: Set<Group> = []
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
            ambiguousGroups = document.ambiguousGroups ?? []
            // Older documents could store duplicate ordinals as independent intent.
            try noteIdentities(Array(sections.keys))
        } else if defaults.object(forKey: Self.defaultsKey) != nil {
            throw StoreError.invalidRecords
        }
    }

    func section(for identity: Identity) -> Section? {
        guard !ambiguousGroups.contains(Group(identity)) else {
            return nil
        }
        return sections[identity]
    }

    var savedItemCount: Int {
        sections.count
    }

    /// Called only for an explicit user move, or before a temporary move.
    func remember(_ identity: Identity, in section: Section) throws {
        try noteIdentities([identity])
        guard !identity.bundleIdentifier.isEmpty else {
            return
        }
        guard !ambiguousGroups.contains(Group(identity)) else {
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

    /// Record ambiguity before settling or excluding temporarily shown windows.
    /// Keep tombstones across launches so a later singleton cannot steal index zero.
    func noteIdentities(_ identities: [Identity]) throws {
        let groups = Dictionary(grouping: identities.filter { !$0.bundleIdentifier.isEmpty }, by: Group.init)
        let discovered = groups.compactMap { group, identities in
            identities.count > 1 || identities.contains(where: { $0.instanceIndex > 0 }) ? group : nil
        }
        let updated = ambiguousGroups.union(discovered)
        try persist(sections, ambiguousGroups: updated)
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
        try noteIdentities(items.map(\.identity))
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
        let currentIdentities = Set(current.map(\.identity))
        attempts = attempts.filter { currentIdentities.contains($0.key) }
        let eligible = current.filter {
            !$0.identity.bundleIdentifier.isEmpty &&
            !ambiguousGroups.contains(Group($0.identity)) &&
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

    private func persist(
        _ updated: [Identity: Section],
        ambiguousGroups updatedGroups: Set<Group>? = nil
    ) throws {
        let updatedGroups = updatedGroups ?? ambiguousGroups
        guard updated != sections || updatedGroups != ambiguousGroups else {
            return
        }
        let records = updated.map { Record(identity: $0.key, section: $0.value) }.sorted {
            if $0.identity.bundleIdentifier != $1.identity.bundleIdentifier {
                return $0.identity.bundleIdentifier < $1.identity.bundleIdentifier
            }
            if $0.identity.title != $1.identity.title {
                return $0.identity.title < $1.identity.title
            }
            return $0.identity.instanceIndex < $1.identity.instanceIndex
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, records: records, ambiguousGroups: updatedGroups))
        defaults.set(data, forKey: Self.defaultsKey)
        sections = updated
        ambiguousGroups = updatedGroups
    }
}
