//
//  UpdatesSettingsPane.swift
//  FloeBar
//

import SwiftUI

struct UpdatesSettingsPane: View {
    @EnvironmentObject var appState: AppState

    private var updatesManager: UpdatesManager {
        appState.updatesManager
    }

    private var lastUpdateCheckString: String {
        if let date = updatesManager.lastUpdateCheckDate {
            date.formatted(date: .abbreviated, time: .standard)
        } else {
            String(localized: "Never")
        }
    }

    var body: some View {
        IceForm {
            IceSection {
                automaticallyCheckForUpdates
                automaticallyDownloadUpdates
            }
            .disabled(!updatesManager.updatesAreEnabled)
            if updatesManager.canCheckForUpdates {
                IceSection {
                    checkForUpdates
                }
            }
        }
    }

    @ViewBuilder
    private var automaticallyCheckForUpdates: some View {
        Toggle(
            "Automatically check for updates",
            isOn: updatesManager.bindings.automaticallyChecksForUpdates
        )
    }

    @ViewBuilder
    private var automaticallyDownloadUpdates: some View {
        Toggle(
            "Automatically download updates",
            isOn: updatesManager.bindings.automaticallyDownloadsUpdates
        )
    }

    @ViewBuilder
    private var checkForUpdates: some View {
        HStack {
            Button("Check for Updates…") {
                updatesManager.checkForUpdates()
            }
            .controlSize(.large)

            Spacer()

            HStack(spacing: 2) {
                Text("Last checked:")
                Text(lastUpdateCheckString)
            }
            .lineLimit(1)
            .font(.caption)
        }
    }
}
