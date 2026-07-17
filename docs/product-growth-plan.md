# ForgeFit Product Growth Plan

Evidence collected in July 2026 from the current repo, local tests, App Store listings, competitor sites, and behavior-change research.

## Executive Thesis

ForgeFit should not try to become four separate apps glued together. The winning product is:

> The Apple Watch training co-pilot for hybrid athletes: one daily training decision, one fast log, one trusted recovery loop, and one useful story after every workout.

Users will not switch from Hevy, Strava, Down Dog, Athlytic, or Bevel because ForgeFit has a longer feature checklist. They will switch if ForgeFit makes the daily question easier than any single-purpose app:

> "What should I do today, exactly how hard should I go, and did it move me forward?"

That is the core product loop to protect:

1. Morning: ForgeFit turns sleep, HRV/RHR, training load, muscle freshness, goals, and available time into one plain recommendation.
2. Training: the user starts the right session in one tap and logs with less friction than Hevy.
3. Finish: ForgeFit explains what improved, what it cost, and what to do next.
4. Return: reminders, widgets, streak protection, monthly Wrapped, and re-entry flows pull the user back without guilt.

## Evidence Summary

### Competitor Reality

Hevy is the strength benchmark. The US App Store lists Hevy at 4.9 stars with 79K ratings, says it has 10M+ users, and highlights routines, exercise videos, warmup/drop/failure/superset set types, automatic rest timers, muscle graphs, one-rep max graphs, social following, workout copying, Apple Watch live sync, complications, Live Activities, widgets, and iPad support. Hevy is also actively moving into guided programs and "hybrid trainings", so ForgeFit cannot win by assuming Hevy is static.

Strava is the cardio and social graph benchmark. The US App Store lists Strava at 4.8 stars with 363K ratings. Strava's site positions it as community-powered motivation with tracking, analysis, routes, clubs, challenges, and segments. In June 2026 Strava said it had over 195M users and launched more hiking route, navigation, offline route, 3D map, replay, and club features. Its 2025 Apple Watch update added Live Segments and "stats at a glance" because Apple Watch usage is strategically important.

Down Dog is the yoga personalization benchmark. The US App Store lists Down Dog at 4.9 stars with 326K ratings. Its core promise is "a new workout every time", tailored by level, focus, pace, and time, with over one million possible configurations. It has 10+ yoga styles, 19 focus boosts, pose like/dislike controls, selectable voices, goals, streaks, Apple Health sync, and a broader wellness subscription across yoga, meditation, Pilates, and HIIT.

Athlytic and Bevel are the recovery/readiness benchmarks. Athlytic is 4.8 stars with 11K ratings and centers on recovery, exertion, target exertion, sleep, 24/7 health monitoring, journal tags, workout HR-zone analysis, trends, complications, and widgets. Bevel is 4.8 stars with 12K US ratings; its site claims 4.8 / 28.6K global ratings. Bevel has expanded into recovery, sleep, strain, stress, nutrition, strength builder, energy bank, biological age, health records, journal, and AI recommendations.

### Behavior-Change Evidence

Fitness technology works best when it gives personalized feedback and timely action, not just dashboards. A University of Sydney summary of a British Journal of Sports Medicine review reports that app/tracker interventions increased activity by about 2000 steps per day, and noted personalization and messaging as especially effective ingredients. A JMIR meta-analysis found app-only effects were modest and strongest in the short term, which means ForgeFit should design for the first 7 days and then convert early motivation into a habit loop.

Large activity-tracking studies point to two important product rules:

1. Early behavior matters. A MyFitnessPal goal-setting study of 1.4M users found first-week behavior predicted eventual goal achievement.
2. Users have "multiple lives." A study of over 1M users and 115M logged activities found that more than 75% of users returned after inactivity, and re-entry often resembled a fresh start rather than a continuation.

Implication: ForgeFit needs a strong first-week activation path and a deliberate "welcome back, restart cleanly" path.

### ForgeFit Current Strengths

ForgeFit already has the right strategic ingredients:

- First launch can connect Apple Health, import recent Health data, pick units, choose starter programs, and import Hevy/common CSV history in `OnboardingView`.
- Home already leads with readiness when data exists, has a readiness empty state, a next-routine suggestion, coach-adjusted starts, quick starts, recent workouts, coach chat, and Wrapped report cards.
- Strength logging already supports previous-set suggestions, placeholder materialization, rest timers, drop sets, plate calculator entry points, exercise notes, PR award cache, and focus advancement.
- Cardio already has HR zones, zone locks, interval plans, live distance from Watch/GPS, manual fallback, and modality-aware copy.
- Yoga already has guided class flows, a flow builder, spoken cue path, contraindication notes, manual logging, HR zone display, and pose splits.
- Retention pieces already exist: reminders, streak protection, monthly/yearly Wrapped, share cards, history import, import exercise matching, AICoach, widgets, and Watch state publishing.
- `make test` passed locally with 145 core/data tests plus stub package builds, covering set math, advanced/unilateral volume, exercise search/classification, HR/zone parsing, intervals, yoga structures, Watch sync payloads, CloudKit-safe models, and routine-to-workout persistence.

### ForgeFit Current Gaps

The live epic tracker shows the biggest trust and retention risks:

- Hevy-speed proof is not complete: no documented timed benchmark, no verified <=3 taps / <=2.5s median set logging.
- Watch companion and mirroring reliability are not complete: E7 and E8 are still not started in the tracker.
- Progression engine v1 is not complete: no explained weight-increase suggestion, no accept/reject tracking, no e1RM trend chart completion.
- HealthKit biometric ingestion and readiness are marked not started in the epic tracker, even though recovery code exists. That means the product claim is ahead of the verified data pipeline.
- Cardio logging exists locally, but correct modality metrics and valid non-zero HealthKit workout writes still need proof.
- Cardio analytics, high-res telemetry, Strava/FIT/TCX export, full export/delete, launch polish, and accessibility audits remain open.
- There is no explicit product analytics layer to measure activation, feature adoption, set-logging speed, D7 retention predictors, or D30 retention.
- Onboarding offers useful choices, but it does not yet force the first value moment: "your first plan is ready" or "your imported history changed today's recommendation."

## Product Strategy

### 1. Own "Today Plan" As The Home Screen

Current Home has pieces of this: readiness, this week, next routine, quick starts, and coach version. Make it a single decision engine:

**Today Plan card**

- Primary recommendation: "Train as planned", "Push", "Reduce volume", "Zone 2", "Mobility", or "Rest".
- Concrete session: routine, cardio modality, or yoga flow.
- User constraints: time available, equipment, soreness/injury notes, training goal.
- Explain why in one line: "Readiness 63, hamstrings still recovering, sleep short, push muscles fresh."
- One-tap starts:
  - Start plan
  - Start coach version
  - Swap to cardio
  - Swap to recovery yoga
- Confidence state: "High confidence from 22 nights of Watch data" or "Building baseline: 5 more nights needed."

Why this wins:

- Beats Hevy because Hevy logs well but does not own the whole training decision.
- Beats Athlytic/Bevel because the recommendation starts the actual workout, not just another dashboard.
- Beats Down Dog for hybrid athletes because yoga is prescribed as recovery, not isolated content.
- Reduces cognitive load, which is the daily pain of the target user.

### 2. Beat Hevy Where Hevy Is Strongest

ForgeFit must be credibly faster and more trustworthy in the gym. This is non-negotiable because lifters will forgive fewer features before they forgive slow logging.

Build and publish an internal benchmark:

- Standard workout: 5 exercises, 3 working sets each, mixed barbell/dumbbell/machine.
- Measure median set entry time, tap count, edit correction rate, and time to replace an unavailable exercise.
- Compare ForgeFit vs Hevy on iPhone and Watch.
- Target: <=2.5s median set entry, <=3 taps, at least 25% faster than Hevy for repeat/prefilled sets.

Product work:

- Keep the current suggestion-backed set rows.
- Add a visible "repeat previous and advance" affordance for each set and a full-row swipe/keyboard shortcut path.
- Finish all advanced set types and unilateral cases.
- Add "gym fallback" flows: replace exercise, substitute same muscle/equipment, keep targets.
- Add post-set micro-feedback: PR, volume, e1RM, next target, but keep it quiet enough not to slow logging.

### 3. Make Recovery Actionable, Honest, And Useful Before It Is Perfect

Recovery apps win because they become a morning habit. ForgeFit should match the morning habit but beat them on actionability.

Ship readiness in layers:

- Layer 1: "Training readiness" from logged workouts and user check-in, available on day 0.
- Layer 2: Apple Health sleep/RHR/HRV once connected, with confidence.
- Layer 3: nocturnal HRV/sleeping HR enrichment and longer rolling baselines.
- Layer 4: per-muscle and cardio freshness tied directly to today's workout.

Required UI rules:

- Never fake a score. Show "building" states and what is missing.
- Always translate the score into a training action.
- Always explain the top 2-3 drivers.
- Always provide a safe alternative: "Do this instead."

### 4. Treat Cardio As Training, Not A Note

Do not try to defeat Strava's social graph or route discovery early. Instead:

- Record or import cardio reliably.
- Show zones, pace/split, route, and training load.
- Explain what the session improved: base, threshold, VO2max, recovery, or mixed.
- Export to Strava so users keep their social identity.
- Use cardio load in Today Plan so strength and endurance stop fighting each other.

Minimum "stop opening another cardio app while training" bar:

- One-tap run/ride/row/walk starts.
- Watch-first display with pace/distance/time/HR/zone.
- Reliable HealthKit save with non-zero energy.
- Post-workout map, zones, splits, and load.
- Strava export with user-controlled fields.

### 5. Make Yoga A Recovery And Mobility Prescription

ForgeFit does not need to clone Down Dog's entire content machine. It needs to make yoga immediately relevant to the hybrid athlete.

Priority yoga value:

- "10 min hips after run"
- "12 min shoulders after upper day"
- "20 min low-readiness recovery flow"
- "5 min cooldown after lifting"
- "Evening downshift after hard day"

Controls to add:

- Duration: 5, 10, 15, 20, 30, 45 minutes.
- Focus: hips, hamstrings, calves, low back, thoracic, shoulders, wrists, full body.
- Intensity: restorative, gentle, active, power.
- Avoid: wrists, knees, low back, inversions.
- Guidance: voice cues on/off, pose preview, simpler alternatives.

This borrows Down Dog's customization lesson while keeping ForgeFit's strategic lane: recovery-aware training.

### 6. Build Retention Around The Loop After Every Workout

Every completed session should create tomorrow's reason to return.

Post-workout summary should always answer:

1. What did I do?
2. What improved?
3. What did it cost?
4. What should I do next?

Add:

- "Next time" target per exercise.
- Readiness/load impact.
- Muscle freshness forecast.
- One shareable card.
- One optional note: "how did this feel?"
- One next-session reminder suggestion.

### 7. Win Trust With Migration And Ownership

Migration is a feature, not a settings utility. It is how ForgeFit steals power users.

Make "Bring your data" a first-class path:

- Hevy CSV import.
- Strong/Fitbod/HeavySet/common CSV import.
- Apple Health history import.
- Exercise matching review.
- Immediate "your history is now useful" payoff: records, volume trends, next routine suggestions, readiness/load context.

Ownership commitments:

- Local-first logging.
- iCloud private database sync.
- Full export.
- Full delete.
- Strava export only with explicit user action.
- No raw health values in product analytics.

## Roadmap

### Phase 0: Measurement And Trust Gate (1-2 weeks)

Goal: know if users get value and prove logging reliability.

Tickets:

- Add a privacy-preserving local event model for activation and product health. Start local-only; export aggregate test builds manually if needed.
- Track: onboarding started/completed, Health connected, history import opened/previewed/committed, starter program selected, first workout started/completed, set completed, workout duration, readiness viewed, coach version started, cardio/yoga started, share card opened, reminder enabled.
- Add a set-logging benchmark harness and UI test path.
- Run the Hevy comparison and record baseline video/timing.
- Add QA scripts for airplane-mode session completion, app kill mid-session, and HealthKit write verification.
- Add a beta "trust dashboard" with crash-free, failed save count, Health write success, duplicate workout count, and sync status.

Success metrics:

- Instrumentation covers all core funnel steps.
- Benchmark has a repeatable script.
- No known data-loss path in local workouts.
- HealthKit write test proves non-zero energy for supported workouts.

### Phase 1: First Value Path (2-3 weeks)

Goal: get a new user to a meaningful first training decision in one session.

Product changes:

- Replace linear onboarding with three starting paths:
  - "I already track workouts" -> import Hevy/CSV/Health.
  - "Give me a program" -> choose starter program.
  - "I just want to train today" -> choose time/equipment/goal and start.
- End onboarding on "Your first plan is ready" with one primary action.
- After import, show instant value: records found, common muscles, recent volume, suggested next session.
- If Health is skipped, ask for a 5-second check-in so Today Plan still works.
- Move notification setup after the user completes or schedules their first session, not before value.

Success metrics:

- 70%+ onboarding completion.
- 55%+ choose import, starter program, or train-today path.
- 45%+ start first workout within first session.
- 35%+ complete first workout within 24 hours.

### Phase 2: Today Plan MVP (2-4 weeks)

Goal: make Home the daily decision center.

Product changes:

- Build `TodayPlanEngine` from readiness report, recent workouts, routine plan, target muscles, cardio freshness, yoga flows, available time, and check-in.
- Replace separate Home hierarchy with a dominant Today Plan module.
- Add a "why" drawer with the top drivers and missing data.
- Add "adjust plan" controls: time, equipment, soreness, goal.
- Add alternate starts: strength, cardio, recovery yoga.
- Add morning widget/notification copy: "Ready 72 - Upper Push or Z2 run today."

Success metrics:

- 60%+ of active users view Today Plan on training mornings.
- 40%+ of workouts start from Today Plan or quick start.
- 25%+ use an adjustment or alternate at least once by D14.
- D7 retention improves against baseline.

### Phase 3: Hevy-Beating Strength Loop (3-5 weeks)

Goal: make strength logging and next-time progression the obvious reason to stay.

Product changes:

- Finish all advanced set type UI and tests.
- Finish unilateral/bodyweight volume entry UX.
- Add progression engine v1:
  - target rep range
  - fixed increment or percent increment
  - RPE/RIR cap
  - explained suggestion
  - accept/reject/edit tracking
- Show next-time targets in post-workout summary and prefill next session.
- Add routine adherence and substitutions: "bench unavailable -> dumbbell press with adjusted targets."
- Add first-class "copy last workout" and "repeat previous set" flows if benchmark reveals friction.

Success metrics:

- <=2.5s median repeat-set logging.
- >=25% faster than Hevy in benchmark.
- 40%+ of strength sessions use a progression suggestion by accept, reject, or edit.
- 80%+ of routine users complete at least one suggested target review by D14.

### Phase 4: Watch And Health Reliability (parallel, 4-6 weeks)

Goal: earn trust for Apple Watch users.

Product changes:

- Complete Watch-only logging.
- Complete Watch/iPhone mirroring with shared UUID and idempotent set deltas.
- Finish Input Lock.
- Finish disconnect/reconnect recovery.
- Complete the Watch test matrix on real devices.
- Complete HealthKit biometric ingestion: HRV, RHR/sleeping HR, sleep, respiratory rate, wrist temp, SpO2, VO2max where available.
- Make missing/denied permissions explainable from the readiness UI.

Success metrics:

- 0 duplicate workouts in QA matrix.
- 0 zero-calorie completed Watch workouts in supported cases.
- 100% forced-disconnect test sessions reconcile without data loss.
- 90% readiness availability for users with overnight Watch wear.

### Phase 5: Cardio And Yoga Value (4-6 weeks)

Goal: replace casual use of separate cardio/yoga apps for the hybrid athlete.

Cardio:

- Finish modality-correct metrics.
- Add post-run/ride/row zone summary, splits, route map, and "what improved."
- Add weekly zone distribution and 80/20 readout.
- Add training load, CTL/ATL/form trend once enough data exists.

Yoga:

- Add recovery-focused flow generator with duration/focus/intensity/avoid controls.
- Use recent training to recommend mobility focus.
- Add "after workout" cooldown flow suggestions.
- Add pose alternatives and safety notes.

Success metrics:

- 30%+ of active users start at least one cardio or yoga session by D30.
- 25%+ of low-readiness days convert to recovery yoga, Zone 2, or rest instead of churn.
- 50%+ of cardio summaries display zones or route/split data.

### Phase 6: Sharing, Re-Entry, And Moat (ongoing)

Goal: turn private progress into identity and reactivation.

Product changes:

- Strava export with explicit field controls.
- Social-ready share cards for PRs, routes, Wrapped, consistency, and recovery wins.
- Monthly Wrapped notification and Home card.
- "Welcome back" flow after 7+ inactive days:
  - acknowledge break without guilt
  - ask current goal/time
  - suggest a lighter restart session
  - preserve streak history but start a fresh mini-streak
- Private squads later: 3-8 friends, consistency and PR feed, no public follower graph at first.

Success metrics:

- 15%+ of completed workouts produce a share action or export.
- 20%+ inactive users who reopen start a session within 48 hours.
- 25%+ of monthly active users open Wrapped when available.

## Metric System

### Activation

- Onboarding completion rate.
- Health connect rate.
- History import preview and commit rate.
- Starter program selection rate.
- First workout start within first session.
- First workout completion within 24 hours.
- First readiness/Today Plan view.

### Habit

- D1, D7, D14, D30 retention.
- Workouts completed in first 7 days.
- Morning Today Plan views per active week.
- Reminder enabled rate.
- Widget install rate.
- Quick start usage rate.
- Coach version start rate.

### Training Value

- Median set logging time.
- Median taps per set.
- Progression suggestion accept/reject/edit rate.
- PR detection rate.
- Substitution rate.
- Post-workout summary view completion.

### Trust

- Crash-free sessions.
- Failed save count.
- Duplicate workout count.
- HealthKit write success.
- Watch disconnect recovery success.
- CloudKit sync delay and conflict count.
- Data export/delete success.

### Monetizable Value

- Imported history users vs blank-slate users D30 retention.
- Users with 3+ modalities logged.
- Users with 3+ Today Plan starts.
- Share/export rate.
- Subscription/trial conversion if monetization is added later.

## Experiment Backlog

1. Onboarding path experiment: "import first" vs "program first" vs "train today first."
   - Hypothesis: explicit starting paths increase first workout completion.
2. Today Plan copy experiment: "Readiness score first" vs "Start recommendation first."
   - Hypothesis: action-first increases workout starts.
3. Morning nudge experiment: readiness notification vs training-day reminder.
   - Hypothesis: readiness plus concrete plan increases morning opens.
4. Post-workout loop experiment: next-target card vs PR/share card first.
   - Hypothesis: next-target card increases next-session return.
5. Re-entry experiment: normal Home vs welcome-back restart flow after inactivity.
   - Hypothesis: restart flow increases 48-hour workout starts for returning users.
6. Yoga recommendation experiment: generic flow vs muscle-specific recovery flow.
   - Hypothesis: muscle-specific copy increases yoga starts on low-readiness days.
7. Strava export experiment: export prompt after outdoor cardio vs hidden in share menu.
   - Hypothesis: explicit export prompt increases cardio user retention without needing a public social graph.

## Prioritized Feature List

### P0: Must Build Before Serious Beta

- Today Plan MVP.
- Local privacy-preserving product analytics.
- Hevy speed benchmark and set-entry improvements.
- HealthKit write verification for non-zero workouts.
- Offline local workout completion QA.
- Watch mirroring risk spike.
- Progression engine v1 for strength.
- First-value onboarding.
- Data export/delete plan and visible privacy language.

### P1: Makes Users Prefer ForgeFit

- Readiness-confidence UI with missing-data actions.
- Coach-adjusted workout starts from Today Plan.
- Post-workout "what improved / what it cost / what next" summary.
- Modality-correct cardio summaries and zone analysis.
- Recovery yoga flow generator.
- Strava export.
- Re-entry flow after inactivity.
- Monthly Wrapped surfaced as a retention event.

### P2: Differentiators After Trust

- Private squads.
- Route replay/share polish.
- Training block planning.
- Adaptive mesocycles.
- Advanced AI coach artifacts.
- iPad/web analysis dashboard.
- Nutrition only if it is explicitly tied to training energy/recovery, not a broad calorie tracker.

## What Not To Build Yet

- A full public social network. Strava and Hevy already have graph moats; ForgeFit should use share/export and private squads first.
- A generic yoga content library bigger than Down Dog. Use recovery-aware prescription instead.
- Broad nutrition, labs, or biological age just because Bevel has them. They dilute the hybrid-training wedge.
- AI chat as the main interface. It should explain and personalize, but the app must still have one-tap actions.
- Advanced analytics before basic reliability. Users do not trust charts from an app that can lose a workout.

## Competitive Battlecards

### Vs Hevy

Must match:

- Fast logging.
- Routine planning.
- Exercise library.
- Rest timers.
- PRs and graphs.
- Apple Watch reliability.

ForgeFit should beat:

- Readiness-adjusted workout starts.
- Strength + cardio + yoga in one training plan.
- Better unilateral/bodyweight/advanced set math.
- Progression suggestions with rationale.
- Recovery and muscle freshness tied to next targets.

### Vs Strava

Must match for hybrid users:

- Reliable recording/import.
- Good route/split/zone summaries.
- Share/export.

Do not try to beat early:

- Global feed.
- Route discovery graph.
- Segments as a social network.

ForgeFit should beat:

- Strength/cardio interference management.
- Recovery-aware cardio prescription.
- Training load that includes lifting and yoga context.

### Vs Down Dog

Must learn from:

- Fast personalization.
- Duration/focus/intensity controls.
- Clear voice-guided flow.
- Streaks/goals.

ForgeFit should beat for hybrid users:

- Recovery-aware flow selection.
- Mobility based on what the user actually trained.
- Post-workout cooldown and low-readiness alternatives.

### Vs Athlytic/Bevel

Must match:

- Morning score.
- Clear reason drivers.
- Widgets/notifications.
- Honest missing-data states.

ForgeFit should beat:

- Starting the recommended workout directly.
- Adapting routine dose, not just saying "recover."
- Combining per-muscle strength fatigue and cardio freshness.
- Privacy-first, local-first Apple ecosystem focus.

## Source Links

- Hevy App Store: https://apps.apple.com/us/app/hevy-workout-tracker-gym-log/id1458862350
- Hevy features: https://www.hevyapp.com/features/
- Strava App Store: https://apps.apple.com/us/app/strava-run-bike-walk/id426826309
- Strava site: https://www.strava.com/
- Strava Apple Watch Live Segments press release: https://press.strava.com/articles/strava-launches-redesigned-apple-watch-app-now-with-live-segments
- Strava hiking features press release: https://press.strava.com/articles/strava-adds-new-features-for-hiking-making-the-outdoor-experience-more-discoverable-navigable-and-social
- Down Dog App Store: https://apps.apple.com/us/app/yoga-down-dog/id983693694
- Down Dog site: https://www.downdogapp.com/
- Athlytic App Store: https://apps.apple.com/us/app/athlytic-ai-fitness-coach/id1543571755
- Bevel App Store: https://apps.apple.com/us/app/bevel-ai-health-coach/id6456176249
- Bevel site: https://www.bevel.health/
- University of Sydney activity-app/tracker research summary: https://www.sydney.edu.au/news-opinion/news/2020/12/22/physical-activity-levels-increased-by-smartphone-apps-and-fitnes.html
- JMIR smartphone app meta-analysis: https://www.jmir.org/2019/3/e12053/
- Multiple lives of activity tracking users: https://arxiv.org/abs/1802.08972
- MyFitnessPal first-week goal behavior study: https://arxiv.org/abs/1904.02813
