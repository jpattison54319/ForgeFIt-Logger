/// Rendering strategies for `GlassDivisionMenu`.
enum GlassDivisionRenderingMode {
    /// The original native cell-division morph used by controls contained
    /// within a card or other stable compositing surface.
    case nativeCellDivision

    /// The deterministic relay backed by ordinary material. Retained as the
    /// quick-action menu's immediate fallback if native compositing regresses.
    case stableMaterialRelay

    /// The deterministic relay with persistent, identity-stable Liquid Glass
    /// surfaces. Intended for root-level controls that cross other surfaces.
    case persistentLiquidGlassRelay
}
