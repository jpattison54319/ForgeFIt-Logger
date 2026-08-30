import ForgeData

/// Keeps an alternating cycle's library positions stable while presenting the
/// due routine in the owner's slot. Only the owner and due member trade places;
/// every other member remains in its stored slot.
@MainActor
enum AlternatingRoutineSlotResolver {
    static func presentedRoutine(
        for slot: RoutineModel,
        state: RoutineAlternationService.State?
    ) -> RoutineModel {
        guard let state else { return slot }
        guard state.due.id != state.owner.id else { return slot }
        if slot.id == state.owner.id { return state.due }
        if slot.id == state.due.id { return state.owner }
        return slot
    }
}
