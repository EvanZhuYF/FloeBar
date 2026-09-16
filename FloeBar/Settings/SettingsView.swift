//
//  SettingsView.swift
//  FloeBar
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var navigationState: AppNavigationState
    @Environment(\.sidebarRowSize) var sidebarRowSize

    private var sidebarWidth: CGFloat {
        switch sidebarRowSize {
        case .small: 190
        case .medium: 210
        case .large: 230
        @unknown default: 210
        }
    }

    private var sidebarItemHeight: CGFloat {
        switch sidebarRowSize {
        case .small: 26
        case .medium: 32
        case .large: 34
        @unknown default: 32
        }
    }

    private var sidebarIconSize: CGFloat {
        switch sidebarRowSize {
        case .small: 20
        case .medium: 24
        case .large: 26
        @unknown default: 24
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle(navigationState.settingsNavigationIdentifier.localized)
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $navigationState.settingsNavigationIdentifier) {
            Section {
                ForEach(SettingsNavigationIdentifier.allCases, id: \.self) { identifier in
                    sidebarItem(for: identifier)
                }
            } header: {
                Text("FloeBar")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 4)
            }
            .collapsible(false)
        }
        .scrollDisabled(true)
        .removeSidebarToggle()
        .navigationSplitViewColumnWidth(sidebarWidth)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigationState.settingsNavigationIdentifier {
        case .general:
            GeneralSettingsPane()
        case .menuBarLayout:
            MenuBarLayoutSettingsPane()
        case .menuBarAppearance:
            MenuBarAppearanceSettingsPane()
        case .hotkeys:
            HotkeysSettingsPane()
        case .advanced:
            AdvancedSettingsPane()
        case .updates:
            UpdatesSettingsPane()
        case .about:
            AboutSettingsPane()
        }
    }

    @ViewBuilder
    private func sidebarItem(for identifier: SettingsNavigationIdentifier) -> some View {
        Label {
            Text(identifier.localized)
        } icon: {
            let icon = icon(for: identifier)
            Image(systemName: icon.systemName)
                .font(.system(size: sidebarIconSize * 0.52, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: sidebarIconSize, height: sidebarIconSize)
                .background(
                    icon.backgroundColor,
                    in: RoundedRectangle(cornerRadius: sidebarIconSize * 0.23, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: sidebarIconSize * 0.23, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 0.75, y: 0.5)
                .accessibilityHidden(true)
        }
        .font(.body)
        .frame(height: sidebarItemHeight)
    }

    private func icon(for identifier: SettingsNavigationIdentifier) -> SettingsSidebarIcon {
        switch identifier {
        case .general:
            SettingsSidebarIcon(systemName: "gearshape.fill", backgroundColor: Color(nsColor: .systemGray))
        case .menuBarLayout:
            SettingsSidebarIcon(
                systemName: "rectangle.topthird.inset.filled",
                backgroundColor: Color(nsColor: .systemBlue)
            )
        case .menuBarAppearance:
            SettingsSidebarIcon(systemName: "paintpalette.fill", backgroundColor: Color(nsColor: .systemPurple))
        case .hotkeys:
            SettingsSidebarIcon(systemName: "keyboard", backgroundColor: Color(nsColor: .systemIndigo))
        case .advanced:
            SettingsSidebarIcon(systemName: "gearshape.2.fill", backgroundColor: Color(nsColor: .systemOrange))
        case .updates:
            SettingsSidebarIcon(systemName: "arrow.down.circle.fill", backgroundColor: Color(nsColor: .systemGreen))
        case .about:
            SettingsSidebarIcon(systemName: "info.circle.fill", backgroundColor: Color(nsColor: .systemTeal))
        }
    }
}

private struct SettingsSidebarIcon {
    let systemName: String
    let backgroundColor: Color
}
