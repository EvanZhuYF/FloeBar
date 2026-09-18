//
//  AdvancedSettingsPane.swift
//  FloeBar
//

import SwiftUI

struct AdvancedSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var maxSliderLabelWidth: CGFloat = 0
    @State private var currentLogFileName: String?

    private var menuBarManager: MenuBarManager {
        appState.menuBarManager
    }

    private var manager: AdvancedSettingsManager {
        appState.settingsManager.advancedSettingsManager
    }

    private func formattedToSeconds(_ interval: TimeInterval) -> LocalizedStringKey {
        let formatted = interval.formatted()
        let unit = if interval == 1 {
            String(localized: "second")
        } else {
            String(localized: "seconds")
        }
        return LocalizedStringKey(formatted + " " + unit)
    }

    var body: some View {
        IceForm {
            IceSection {
                hideApplicationMenus
                if !appState.settingsManager.generalSettingsManager.useIceBar {
                    showSectionDividers
                }
                showAllSectionsOnUserDrag
            }
            IceSection {
                enableAlwaysHiddenSection
                canToggleAlwaysHiddenSection
            }
            IceSection {
                showOnHoverDelaySlider
                tempShowIntervalSlider
            }
            IceSection("Diagnostics") {
                diagnosticLogging
            }
        }
    }

    @ViewBuilder
    private var hideApplicationMenus: some View {
        Toggle("Hide application menus when showing menu bar items", isOn: manager.bindings.hideApplicationMenus)
            .annotation("Make more room in the menu bar by hiding the left application menus if needed")
    }

    @ViewBuilder
    private var showSectionDividers: some View {
        Toggle("Show section dividers", isOn: manager.bindings.showSectionDividers)
            .annotation {
                HStack(spacing: 2) {
                    Text("Insert divider items")
                    if let nsImage = ControlItemImage.builtin(.chevronLarge).nsImage(for: appState) {
                        HStack(spacing: 0) {
                            Text("(")
                                .font(.body.monospaced().bold())
                            Image(nsImage: nsImage)
                                .padding(.horizontal, -2)
                            Text(")")
                                .font(.body.monospaced().bold())
                        }
                    }
                    Text("between sections")
                }
            }
    }

    @ViewBuilder
    private var enableAlwaysHiddenSection: some View {
        Toggle("Enable always-hidden section", isOn: manager.bindings.enableAlwaysHiddenSection)
    }

    @ViewBuilder
    private var canToggleAlwaysHiddenSection: some View {
        if manager.enableAlwaysHiddenSection {
            Toggle("Always-hidden section can be shown", isOn: manager.bindings.canToggleAlwaysHiddenSection)
                .annotation {
                    if appState.settingsManager.generalSettingsManager.showOnClick {
                        Text("Option + click one of FloeBar's menu bar items, or inside an empty area of the menu bar to show the section")
                    } else {
                        Text("Option + click one of FloeBar's menu bar items to show the section")
                    }
                }
        }
    }

    @ViewBuilder
    private var showOnHoverDelaySlider: some View {
        IceLabeledContent {
            IceSlider(
                formattedToSeconds(manager.showOnHoverDelay),
                value: manager.bindings.showOnHoverDelay,
                in: 0...1,
                step: 0.1
            )
        } label: {
            Text("Show on hover delay")
                .frame(minHeight: .compactSliderMinHeight)
                .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                .onFrameChange { frame in
                    maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                }
        }
        .annotation("The amount of time to wait before showing on hover")
    }

    @ViewBuilder
    private var tempShowIntervalSlider: some View {
        IceLabeledContent {
            IceSlider(
                formattedToSeconds(manager.tempShowInterval),
                value: manager.bindings.tempShowInterval,
                in: 0...30,
                step: 1
            )
        } label: {
            Text("Temporarily shown item delay")
                .frame(minHeight: .compactSliderMinHeight)
                .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                .onFrameChange { frame in
                    maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                }
        }
        .annotation("The amount of time to wait before hiding temporarily shown menu bar items")
    }

    @ViewBuilder
    private var showAllSectionsOnUserDrag: some View {
        Toggle("Show all sections when Command + dragging menu bar items", isOn: manager.bindings.showAllSectionsOnUserDrag)
    }

    @ViewBuilder
    private var diagnosticLogging: some View {
        Toggle("Enable diagnostic logging", isOn: manager.bindings.enableDiagnosticLogging)
            .annotation("Writes detailed logs to a file for troubleshooting. Log files are saved to ~/Library/Logs/FloeBar/. Disable when not needed to avoid unnecessary disk writes.")

        if manager.enableDiagnosticLogging || DiagnosticLogger.shared.hasLogFiles {
            IceLabeledContent {
                Button("Show Log Files in Finder") {
                    NSWorkspace.shared.open(DiagnosticLogger.shared.logDirectory)
                }
            } label: {
                if let currentLogFileName {
                    Text(currentLogFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: manager.enableDiagnosticLogging) {
                // Let the Combine sink create/close the log file first.
                try? await Task.sleep(for: .milliseconds(50))
                currentLogFileName = (
                    DiagnosticLogger.shared.currentLogFile ?? DiagnosticLogger.shared.latestLogFile
                )?.lastPathComponent
            }
        }
    }
}

#Preview {
    AdvancedSettingsPane()
        .fixedSize()
        .environmentObject(AppState())
}
