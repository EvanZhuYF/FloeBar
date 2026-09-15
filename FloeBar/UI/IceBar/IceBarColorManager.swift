//
//  IceBarColorManager.swift
//  FloeBar
//

import Cocoa
import Combine

final class IceBarColorManager: ObservableObject {
    @Published private(set) var colorInfo: MenuBarAverageColorInfo?

    private weak var iceBarPanel: IceBarPanel?

    private var windowImage: CGImage?

    private var cancellables = Set<AnyCancellable>()

    init(iceBarPanel: IceBarPanel) {
        self.iceBarPanel = iceBarPanel
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let iceBarPanel {
            iceBarPanel.publisher(for: \.screen)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] screen in
                    guard
                        let self,
                        let screen,
                        iceBarPanel.isVisible,
                        screen == .main
                    else {
                        return
                    }
                    updateWindowImage(for: screen)
                }
                .store(in: &c)

            Publishers.CombineLatest(
                iceBarPanel.publisher(for: \.frame),
                iceBarPanel.publisher(for: \.isVisible)
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame, isVisible in
                guard let self else {
                    return
                }
                guard isVisible else {
                    windowImage = nil
                    colorInfo = nil
                    return
                }
                guard
                    let screen = iceBarPanel.screen,
                    screen == .main
                else {
                    return
                }
                if windowImage == nil {
                    updateWindowImage(for: screen)
                }
                updateColorInfo(with: frame, screen: screen)
            }
            .store(in: &c)

            let visibleRefreshTimer = iceBarPanel.publisher(for: \.isVisible)
                .removeDuplicates()
                .map { isVisible -> AnyPublisher<Void, Never> in
                    guard isVisible else {
                        return Empty().eraseToAnyPublisher()
                    }
                    return Timer.publish(every: 5, on: .main, in: .default)
                        .autoconnect()
                        .mapToVoid()
                        .eraseToAnyPublisher()
                }
                .switchToLatest()

            Publishers.Merge4(
                NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                    .mapToVoid(),
                NotificationCenter.default
                    .publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .mapToVoid(),
                DistributedNotificationCenter.default()
                    .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
                    .mapToVoid(),
                visibleRefreshTimer
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak iceBarPanel] in
                guard
                    let self,
                    let iceBarPanel,
                    let screen = iceBarPanel.screen,
                    iceBarPanel.isVisible,
                    screen == .main
                else {
                    return
                }
                updateWindowImage(for: screen)
                updateColorInfo(with: iceBarPanel.frame, screen: screen)
            }
            .store(in: &c)
        }

        cancellables = c
    }

    private func updateWindowImage(for screen: NSScreen) {
        let displayID = screen.displayID
        if
            let window = WindowInfo.getMenuBarWindow(for: displayID),
            let image = ScreenCapture.captureWindow(window.windowID, option: .nominalResolution)
        {
            windowImage = image
        } else {
            windowImage = nil
        }
    }

    private func updateColorInfo(with frame: CGRect, screen: NSScreen) {
        guard let windowImage else {
            colorInfo = nil
            return
        }

        let imageBounds = CGRect(x: 0, y: 0, width: windowImage.width, height: windowImage.height)
        let insetScreenFrame = screen.frame.insetBy(dx: frame.width / 2, dy: 0)
        let percentage = ((frame.midX - insetScreenFrame.minX) / insetScreenFrame.width).clamped(to: 0...1)
        let cropRect = CGRect(x: imageBounds.width * percentage, y: 0, width: 0, height: 1)
            .insetBy(dx: -50, dy: 0)
            .intersection(imageBounds)

        guard
            let croppedImage = windowImage.cropping(to: cropRect),
            let averageColor = croppedImage.averageColor(resolution: .low)
        else {
            colorInfo = nil
            return
        }

        colorInfo = MenuBarAverageColorInfo(color: averageColor, source: .menuBarWindow)
    }

    func updateAllProperties(with frame: CGRect, screen: NSScreen) {
        updateWindowImage(for: screen)
        updateColorInfo(with: frame, screen: screen)
    }
}
