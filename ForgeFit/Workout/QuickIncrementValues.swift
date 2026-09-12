import SwiftUI

/// Observe only this field's three scalar preferences. No decoding, model
/// access, or persistence runs while the fan tracks the user's finger.
struct QuickIncrementValues: DynamicProperty {
    @AppStorage private var first: Double
    @AppStorage private var second: Double
    @AppStorage private var third: Double
    private let kind: QuickIncrementKind

    init(kind: QuickIncrementKind) {
        self.kind = kind
        _first = AppStorage(wrappedValue: kind.defaults[0], kind.key(0))
        _second = AppStorage(wrappedValue: kind.defaults[1], kind.key(1))
        _third = AppStorage(wrappedValue: kind.defaults[2], kind.key(2))
    }

    var options: [QuickIncrementController.Option] {
        let values = [first, second, third]
        return QuickIncrementController.options(increments: kind.isValid(values) ? values : kind.defaults)
    }
}
