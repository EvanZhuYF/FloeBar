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
        /// A filled Antarctica silhouette.
        case floeFill
        /// An outlined Antarctica silhouette.
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

        /// A namespace for Antarctica silhouette images.
        enum Floe {
            /// Creates a simplified Antarctica silhouette with the given fill style.
            private static func antarctica(filled: Bool) -> NSImage {
                let image = NSImage(size: CGSize(width: 22, height: 18), flipped: false) { _ in
                    let continent = NSBezierPath()
                    continent.move(to: CGPoint(x: 0.8, y: 14.2))
                    continent.line(to: CGPoint(x: 1.5, y: 12.7))
                    continent.line(to: CGPoint(x: 3.2, y: 11.1))
                    continent.line(to: CGPoint(x: 4.8, y: 11.4))
                    continent.line(to: CGPoint(x: 6.2, y: 12.8))
                    continent.curve(
                        to: CGPoint(x: 8.2, y: 15.5),
                        controlPoint1: CGPoint(x: 6.8, y: 14.2),
                        controlPoint2: CGPoint(x: 7.2, y: 15.2)
                    )
                    continent.curve(
                        to: CGPoint(x: 12.2, y: 16.5),
                        controlPoint1: CGPoint(x: 9.2, y: 16.4),
                        controlPoint2: CGPoint(x: 11, y: 16.8)
                    )
                    continent.curve(
                        to: CGPoint(x: 16.2, y: 15),
                        controlPoint1: CGPoint(x: 13.6, y: 16.2),
                        controlPoint2: CGPoint(x: 15.2, y: 15.8)
                    )
                    continent.line(to: CGPoint(x: 18.5, y: 13))
                    continent.curve(
                        to: CGPoint(x: 20.3, y: 9.7),
                        controlPoint1: CGPoint(x: 19.6, y: 12),
                        controlPoint2: CGPoint(x: 20.5, y: 10.7)
                    )
                    continent.line(to: CGPoint(x: 19, y: 7.2))
                    continent.line(to: CGPoint(x: 17.4, y: 5))
                    continent.line(to: CGPoint(x: 15.2, y: 3.8))
                    continent.line(to: CGPoint(x: 13.2, y: 1.5))
                    continent.line(to: CGPoint(x: 11.8, y: 2.3))
                    continent.line(to: CGPoint(x: 11.1, y: 4.3))
                    continent.line(to: CGPoint(x: 9.2, y: 3.8))
                    continent.line(to: CGPoint(x: 6.8, y: 4.5))
                    continent.line(to: CGPoint(x: 4.8, y: 6.5))
                    continent.line(to: CGPoint(x: 4.4, y: 8.5))
                    continent.line(to: CGPoint(x: 3.4, y: 9.8))
                    continent.line(to: CGPoint(x: 2.2, y: 10.3))
                    continent.line(to: CGPoint(x: 1.3, y: 11.7))
                    continent.close()
                    continent.lineWidth = 1.25
                    continent.lineCapStyle = .round
                    continent.lineJoinStyle = .round

                    NSColor.black.set()
                    if filled {
                        continent.fill()
                    } else {
                        continent.stroke()
                    }
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A filled Antarctica silhouette.
            static let fill = antarctica(filled: true)

            /// An outlined Antarctica silhouette.
            static let stroke = antarctica(filled: false)
        }
    }
}
