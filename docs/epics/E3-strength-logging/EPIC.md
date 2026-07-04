# E3 — Strength Logging UX 🟡

Scope: routine runner, fast set entry, setup notes in context, completion, and offline-first local persistence.

## Landed
- [x] Today screen starts a seeded routine from SwiftData.
- [x] Active workout logs working sets with weight/reps/RPE.
- [x] Completion persists the workout and recomputed volume.
- [x] Pending routine target sets prefill the runner and do not count as volume until completed.
- [x] Logged workout sets can be edited or deleted, with workout volume recomputed.
- [x] UI test covers start → log set → complete → setup note display.
- [x] UI test covers completed workout History list/detail.

## Remaining Acceptance
- [ ] Timed comparison shows median set logging is at least 25% faster than Hevy and ≤3 taps.
- [ ] All advanced set types are enterable.
- [ ] Unilateral entry never requires the user to double load manually.
- [ ] Airplane-mode behavior is explicitly tested.
