//
//  MenuBarAppearanceSettingsPane.swift
//  FloeBar
//

import SwiftUI

struct MenuBarAppearanceSettingsPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        MenuBarAppearanceEditor(location: .settings)
            .environmentObject(appState.appearanceManager)
    }
}

#Preview {
    MenuBarAppearanceSettingsPane()
        .environmentObject(AppState())
}
