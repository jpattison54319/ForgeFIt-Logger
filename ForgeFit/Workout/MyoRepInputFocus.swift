enum MyoRepInputFocus: Hashable {
    case activeWeight
    case activeActivation(side: Int)
    case activeMini(side: Int)
    case editorWeight
    case editorActivation(side: Int)
    case miniEditor(side: Int, index: Int)
}
