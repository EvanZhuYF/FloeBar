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

    private struct DisplaySample {
        let image: CGImage
        let screenFrame: CGRect
        let spaceID: CGSSpaceID
        var lastUsed: ContinuousClock.Instant
    }

    private var displaySamples = [CGDirectDisplayID: DisplaySample]()
    private var windowImageDisplayID: CGDirectDisplayID?
    private var windowImageSpaceID: CGSSpaceID?
    private static let maximumDisplaySamples = 4

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
                        iceBarPanel.isVisible
                    else {
                        return
                    }
                    updateAllProperties(with: iceBarPanel.frame, screen: screen)
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
                    windowImageDisplayID = nil
                    windowImageSpaceID = nil
                    colorInfo = nil
                    return
                }
                guard
                    let screen = iceBarPanel.screen
                else {
                    return
                }
                if windowImage == nil || windowImageDisplayID != screen.displayID {
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
                    return Timer.publish(every: 15, on: .main, in: .default)
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
                    iceBarPanel.isVisible
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
        let connectedDisplays = Set(NSScreen.screens.map(\.displayID))
        displaySamples = displaySamples.filter { connectedDisplays.contains($0.key) }
        windowImage = nil
        windowImageDisplayID = displayID
        windowImageSpaceID = nil
        guard let spaceID = Bridging.currentSpaceID(for: displayID) else {
            displaySamples.removeValue(forKey: displayID)
            return
        }
        windowImageSpaceID = spaceID
        if
            var sample = displaySamples[displayID],
            sample.screenFrame == screen.frame,
            sample.spaceID == spaceID
        {
            sample.lastUsed = .now
            displaySamples[displayID] = sample
            windowImage = sample.image
        }
        guard ScreenCapture.claimLegacyCapture(
            for: "ice-bar-color-\(displayID)"
        ) else {
            return
        }
        // Once a refresh is allowed, the old sample must not mask a failure.
        displaySamples.removeValue(forKey: displayID)
        windowImage = nil
        let windows = WindowInfo.getOnScreenWindows(excludeDesktopWindows: false)
        guard let menuBarWindow = WindowInfo.getMenuBarWindow(
            from: windows,
            for: displayID
        ) else {
            windowImage = nil
            return
        }

        let image: CGImage?
        if #available(macOS 26.0, *),
           let wallpaperWindow = WindowInfo.getWallpaperWindow(
               from: windows,
               for: displayID
           )
        {
            image = ScreenCapture.captureWindows(
                [menuBarWindow.windowID, wallpaperWindow.windowID],
                screenBounds: menuBarWindow.frame,
                option: .nominalResolution
            )
        } else {
            image = ScreenCapture.captureWindow(
                menuBarWindow.windowID,
                option: .nominalResolution
            )
        }
        if let image {
            windowImage = image
            displaySamples[displayID] = DisplaySample(
                image: image,
                screenFrame: screen.frame,
                spaceID: spaceID,
                lastUsed: .now
            )
            while displaySamples.count > Self.maximumDisplaySamples {
                guard let oldest = displaySamples.min(by: {
                    $0.value.lastUsed < $1.value.lastUsed
                })?.key else {
                    break
                }
                displaySamples.removeValue(forKey: oldest)
            }
        } else {
            windowImage = nil
        }
    }

    private func updateColorInfo(with frame: CGRect, screen: NSScreen) {
        guard
            let windowImage,
            windowImageDisplayID == screen.displayID,
            let windowImageSpaceID,
            Bridging.currentSpaceID(for: screen.displayID) == windowImageSpaceID
        else {
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
