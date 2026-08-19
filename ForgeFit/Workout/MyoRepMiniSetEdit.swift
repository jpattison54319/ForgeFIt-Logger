struct MyoRepMiniSetEdit: Identifiable, Equatable {
    let side: Int
    let index: Int
    let reps: Int

    var id: String { "\(side)-\(index)" }
}
