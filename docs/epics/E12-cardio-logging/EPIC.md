# E12 — Cardio Modality Logging 🟡

Scope: modality-specific cardio logging for iPhone and Watch, including correct metrics, HealthKit workout configuration, and HR-zone capture.

## Landed
- [x] Global exercise seed includes run, ride, and row modalities.
- [x] Today screen offers quick run/ride/row starts.
- [x] Local cardio workouts save structured duration, distance, energy, HR, cadence/stroke, power, and effort fields.
- [x] Cardio exercises seed/update as cardio with cardiovascular muscles and modality-specific metric labels.
- [x] Cardio routine entries use target duration and create linked `CardioSessionModel` rows, not strength sets.
- [x] Cardio logging screens do not expose strength set types such as myo-reps/drop sets.
- [x] UI test covers quick row start → structured save → recent summary.

## Remaining Acceptance
- [ ] Each modality records its correct structured metric set.
- [ ] HealthKit writes use the correct `HKWorkoutConfiguration`.
- [ ] Completed cardio writes non-zero energy.
- [ ] HR zones are captured and summarized.
