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
        /// A filled floating ice floe.
        case floeFill
        /// An outlined floating ice floe.
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

        /// A namespace for floating ice floe images.
        enum Floe {
            /// Creates a floating ice floe with the given fill style.
            private static func floe(filled: Bool) -> NSImage {
                let image = NSImage(size: CGSize(width: 22, height: 18), flipped: false) { _ in
                    let body = NSBezierPath()
                    body.move(to: CGPoint(x: 1.5, y: 9))
                    body.line(to: CGPoint(x: 5.5, y: 13))
                    body.line(to: CGPoint(x: 12.5, y: 14.5))
                    body.line(to: CGPoint(x: 20.5, y: 10))
                    body.line(to: CGPoint(x: 17.5, y: 7))
                    body.line(to: CGPoint(x: 13.5, y: 6.5))
                    body.line(to: CGPoint(x: 10.5, y: 4))
                    body.line(to: CGPoint(x: 7.5, y: 6.5))
                    body.line(to: CGPoint(x: 3.5, y: 7))
                    body.close()
                    body.lineWidth = 1.45
                    body.lineCapStyle = .round
                    body.lineJoinStyle = .round

                    NSColor.black.set()
                    if filled {
                        body.fill()
                    } else {
                        body.stroke()
                    }

                    let wave = NSBezierPath()
                    wave.move(to: CGPoint(x: 2.5, y: 1.5))
                    wave.curve(
                        to: CGPoint(x: 10.8, y: 1.5),
                        controlPoint1: CGPoint(x: 5, y: 3.7),
                        controlPoint2: CGPoint(x: 8.3, y: -0.7)
                    )
                    wave.curve(
                        to: CGPoint(x: 19.5, y: 1.5),
                        controlPoint1: CGPoint(x: 13.5, y: 3.7),
                        controlPoint2: CGPoint(x: 17, y: -0.7)
                    )
                    wave.lineWidth = 1.45
                    wave.lineCapStyle = .round
                    wave.stroke()
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A filled floating ice floe.
            static let fill = floe(filled: true)

            /// An outlined floating ice floe.
            static let stroke = floe(filled: false)
        }
    }
}
