# Earned Feature Discovery Catalog

ForgeFit suggests a feature only after durable user behavior makes its value
immediately relevant. Offers are not driven by launches, time installed, or
remote analytics. Only one offer may be visible at a time, and a permanent
dismissal is respected across sanitized backup and restore.

## Shipping

| Feature | Earned condition | Existing-use evidence | Surface |
| --- | --- | --- | --- |
| Microcycle tracking | Three ForgeFit-authored routine workouts from the same live leaf folder during the current day and prior eight calendar days, all completed after discovery enrollment | Any active, stopped, or historical tracking parent | Home |

## Candidate policies

These entries document the next conservative opportunities. They remain
disabled until their policy, presentation, and acceptance coverage ship.

| Feature | Candidate earned condition | Existing-use evidence | Candidate surface |
| --- | --- | --- | --- |
| Routine folders | Three live ungrouped routines and no live folder | Any live folder | Workout |
| Quick Start customization | The same unpinned routine completed three times within 14 days | Routine already present in Quick Start | Home Quick Start |
| Routine alternation | Four recent workouts form A-B-A-B within 21 days, both routines in the same leaf folder | Any alternation record containing either routine | Workout folder |
| Planned rest slots | Explicit rest logged in two recent tracked windows with no planned-rest slot | Any planned-rest snapshot | Microcycle detail |

## Policy requirements

- Existing durable models are the source of interaction evidence whenever
  possible; do not add a general analytics event log.
- Every policy returns a typed eligibility decision and concise “why now”
  presentation. Copy explains value or consequence, never interaction mechanics.
- Existing use suppresses its matching offer. Using a related affordance does
  not imply knowledge of a distinct feature; a folder does not itself suppress
  microcycle tracking discovery.
- Imported history and activity that predates enrollment do not earn offers.
- Policies must evaluate outside SwiftUI render paths from bounded or memoized
  snapshots, deduplicate logical CloudKit rows, and remain deterministic when
  several targets qualify.
