import SwiftUI

enum ResistanceBandHue: String, Codable, CaseIterable, Identifiable {
    case yellow, red, black, purple, green, blue, orange, gray, pink, teal

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .yellow: Color(hex: 0xEAB308)
        case .red: Color(hex: 0xDC2626)
        case .black: Color(hex: 0x171717)
        case .purple: Color(hex: 0x7C3AED)
        case .green: Color(hex: 0x16A34A)
        case .blue: Color(hex: 0x2563EB)
        case .orange: Color(hex: 0xEA580C)
        case .gray: Color(hex: 0x737373)
        case .pink: Color(hex: 0xDB2777)
        case .teal: Color(hex: 0x0F766E)
        }
    }
}

struct ResistanceBandPreset: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var hueRaw: String
    /// Equivalent resistance stored in the app's canonical kilogram unit.
    var weightKilograms: Double

    init(
        id: UUID = UUID(),
        name: String,
        hue: ResistanceBandHue,
        weightKilograms: Double
    ) {
        self.id = id
        self.name = name
        hueRaw = hue.rawValue
        self.weightKilograms = max(0, weightKilograms)
    }

    var hue: ResistanceBandHue {
        get { ResistanceBandHue(rawValue: hueRaw) ?? .gray }
        set { hueRaw = newValue.rawValue }
    }
}

struct ResistanceBandProfile: Codable, Equatable {
    var presets: [ResistanceBandPreset]

    static let standard = ResistanceBandProfile(presets: [
        preset("Yellow", .yellow, pounds: 5),
        preset("Red", .red, pounds: 15),
        preset("Black", .black, pounds: 30),
        preset("Purple", .purple, pounds: 50),
        preset("Green", .green, pounds: 65),
        preset("Blue", .blue, pounds: 100),
    ])

    func matching(weightKilograms: Double?) -> ResistanceBandPreset? {
        guard let weightKilograms else { return nil }
        return presets.first { abs($0.weightKilograms - weightKilograms) < 0.01 }
    }

    mutating func addPreset() {
        let used = Set(presets.map(\.hue))
        let hue = ResistanceBandHue.allCases.first { !used.contains($0) } ?? .gray
        presets.append(ResistanceBandPreset(
            name: hue.title,
            hue: hue,
            weightKilograms: Fmt.unit.kilograms(fromDisplayValue: 10)
        ))
    }

    private static func preset(
        _ name: String,
        _ hue: ResistanceBandHue,
        pounds: Double
    ) -> ResistanceBandPreset {
        ResistanceBandPreset(
            name: name,
            hue: hue,
            weightKilograms: WeightUnit.lb.kilograms(fromDisplayValue: pounds)
        )
    }
}

enum ResistanceBandProfileStore {
    static let key = "resistanceBandProfile.v1"

    static func load() -> ResistanceBandProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(ResistanceBandProfile.self, from: data),
              !profile.presets.isEmpty else {
            return .standard
        }
        return profile
    }

    static func save(_ profile: ResistanceBandProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum ResistanceBandSupport {
    static func isBandExercise(name: String?, equipment: String?) -> Bool {
        let normalizedEquipment = equipment?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedName = name?.lowercased() ?? ""
        return normalizedEquipment == "bands"
            || normalizedEquipment.contains("resistance band")
            || normalizedName.contains("band")
    }
}

struct ResistanceBandSwatch: View {
    let hue: ResistanceBandHue

    var body: some View {
        Circle()
            .fill(hue.color)
            .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct ResistanceBandLoadMenu: View {
    @AppStorage(ResistanceBandProfileStore.key) private var storedProfile = Data()

    let selectedWeightKilograms: Double?
    let unit: WeightUnit
    let onSelect: (Double) -> Void

    private var profile: ResistanceBandProfile {
        (try? JSONDecoder().decode(ResistanceBandProfile.self, from: storedProfile))
            ?? ResistanceBandProfileStore.load()
    }

    private var selected: ResistanceBandPreset? {
        profile.matching(weightKilograms: selectedWeightKilograms)
    }

    var body: some View {
        Menu {
            ForEach(profile.presets) { preset in
                Button {
                    onSelect(preset.weightKilograms)
                } label: {
                    Label {
                        Text("\(preset.name) · \(Fmt.loadUnit(preset.weightKilograms, unit: unit))")
                    } icon: {
                        Image(systemName: selected?.id == preset.id ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(preset.hue.color)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                ResistanceBandSwatch(hue: selected?.hue ?? .gray)
                    .frame(width: 14, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .frame(width: 24, height: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel("Resistance band color")
        .accessibilityValue(selected.map { "\($0.name), \(Fmt.loadUnit($0.weightKilograms, unit: unit))" } ?? "Custom weight")
    }
}
