//
//  ControlItemImage.swift
//  FloeBar
//

import Cocoa

/// A Codable image for a control item.
enum ControlItemImage: Codable, Hashable {
    /// An image created from drawing code built into the app.
    case builtin(_ name: ImageBuiltinName)
    /// A system symbol image.
    case symbol(_ name: String)
    /// An image in an asset catalog.
    case catalog(_ name: String)
    /// An image stored as data.
    case data(_ data: Data)

    /// A Cocoa representation of this image.
    @MainActor
    func nsImage(for appState: AppState) -> NSImage? {
        switch self {
        case .builtin(let name):
            return switch name {
            case .chevronLarge: StaticBuiltins.Chevron.large
            case .chevronSmall: StaticBuiltins.Chevron.small
            case .floeFill: StaticBuiltins.Floe.fill
            case .floeStroke: StaticBuiltins.Floe.stroke
            }
        case .symbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        case .catalog(let name):
            guard let originalImage = NSImage(named: name) else {
                return nil
            }
            let originalWidth = originalImage.size.width
            let originalHeight = originalImage.size.height
            let ratio = max(originalWidth / 25, originalHeight / 17)
            let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
            return originalImage.resized(to: newSize)
        case .data(let data):
            let image = NSImage(data: data)
            let generalSettingsManager = appState.settingsManager.generalSettingsManager
            image?.isTemplate = generalSettingsManager.customIceIconIsTemplate
            return image
        }
    }
}

extension ControlItemImage {
    /// A name for an image that is created from drawing code in the app.
    enum ImageBuiltinName: Codable, Hashable {
        /// A large chevron.
        case chevronLarge
        /// A small chevron.
        case chevronSmall
        /// A filled FloeBar brand mark.
        case floeFill
        /// An outlined FloeBar brand mark.
        case floeStroke
    }
}

extension ControlItemImage {
    /// A namespace for static builtin images.
    ///
    /// - Note: We use the static properties `large` and `small` to avoid repeatedly
    ///   executing code every time ``nsImage(for:)`` is called.
    private enum StaticBuiltins {
        /// A namespace for static builtin chevron images.
        enum Chevron {
            /// Creates a chevron image with the given size and line width.
            private static func chevron(size: CGSize, lineWidth: CGFloat) -> NSImage {
                let image = NSImage(size: size, flipped: false) { bounds in
                    let insetBounds = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.maxY))
                    path.line(to: CGPoint(x: (insetBounds.minX + insetBounds.midX) / 2, y: insetBounds.midY))
                    path.line(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.minY))
                    path.lineWidth = lineWidth
                    path.lineCapStyle = .butt
                    NSColor.black.setStroke()
                    path.stroke()
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A large chevron.
            static let large = chevron(size: CGSize(width: 12, height: 12), lineWidth: 2)

            /// A small chevron.
            static let small = chevron(size: CGSize(width: 9, height: 9), lineWidth: 2)
        }

        /// A namespace for FloeBar brand mark images.
        enum Floe {
            /// Creates the App Icon's core symbol without its blue background.
            private static func brandMark(filled: Bool) -> NSImage {
                let image = NSImage(size: CGSize(width: 22, height: 18), flipped: false) { _ in
                    let capsule = NSBezierPath(
                        roundedRect: CGRect(x: 1, y: 8.5, width: 20, height: 7.5),
                        xRadius: 3.75,
                        yRadius: 3.75
                    )
                    let leadingDot = NSBezierPath(
                        ovalIn: CGRect(x: 13, y: 11, width: 2.4, height: 2.4)
                    )
                    let trailingDot = NSBezierPath(
                        ovalIn: CGRect(x: 16.5, y: 11, width: 2.4, height: 2.4)
                    )
                    let lowerBar = NSBezierPath(
                        roundedRect: CGRect(x: 1.5, y: 2, width: 8.5, height: 4),
                        xRadius: 2,
                        yRadius: 2
                    )

                    if filled {
                        capsule.append(leadingDot)
                        capsule.append(trailingDot)
                        capsule.windingRule = .evenOdd
                        NSColor.black.setFill()
                        capsule.fill()
                    } else {
                        capsule.lineWidth = 1.4
                        NSColor.black.setStroke()
                        capsule.stroke()

                        NSColor.black.setFill()
                        leadingDot.fill()
                        trailingDot.fill()
                    }

                    NSColor.black.withAlphaComponent(0.55).setFill()
                    lowerBar.fill()
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A filled FloeBar brand mark.
            static let fill = brandMark(filled: true)

            /// An outlined FloeBar brand mark.
            static let stroke = brandMark(filled: false)
        }
    }
}
