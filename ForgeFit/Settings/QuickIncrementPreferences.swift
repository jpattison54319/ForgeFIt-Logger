import Foundation

enum QuickIncrementPreferences {
    static let keys = QuickIncrementKind.allCases.flatMap { kind in (0..<3).map(kind.key) }

    static func load(_ kind: QuickIncrementKind, from defaults: UserDefaults = .standard) -> [Double] {
        let values = (0..<3).map { index in
            (defaults.object(forKey: kind.key(index)) as? NSNumber)?.doubleValue ?? kind.defaults[index]
        }
        return kind.isValid(values) ? values : kind.defaults
    }

    @discardableResult
    static func save(_ values: [Double], for kind: QuickIncrementKind, to defaults: UserDefaults = .standard) -> Bool {
        guard kind.isValid(values) else { return false }
        for index in 0..<3 {
            defaults.set(values[index], forKey: kind.key(index))
        }
        return true
    }
}
