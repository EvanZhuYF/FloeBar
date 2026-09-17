//
//  ControlItemImageSet.swift
//  FloeBar
//

import Foundation

/// A named set of images that are used by control items.
///
/// An image set contains images for a control item in both the hidden and visible states.
struct ControlItemImageSet: Codable, Hashable, Identifiable {
    enum Name: String, Codable, Hashable {
        case arrow = "Arrow"
        case chevron = "Chevron"
        case door = "Door"
        case dot = "Dot"
        case ellipsis = "Ellipsis"
        case floe = "Floe"
        case iceCube = "Ice Cube"
        case sunglasses = "Sunglasses"
        case custom = "Custom"

        var localized: String {
            switch self {
            case .arrow: String(localized: "Arrow")
            case .chevron: String(localized: "Chevron")
            case .door: String(localized: "Door")
            case .dot: String(localized: "Dot")
            case .ellipsis: String(localized: "Ellipsis")
            case .floe: String(localized: "Floe")
            case .iceCube: String(localized: "Ice Cube")
            case .sunglasses: String(localized: "Sunglasses")
            case .custom: String(localized: "Custom")
            }
        }
    }

    let name: Name
    let hidden: ControlItemImage
    let visible: ControlItemImage

    var id: Int { hashValue }

    init(name: Name, hidden: ControlItemImage, visible: ControlItemImage) {
        self.name = name
        self.hidden = hidden
        self.visible = visible
    }

    init(name: Name, image: ControlItemImage) {
        self.init(name: name, hidden: image, visible: image)
    }
}

extension ControlItemImageSet {
    /// The FloeBar brand image set.
    private static let floeIcon = ControlItemImageSet(
        name: .floe,
        hidden: .builtin(.floeFill),
        visible: .builtin(.floeStroke)
    )

    /// The default image set for the FloeBar icon.
    static let defaultIceIcon = floeIcon

    /// The image sets that the user can choose to display in the Ice icon.
    static let userSelectableIceIcons = [
        floeIcon,
        ControlItemImageSet(
            name: .arrow,
            hidden: .symbol("arrowshape.left.fill"),
            visible: .symbol("arrowshape.right.fill")
        ),
        ControlItemImageSet(
            name: .chevron,
            hidden: .symbol("chevron.left"),
            visible: .symbol("chevron.right")
        ),
        ControlItemImageSet(
            name: .door,
            hidden: .symbol("door.left.hand.closed"),
            visible: .symbol("door.left.hand.open")
        ),
        ControlItemImageSet(
            name: .dot,
            hidden: .catalog("DotFill"),
            visible: .catalog("DotStroke")
        ),
        ControlItemImageSet(
            name: .ellipsis,
            hidden: .catalog("EllipsisFill"),
            visible: .catalog("EllipsisStroke")
        ),
        ControlItemImageSet(
            name: .iceCube,
            hidden: .catalog("IceCubeStroke"),
            visible: .catalog("IceCubeFill")
        ),
        ControlItemImageSet(
            name: .sunglasses,
            hidden: .symbol("sunglasses.fill"),
            visible: .symbol("sunglasses")
        ),
    ]
}
