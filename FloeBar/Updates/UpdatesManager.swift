//
//  UpdatesManager.swift
//  FloeBar
//

import Sparkle
import SwiftUI

/// Manager for app updates.
@MainActor
final class UpdatesManager: NSObject, ObservableObject {
    /// A Boolean value that indicates whether the user can check for updates.
    @Published var canCheckForUpdates = false

    /// The date of the last update check.
    @Published var lastUpdateCheckDate: Date?

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The underlying updater controller.
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: updatesAreEnabled,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    /// The underlying updater.
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// Local packages must not replace themselves with an upstream release.
    var isLocalBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "IceLocalBuild") as? Bool == true
    }

    /// A Boolean value that indicates whether a Sparkle update feed is configured.
    ///
    /// FloeBar ships without the upstream Ice feed, so updates stay disabled
    /// until a FloeBar `SUFeedURL` is added to the bundle's Info.plist.
    var hasUpdateFeed: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A Boolean value that indicates whether in-app updates are available.
    ///
    /// Updates are disabled for local builds and whenever no update feed is
    /// configured, so FloeBar never pulls an upstream Ice release over itself.
    var updatesAreEnabled: Bool {
        !isLocalBuild && hasUpdateFeed
    }

    /// A Boolean value that indicates whether to automatically check for updates.
    var automaticallyChecksForUpdates: Bool {
        get {
            updatesAreEnabled && updater.automaticallyChecksForUpdates
        }
        set {
            guard updatesAreEnabled else { return }
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// A Boolean value that indicates whether to automatically download updates.
    var automaticallyDownloadsUpdates: Bool {
        get {
            updatesAreEnabled && updater.automaticallyDownloadsUpdates
        }
        set {
            guard updatesAreEnabled else { return }
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Creates an updates manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Sets up the manager.
    func performSetup() {
        guard updatesAreEnabled else { return }
        _ = updaterController
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }

    /// Checks for app updates.
    @objc func checkForUpdates() {
        guard updatesAreEnabled else {
            let alert = NSAlert()
            alert.messageText = String(localized: "In-app updates are not available in this build of FloeBar.")
            alert.informativeText = String(localized: "Download the latest FloeBar build to keep your custom changes.")
            alert.runModal()
            return
        }
        #if DEBUG
        // Checking for updates hangs in debug mode.
        let alert = NSAlert()
        alert.messageText = String(localized: "Checking for updates is not supported in debug mode.")
        alert.runModal()
        #else
        guard let appState else {
            return
        }
        // Activate the app in case an alert needs to be displayed.
        appState.activate(withPolicy: .regular)
        appState.openSettingsWindow()
        updater.checkForUpdates()
        #endif
    }
}

// MARK: UpdatesManager: SPUUpdaterDelegate
extension UpdatesManager: @preconcurrency SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        guard let appState else {
            return
        }
        appState.userNotificationManager.requestAuthorization()
    }
}

// MARK: UpdatesManager: SPUStandardUserDriverDelegate
extension UpdatesManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        if NSApp.isActive {
            return immediateFocus
        } else {
            return false
        }
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard let appState else {
            return
        }
        if !state.userInitiated {
            appState.userNotificationManager.addRequest(
                with: .updateCheck,
                title: String(localized: "A new update is available"),
                body: String(localized: "Version \(update.displayVersionString) is now available")
            )
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        guard let appState else {
            return
        }
        appState.userNotificationManager.removeDeliveredNotifications(with: [.updateCheck])
    }
}

// MARK: UpdatesManager: BindingExposable
extension UpdatesManager: BindingExposable { }
