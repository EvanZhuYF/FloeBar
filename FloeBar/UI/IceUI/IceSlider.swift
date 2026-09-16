//
//  IceSlider.swift
//  FloeBar
//

import CompactSlider
import SwiftUI

struct IceSlider<Value: BinaryFloatingPoint, ValueLabel: View, ValueLabelSelectability: TextSelectability>: View {
    private let value: Binding<Value>
    private let bounds: ClosedRange<Value>
    private let step: Value
    private let valueLabel: ValueLabel
    private let valueLabelSelectability: ValueLabelSelectability
    private let onEditingChanged: (Bool) -> Void
    @State private var sliderState = CompactSliderState.zero

    init(
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0,
        valueLabelSelectability: ValueLabelSelectability = .disabled,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder valueLabel: () -> ValueLabel
    ) {
        self.value = value
        self.bounds = bounds
        self.step = step
        self.valueLabel = valueLabel()
        self.valueLabelSelectability = valueLabelSelectability
        self.onEditingChanged = onEditingChanged
    }

    init(
        _ valueLabelKey: LocalizedStringKey,
        valueLabelSelectability: ValueLabelSelectability = .disabled,
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) where ValueLabel == Text {
        self.init(
            value: value,
            in: bounds,
            step: step,
            valueLabelSelectability: valueLabelSelectability,
            onEditingChanged: onEditingChanged
        ) {
            Text(valueLabelKey)
        }
    }

    var body: some View {
        CompactSlider(
            value: value,
            in: bounds,
            step: step,
            handleVisibility: .hovering(width: 1),
            state: $sliderState
        ) {
            valueLabel
                .textSelection(valueLabelSelectability)
        }
        .compactSliderDisabledHapticFeedback(true)
        .onChange(of: sliderState.isDragging) { _, isDragging in
            onEditingChanged(isDragging)
        }
    }
}
