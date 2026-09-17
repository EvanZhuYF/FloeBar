//
//  LayoutBarStyle.swift
//  FloeBar
//

import SwiftUI

extension View {
    /// Returns a view that is drawn in the style of a layout bar.
    ///
    /// - Note: The view this modifier is applied to must be transparent, or the style
    ///   will be drawn incorrectly.
    @ViewBuilder
    func layoutBarStyle(
        appState: AppState,
        averageColorInfo: MenuBarAverageColorInfo?,
        backgroundOpacity: Double = 1,
        prefersHighContrastBackground: Bool = false
    ) -> some View {
        background {
            Group {
                if appState.isActiveSpaceFullscreen {
                    Color.black
                } else if let averageColorInfo {
                    let useDarkFallback = prefersHighContrastBackground && (averageColorInfo.color.brightness ?? 0) > 0.67
                    switch averageColorInfo.source {
                    case .menuBarWindow:
                        Group {
                            if useDarkFallback {
                                Color(.sRGB, white: 0.22, opacity: 1)
                            } else {
                                Color(cgColor: averageColorInfo.color)
                            }
                        }
                            .overlay(
                                Material.bar
                                    .opacity(0.2)
                                    .blendMode(.softLight)
                            )
                    case .desktopWallpaper:
                        Group {
                            if useDarkFallback {
                                Color(.sRGB, white: 0.22, opacity: 1)
                            } else {
                                Color(cgColor: averageColorInfo.color)
                            }
                        }
                            .overlay(
                                Material.bar
                                    .opacity(0.5)
                                    .blendMode(.softLight)
                            )
                    }
                } else {
                    Color.defaultLayoutBar
                }
            }
            .opacity(backgroundOpacity)
        }
        .overlay {
            if !appState.isActiveSpaceFullscreen {
                switch appState.appearanceManager.configuration.current.tintKind {
                case .none:
                    EmptyView()
                case .solid:
                    Color(cgColor: appState.appearanceManager.configuration.current.tintColor)
                        .opacity(0.2 * backgroundOpacity)
                        .allowsHitTesting(false)
                case .gradient:
                    appState.appearanceManager.configuration.current.tintGradient
                        .opacity(0.2 * backgroundOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
