import ForgeData

/// Keeps an alternating pair's library positions stable while presenting the
/// due routine in the owner's slot and the other routine in the partner's slot.
@MainActor
enum AlternatingRoutineSlotResolver {
    static func presentedRoutine(
        for slot: RoutineModel,
        state: RoutineAlternationService.State?
    ) -> RoutineModel {
        guard let state else { return slot }
        if slot.id == state.owner.id { return state.due }
        if slot.id == state.partner.id { return state.other }
        return slot
    }
}
