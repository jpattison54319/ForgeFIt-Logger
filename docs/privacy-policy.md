# ForgeFit Privacy Policy

_Last updated: August 11, 2026_

ForgeFit is built local-first: your training data belongs to you. If you are
signed into iCloud, ForgeFit automatically syncs your training plan through
your private CloudKit database and automatically backs up a sanitized copy of
your workout history to your iCloud Drive.

## What we collect

**We operate no servers and collect no personal information.** ForgeFit stores
your workouts, routines, exercise notes, and settings in a local database on
your iPhone. We run no analytics and have no backend. Nothing you log is sent
anywhere we can read it.

## iCloud sync & workout backup

If you are signed into iCloud, ForgeFit syncs your **training plan** —
routines, folders, each microcycle folder's default day target, your exercise
library, notes, saved interval and yoga presets, saved insight charts (their
definitions only — the numbers they show are recomputed on each device), and
coaching plans and preferences, progression suggestions, and your XP progress —
across your Apple devices using Apple's CloudKit. The records are stored under
your iCloud account in your private CloudKit database. ForgeFit's developer
operates no server and cannot read them.

Your **workout history** remains in a local database on each iPhone rather than
syncing as live CloudKit records. ForgeFit automatically creates a separate,
sanitized backup in Files → iCloud Drive → ForgeFit → Backups. Backup is on
automatically when iCloud Drive is available: ForgeFit queues a copy after
workout-history changes and performs a daily catch-up while you use the app.
It defers backup work while a live workout is open or the app is in the
background. ForgeFit keeps a latest and previous copy so an interrupted write
does not replace the only usable backup. Settings → iCloud Backup shows the
latest success or failure and lets you retry immediately.

The workout backup includes user-recorded training details such as workout
names and notes, exercises, sets, weights, reps, RPE, cardio and yoga details,
precise outdoor route coordinates, imports, microcycle windows, rest markers,
and selected app preferences such as display name, units, theme, quick actions,
and reminder choices. It excludes experiments and custom experiment entries,
workouts imported from Apple Health, HealthKit-filled distance, Health-derived
automatic interval detection, heart rate, calories or active energy, step
counts, sleep, readiness, body weight, daily check-ins, and other Apple Health
data. On another iPhone signed into the same iCloud account, you choose
Settings → Import workout history to restore a backup; ForgeFit then re-reads
available Health metrics from Apple Health on that device.

## Microcycle tracking

A leaf routine folder can be tracked as a repeating microcycle with a day
target. The folder's default day target is part of your synced training plan.
Active tracking runs, frozen window snapshots, Home and folder-header display
choices, and rest-day markers stay in the local training log; the sanitized
automatic workout backup includes them, and user-directed exports can include
them too.
Progress is derived from completed workouts linked to routines in that
microcycle. A rest-day marker adds calendar context but never completes a
routine. Workouts completed on Apple Watch can contribute after they reconcile
to that iPhone.

## Experiments

Experiments let you compare training, cardio, yoga, and available Apple Health
trends across a time period, alongside custom information you choose to record.
Experiment names, descriptions, schedules, custom trackers, and entries stay
only in the local database on the iPhone where you create them. They do not
sync through CloudKit or any automatic backup.
Workouts completed on Apple Watch can appear in an experiment after they
reconcile to that iPhone.

Experiment results describe differences and associations in your recorded
data. They do not establish that a supplement, routine, or other change caused
an outcome and are not medical advice. Deleting the app or replacing the
iPhone without making a separate user-directed export deletes the experiment
records.

## Apple Health

With your permission, ForgeFit reads health data from Apple Health to power
its features:

- **Workout metrics** (heart rate, active energy, distance, power) to
  auto-fill cardio sessions and show live stats during workouts.
- **Recovery data** (heart-rate variability, resting heart rate, sleep,
  respiratory rate, blood oxygen, VO₂max, heart-rate recovery, steps,
  exercise time, body weight) to compute your daily readiness score.

With your permission, ForgeFit also **writes** finished workouts back to Apple
Health.

Health data is processed entirely on your device. It is never transmitted to
us or any third party, is excluded from automatic iCloud sync and backup, and
is protected by iOS's Health data security. A user-directed data export can
include Health metrics stored with workouts or used in an experiment; you
choose that export's destination. When you restore a ForgeFit workout backup,
ForgeFit re-reads available Health metrics from Apple Health on that device.
You can revoke access at any time in the Health app under Sharing → Apps.

## Apple Watch

If you use the ForgeFit watch app, workout data syncs directly between your
watch and iPhone using Apple's encrypted device-to-device channel
(WatchConnectivity). It does not pass through any server.

## Bluetooth heart-rate monitors

If you pair a Bluetooth heart-rate monitor, its readings are used live during
your workout and stored with the session on your device, like any other
workout metric. The pairing is remembered only on that device.

## Earlier Community data

An earlier test build included an optional Community feature backed by Apple's
public CloudKit database. This version does not publish new Community data. If
you used that feature, Settings → Delete Community data permanently removes your
public profile and handle, shared workouts, follows, and likes.

## Data export

Settings → Export data creates JSON or CSV files of your workouts, routines,
microcycle tracking windows, and rest-day markers on demand, including the
health metrics ForgeFit has stored with workouts. An experiment's results
screen can separately export the observations used in that experiment,
including custom entries and available daily Health summaries. These exports
happen only when you request them. You choose the format and where the files
go — they are handed directly to you through the iOS share sheet and are never
transmitted to us or anyone else. Files shared outside ForgeFit are then
controlled by the destination you choose.

## Plan sharing

When you share a routine, microcycle, or mesocycle, ForgeFit creates a preview
image and a ForgeFit Plan file only after you choose Share. The plan file can
include routine and cycle names, routine notes, exercise definitions, ordering,
and planned targets so another ForgeFit user can save an independent copy. It
never includes your account identity, setup notes, workout history, cycle
progress, experiments, Apple Health data, readiness, or recovery information.
You choose the destination through the iOS share sheet; after sharing, the file
is controlled by that destination and its recipient.

## Data deletion

Deleting the app deletes all local ForgeFit data on that device, including
microcycle tracking runs, rest-day markers, experiments, and their custom
entries. Ending microcycle tracking does not delete workouts or rest-day
markers; deleting one experiment removes only that experiment and its entries.
Neither action deletes Apple Health data. Your training plan in iCloud can be
removed by deleting routines in the app (deletions sync) or via Settings →
Reset all app data. The workout backup is an ordinary pair of files you control:
delete it with Settings → iCloud Backup → Delete workout backup, in Files →
iCloud Drive → ForgeFit → Backups, or via Settings → Reset all app data. Reset
attempts to remove the backup and tells you if it could not. Because workout
backup is automatic, deleting only the backup does not turn backup off; a new
copy is created after future workout-history changes or a later daily catch-up.
Deleting the app from one device does not by itself delete the private CloudKit
plan or iCloud Drive backup. Any earlier public Community data must be removed
separately with Settings → Delete Community data. Workouts written to Apple
Health remain there under your control and can be deleted in the Health app.

## Changes

This privacy policy will be updated if any future version changes how data is
stored or synced. Any changes will be documented here first.

## Contact

Questions? Contact the developer through the app's App Store listing.
