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
        case .small: 14
        case .medium: 16
        case .large: 17
        @unknown default: 16
        }
    }

    private var sidebarIconFrameSize: CGFloat {
        switch sidebarRowSize {
        case .small: 18
        case .medium: 20
        case .large: 22
        @unknown default: 20
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
        HStack(spacing: 10) {
            Image(systemName: iconName(for: identifier))
                .font(.system(size: sidebarIconSize, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(
                    navigationState.settingsNavigationIdentifier == identifier
                        ? Color.white
                        : Color.accentColor
                )
                .frame(width: sidebarIconFrameSize, height: sidebarIconFrameSize)
                .accessibilityHidden(true)

            Text(identifier.localized)
        }
        .font(.body)
        .frame(height: sidebarItemHeight)
    }

    private func iconName(for identifier: SettingsNavigationIdentifier) -> String {
        switch identifier {
        case .general: "gearshape"
        case .menuBarLayout: "rectangle.topthird.inset"
        case .menuBarAppearance: "paintpalette"
        case .hotkeys: "keyboard"
        case .advanced: "slider.horizontal.3"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }
}
