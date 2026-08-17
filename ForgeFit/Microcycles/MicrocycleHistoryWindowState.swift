enum MicrocycleHistoryWindowState: Equatable {
    case inProgress(day: Int, total: Int)
    case finished
    case stopped(day: Int, total: Int)
}
