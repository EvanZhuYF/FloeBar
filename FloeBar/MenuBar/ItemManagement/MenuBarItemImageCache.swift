//
//  MenuBarItemImageCache.swift
//  FloeBar
//

import Cocoa
import Combine

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    struct CachedImage: Equatable {
        let cgImage: CGImage
        let pixelScale: CGFloat

        init?(cgImage: CGImage, pixelScale: CGFloat) {
            guard
                pixelScale.isFinite,
                pixelScale > 0,
                !cgImage.isTransparent(maxAlpha: 0.02)
            else {
                return nil
            }
            self.cgImage = cgImage
            self.pixelScale = pixelScale
        }

        var nsImage: NSImage {
            NSImage(
                cgImage: cgImage,
                size: CGSize(
                    width: CGFloat(cgImage.width) / pixelScale,
                    height: CGFloat(cgImage.height) / pixelScale
                )
            )
        }
    }

    /// The cached item images.
    @Published private(set) var images = [CGWindowID: CachedImage]()

    /// The screen of the cached item images.
    private(set) var screen: NSScreen?

    /// The height of the menu bar of the cached item images.
    private(set) var menuBarHeight: CGFloat?

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Coalesces timer and notification bursts into the latest cache refresh.
    private var scheduledUpdateTask: Task<Void, Never>?

    /// Prevents periodic refresh work from overlapping a previous timer tick.
    private var periodicUpdateTask: Task<Void, Never>?

    /// Only the latest refresh may publish captured images.
    private var updateGeneration = 0

    /// Avoids repeatedly probing a transparent ScreenCaptureKit result on macOS 15.
    private var visibleItemsRequireLegacyCapture = false

    /// Creates a cache with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the cache.
    @MainActor
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Timer.publish(every: 15, on: .main, in: .default)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    periodicUpdateTask?.cancel()
                    periodicUpdateTask = Task.detached { [weak self] in
                        await self?.updateCacheForTimer()
                    }
                }
                .store(in: &c)

            Publishers.Merge(
                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .mapToVoid(),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().mapToVoid(),
                    appState.itemManager.$itemCache.removeDuplicates().mapToVoid()
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                scheduledUpdateTask?.cancel()
                scheduledUpdateTask = Task.detached { [weak self] in
                    await self?.updateCache()
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.imageCache.debug("Skipping menu bar item image cache as \(reason)")
    }

    /// Returns a Boolean value that indicates whether caching menu bar items failed for
    /// the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        let items = appState?.itemManager.itemCache.managedItems(for: section) ?? []
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.windowID) {
            return false
        }
        return true
    }

    /// Captures the images of the current menu bar items and returns a dictionary containing
    /// the images, keyed by the current menu bar item window identifiers.
    func createImages(
        for section: MenuBarSection.Name,
        screen: NSScreen
    ) async -> [CGWindowID: CachedImage]? {
        guard !Task.isCancelled else {
            return nil
        }
        guard let appState else {
            return [:]
        }

        let items = await appState.itemManager.itemCache[section]
        guard !Task.isCancelled else {
            return nil
        }

        var images = [CGWindowID: CachedImage]()
        let displayBounds = CGDisplayBounds(screen.displayID)
        let option: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]

        var itemFrames = [CGWindowID: CGRect]()
        var windowIDs = [CGWindowID]()
        var captureWindows = [MenuBarCaptureService.Window]()
        var expectedCaptureWindows = [
            CGWindowID: MenuBarCaptureService.Window
        ]()
        var frame = CGRect.null

        let requestedWindowIDs = items.map(\.windowID)
        let freshWindowsByID = Dictionary(
            WindowInfo.createWindows(from: requestedWindowIDs).map {
                ($0.windowID, $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for windowID in requestedWindowIDs {
            guard !Task.isCancelled else {
                return nil
            }
            guard
                let window = freshWindowsByID[windowID],
                window.isMenuBarItem,
                let captureWindow = MenuBarCaptureService.Window(
                    windowID: window.windowID,
                    ownerPID: window.ownerPID,
                    title: window.title,
                    layer: window.layer,
                    bounds: window.frame
                ),
                window.frame.minY == displayBounds.minY
            else {
                continue
            }
            let itemFrame = window.frame
            itemFrames[windowID] = itemFrame
            windowIDs.append(windowID)
            captureWindows.append(captureWindow)
            expectedCaptureWindows[windowID] = captureWindow
            frame = frame.union(itemFrame)
        }

        guard !windowIDs.isEmpty else {
            return [:]
        }

        if #available(macOS 26.0, *), section != .visible {
            guard ScreenCapture.claimLegacyCapture(
                for: "item-cache-\(section.logString)"
            ) else {
                return nil
            }
            return await createImagesWithCaptureService(
                windows: captureWindows,
                expectedWindows: expectedCaptureWindows,
                expectedScale: screen.backingScaleFactor,
                option: option
            )
        }

        var compositeImage: CGImage?
        if section == .visible {
            let shouldTryScreenCaptureKit: Bool
            if #available(macOS 15.0, *) {
                if #unavailable(macOS 26.0) {
                    shouldTryScreenCaptureKit = await MainActor.run {
                        !visibleItemsRequireLegacyCapture
                    }
                } else {
                    shouldTryScreenCaptureKit = true
                }
            } else {
                shouldTryScreenCaptureKit = true
            }
            if shouldTryScreenCaptureKit {
                compositeImage = await ScreenCapture.captureWindowsOnScreen(
                    windowIDs,
                    option: option
                )
                guard !Task.isCancelled else {
                    return nil
                }
            }
            // On macOS 15, ScreenCaptureKit can return a successful but fully
            // transparent image for visible menu bar items.
            let sckCompositeIsTransparent =
                compositeImage?.isTransparent(maxAlpha: 0.02) == true
            if sckCompositeIsTransparent {
                compositeImage = nil
                if #available(macOS 15.0, *) {
                    if #unavailable(macOS 26.0) {
                        await MainActor.run {
                            visibleItemsRequireLegacyCapture = true
                        }
                    }
                }
            }
            if
                compositeImage == nil,
                ScreenCapture.claimLegacyCapture(
                    for: "item-cache-\(section.logString)"
                )
            {
                if #available(macOS 26.0, *) {
                    let serviceImages = await createImagesWithCaptureService(
                        windows: captureWindows,
                        expectedWindows: expectedCaptureWindows,
                        expectedScale: screen.backingScaleFactor,
                        option: option
                    )
                    guard !Task.isCancelled else {
                        return nil
                    }
                    if let serviceImages, !serviceImages.isEmpty {
                        return serviceImages
                    }
                } else {
                    compositeImage = ScreenCapture.captureWindows(
                        windowIDs,
                        option: option
                    )
                }
            }
        } else {
            guard !Task.isCancelled, ScreenCapture.claimLegacyCapture(
                for: "item-cache-\(section.logString)"
            ) else {
                return nil
            }
            compositeImage = ScreenCapture.captureWindows(
                windowIDs,
                option: option
            )
        }
        guard !Task.isCancelled else {
            return nil
        }
        let effectiveScale = compositeImage.map {
            frame.width > 0 ? CGFloat($0.width) / frame.width : 0
        } ?? 0

        if
            let compositeImage,
            effectiveScale.isFinite,
            effectiveScale >= 0.5,
            effectiveScale <= 4
        {
            for windowID in windowIDs {
                guard !Task.isCancelled else {
                    return nil
                }
                guard let itemFrame = itemFrames[windowID] else {
                    continue
                }

                let frame = CGRect(
                    x: (itemFrame.origin.x - frame.origin.x) * effectiveScale,
                    y: (itemFrame.origin.y - frame.origin.y) * effectiveScale,
                    width: itemFrame.width * effectiveScale,
                    height: itemFrame.height * effectiveScale
                )

                guard
                    let itemImage = compositeImage.cropping(to: frame),
                    let cachedImage = CachedImage(
                        cgImage: itemImage,
                        pixelScale: effectiveScale
                    )
                else {
                    continue
                }

                images[windowID] = cachedImage
            }
        } else {
            Logger.imageCache.warning("Composite image capture failed. Attempting to capture items individually.")

            for windowID in windowIDs {
                guard !Task.isCancelled else {
                    return nil
                }
                guard let itemFrame = itemFrames[windowID] else {
                    continue
                }

                let itemImage: CGImage?
                if section == .visible {
                    itemImage = await ScreenCapture.captureWindowOnScreen(
                        windowID,
                        option: option
                    )
                } else if #unavailable(macOS 26.0) {
                    itemImage = ScreenCapture.captureWindow(
                        windowID,
                        option: option
                    )
                } else {
                    itemImage = nil
                }
                guard !Task.isCancelled else {
                    return nil
                }
                guard let itemImage, itemFrame.width > 0 else {
                    continue
                }
                let itemScale = CGFloat(itemImage.width) / itemFrame.width
                let defaultItemThickness = NSStatusBar.system.thickness * itemScale
                let frame = CGRect(
                    x: 0,
                    y: ((itemFrame.height * itemScale) / 2) - (defaultItemThickness / 2),
                    width: itemFrame.width * itemScale,
                    height: defaultItemThickness
                )
                guard
                    let croppedImage = itemImage.cropping(to: frame),
                    let cachedImage = CachedImage(
                        cgImage: croppedImage,
                        pixelScale: itemScale
                    )
                else {
                    continue
                }

                images[windowID] = cachedImage
            }
        }

        return images
    }

    private func createImagesWithCaptureService(
        windows: [MenuBarCaptureService.Window],
        expectedWindows: [CGWindowID: MenuBarCaptureService.Window],
        expectedScale: CGFloat,
        option: CGWindowImageOption
    ) async -> [CGWindowID: CachedImage]? {
        let frames = await MenuBarCaptureServiceConnection.shared.capture(
            windows: windows,
            expectedScale: expectedScale,
            option: option
        )
        guard !Task.isCancelled else {
            return nil
        }
        let liveWindowsByID = Dictionary(
            WindowInfo.createWindows(from: frames.map(\.windowID)).map {
                ($0.windowID, $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var images = [CGWindowID: CachedImage]()
        for frame in frames {
            guard
                let expectedWindow = expectedWindows[frame.windowID],
                let liveWindow = liveWindowsByID[frame.windowID],
                expectedWindow.matches(
                    windowID: liveWindow.windowID,
                    ownerPID: liveWindow.ownerPID,
                    title: liveWindow.title,
                    layer: liveWindow.layer,
                    bounds: liveWindow.frame
                ),
                let image = MenuBarCaptureService.makeImage(from: frame),
                let cachedImage = CachedImage(
                    cgImage: image,
                    pixelScale: CGFloat(frame.pixelScale)
                )
            else {
                continue
            }
            images[frame.windowID] = cachedImage
        }
        return images
    }

    /// Updates the cache for the given sections, without checking whether caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        let generation = await MainActor.run {
            updateGeneration += 1
            return updateGeneration
        }
        guard let appState, !Task.isCancelled else {
            return
        }

        let currentItems = await appState.itemManager.itemCache.allItems
        let onScreenAnchor = currentItems.first(where: \.isOnScreen)
        let screen = onScreenAnchor.flatMap { item in
            NSScreen.screens.first {
                CGDisplayBounds($0.displayID).contains(
                    CGPoint(x: item.frame.midX, y: item.frame.midY)
                )
            }
        } ?? NSScreen.main
        guard let screen else {
            return
        }
        let validWindowIDs = Set(currentItems.map(\.windowID))
        var updatedImages = [CGWindowID: CachedImage]()

        for section in sections {
            guard !Task.isCancelled else {
                return
            }
            guard await !appState.itemManager.itemCache[section].isEmpty else {
                continue
            }
            guard let sectionImages = await createImages(
                for: section,
                screen: screen
            ) else {
                continue
            }
            guard !sectionImages.isEmpty else {
                Logger.imageCache.warning("Update image cache failed for \(section.logString)")
                continue
            }
            updatedImages.merge(sectionImages) { (_, new) in new }
        }

        guard !Task.isCancelled else {
            return
        }
        let committedImages = updatedImages
        let displayID = screen.displayID
        let menuBarHeight = screen.getMenuBarHeight()
        await MainActor.run {
            guard !Task.isCancelled, updateGeneration == generation else {
                return
            }
            self.images = self.images.filter { validWindowIDs.contains($0.key) }
            self.images.merge(committedImages) { (_, new) in new }
            self.screen = NSScreen.screens.first { $0.displayID == displayID }
            self.menuBarHeight = menuBarHeight
        }
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState, !sections.isEmpty else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isLayoutPanePresented = await isMenuBarLayoutPresented(in: appState)

        if !isIceBarPresented {
            guard isLayoutPanePresented else {
                logSkippingCache(reason: "neither Ice Bar nor menu bar layout is visible")
                return
            }
        }

        guard await !appState.itemManager.isMovingItem else {
            logSkippingCache(reason: "an item is currently being moved")
            return
        }

        guard await !appState.itemManager.itemHasRecentlyMoved else {
            logSkippingCache(reason: "an item was recently moved")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates dynamic item images while the Ice Bar is visible.
    private func updateCacheForTimer() async {
        guard let appState else {
            return
        }
        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        guard
            isIceBarPresented,
            let section = await appState.menuBarManager.iceBarPanel.currentSection
        else {
            return
        }
        await updateCache(sections: [section])
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isLayoutPanePresented = await isMenuBarLayoutPresented(in: appState)

        var sectionsNeedingDisplay = [MenuBarSection.Name]()
        if isLayoutPanePresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isIceBarPresented,
            let section = await appState.menuBarManager.iceBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }

    @MainActor
    private func isMenuBarLayoutPresented(in appState: AppState) -> Bool {
        guard appState.navigationState.settingsNavigationIdentifier == .menuBarLayout else {
            return false
        }
        return NSApp.windows.contains {
            $0.identifier?.rawValue == Constants.settingsWindowID && $0.isVisible
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let imageCache = Logger(category: "MenuBarItemImageCache")
}
