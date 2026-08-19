import Foundation
import ForgeData

struct MyoRepSetPresentation: Identifiable {
    enum Mode: String {
        case active
        case editing
    }

    let set: SetModel
    let mode: Mode

    var id: String { "\(set.id.uuidString)-\(mode.rawValue)" }
}
