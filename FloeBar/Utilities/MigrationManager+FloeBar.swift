//
//  MigrationManager+FloeBar.swift
//  FloeBar
//

import Foundation

// MARK: - Migrate From Ice

extension MigrationManager {
    /// The bundle identifier of the upstream Ice app that FloeBar is based on.
    private static let iceBundleIdentifier = "com.jordanbaird.Ice"

    /// Imports the user's existing settings from an installed Ice app the first
    /// time FloeBar launches.
    ///
    /// FloeBar uses its own bundle identifier, so it starts with an empty
    /// `UserDefaults` domain. To keep upgrading users' menu bar layout, section
    /// persistence, and preferences, this copies every key from Ice's domain
    /// into FloeBar's domain exactly once. It never overwrites values the user
    /// has already changed in FloeBar, and it is skipped entirely once the
    /// one-time flag is set.
    static func migrateFromIce() {
        guard !Defaults.bool(forKey: .hasMigratedFromIce) else {
            return
        }

        let defaults = UserDefaults.standard

        // Only import when FloeBar has no settings of its own yet. If the user
        // has already configured FloeBar, leave their data untouched.
        let hasExistingFloeBarSettings = Defaults.data(forKey: .menuBarAppearanceConfigurationV2) != nil
            || Defaults.data(forKey: .sections) != nil
            || Defaults.object(forKey: .hotkeys) != nil

        if
            !hasExistingFloeBarSettings,
            let iceDomain = defaults.persistentDomain(forName: iceBundleIdentifier),
            !iceDomain.isEmpty
        {
            for (key, value) in iceDomain {
                // Never clobber a value FloeBar already has.
                guard defaults.object(forKey: key) == nil else {
                    continue
                }
                defaults.set(value, forKey: key)
            }
            Logger.iceMigration.info("Imported \(iceDomain.count) settings from Ice")
        }

        Defaults.set(true, forKey: .hasMigratedFromIce)
    }
}

// MARK: - Logger

private extension Logger {
    static let iceMigration = Logger(category: "IceMigration")
}
