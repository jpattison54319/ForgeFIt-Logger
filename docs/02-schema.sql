-- =====================================================================
-- C — ForgeFit schema reference (PostgreSQL DDL)
-- Reference DDL documenting the data shape. The app uses SwiftData @Model
-- classes (in Packages/ForgeData) that mirror this schema, synced via CloudKit.
-- This SQL is NOT a live backend — it's a canonical schema reference.
-- Convention: PKs are client-generated UUIDs passed from device.
--             Every user-owned row carries user_id.
--             Soft deletes via deleted_at. Timestamps are timestamptz.
-- =====================================================================

create extension if not exists "pgcrypto";  -- gen_random_uuid fallback
create extension if not exists pg_trgm;     -- typo-tolerant exercise search (must precede trgm indexes)

-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
create type set_type as enum (
  'warmup','working','drop','rest_pause','backoff','amrap','myo_rep','cluster'
);

create type weight_mode as enum (
  'external',            -- standard barbell/dumbbell/machine load
  'bodyweight',          -- pure bodyweight (pullup, pushup)
  'bodyweight_assisted', -- assisted (assist machine, band) -> assistance_weight subtracts
  'bodyweight_added'     -- bodyweight + added_weight (weighted pullup/dip)
);

create type cardio_modality as enum (
  'run','walk','hike','cycle','row','stairmaster','elliptical','hiit','swim','other'
);

create type meso_block_type as enum (
  'accumulation','intensification','realization','deload','strength','hypertrophy'
);

create type progression_strategy as enum (
  'percent_increase','fixed_increment','rep_target','rpe_target','manual'
);

create type recommendation_action as enum (
  'maintain','push','reduce_volume','deload'
);

create type integration_provider as enum (
  'apple_health','strava'
);

create type sync_op as enum ('insert','update','delete');

-- ---------------------------------------------------------------------
-- Helper: updated_at trigger
-- ---------------------------------------------------------------------
create or replace function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end; $$ language plpgsql;

-- =====================================================================
-- profiles
-- =====================================================================
create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text,
  unit_weight   text not null default 'kg' check (unit_weight in ('kg','lb')),
  unit_distance text not null default 'km' check (unit_distance in ('km','mi')),
  body_weight_kg numeric(6,2),                 -- cached latest, full history in body_metrics
  hr_zone_model jsonb,                          -- {model:'lthr'|'maxhr'|'reserve', zones:[...]}
  birth_date    date,
  sex           text check (sex in ('male','female','other','unspecified')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create trigger trg_profiles_updated before update on profiles
  for each row execute function set_updated_at();

-- =====================================================================
-- exercise_library  (global rows: owner_id null; custom rows: owner_id set)
-- =====================================================================
create table exercise_library (
  id               uuid primary key,
  owner_id         uuid references auth.users(id) on delete cascade,  -- null => global
  name             text not null,
  movement_pattern text,            -- 'horizontal_push','squat','hinge','vertical_pull',...
  primary_muscles  text[] not null default '{}',
  secondary_muscles text[] not null default '{}',
  equipment        text,            -- 'barbell','dumbbell','cable','machine','smith','bodyweight',...
  is_unilateral    boolean not null default false,  -- default for sets of this exercise
  default_weight_mode weight_mode not null default 'external',
  preferred_weight_unit text check (preferred_weight_unit in ('kg','lb')),
  difficulty       text check (difficulty in ('beginner','intermediate','advanced')),
  is_cardio        boolean not null default false,
  mapped_global_id uuid references exercise_library(id),  -- custom -> global movement mapping
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);
create index idx_exlib_owner on exercise_library(owner_id);
create index idx_exlib_pattern on exercise_library(movement_pattern);
create index idx_exlib_name_trgm on exercise_library using gin (name gin_trgm_ops);
create trigger trg_exlib_updated before update on exercise_library
  for each row execute function set_updated_at();

-- =====================================================================
-- exercise_aliases  (search synonyms; global or user-scoped)
-- =====================================================================
create table exercise_aliases (
  id          uuid primary key,
  exercise_id uuid not null references exercise_library(id) on delete cascade,
  owner_id    uuid references auth.users(id) on delete cascade,  -- null => global alias
  alias       text not null,
  created_at  timestamptz not null default now()
);
create index idx_alias_exercise on exercise_aliases(exercise_id);
create index idx_alias_text_trgm on exercise_aliases using gin (alias gin_trgm_ops);

-- =====================================================================
-- user_exercise_notes  (auto-surface on exercise load: seat height, grip, pain...)
-- =====================================================================
create table user_exercise_notes (
  id          uuid primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  exercise_id uuid not null references exercise_library(id) on delete cascade,
  note        text not null,
  seat_height text,
  grip        text,
  stance      text,
  machine_settings jsonb,
  pain_flag   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, exercise_id)
);
create trigger trg_uxnotes_updated before update on user_exercise_notes
  for each row execute function set_updated_at();

-- =====================================================================
-- routines / routine_exercises / routine_sets  (templates)
-- =====================================================================
create table routines (
  id         uuid primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  notes      text,
  folder     text,
  position   int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index idx_routines_user on routines(user_id);
create trigger trg_routines_updated before update on routines
  for each row execute function set_updated_at();

create table routine_exercises (
  id           uuid primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  routine_id   uuid not null references routines(id) on delete cascade,
  exercise_id  uuid not null references exercise_library(id),
  position     int not null default 0,
  superset_group int,                  -- shared int => supersetted
  progression_rule_id uuid,            -- fk added after progression_rules
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index idx_rex_routine on routine_exercises(routine_id);
create trigger trg_rex_updated before update on routine_exercises
  for each row execute function set_updated_at();

create table routine_sets (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  routine_exercise_id uuid not null references routine_exercises(id) on delete cascade,
  position      int not null default 0,
  set_type      set_type not null default 'working',
  target_reps_low  int,
  target_reps_high int,
  target_weight numeric(7,2),
  target_rpe    numeric(3,1),
  target_rir    int,
  target_duration_s int,
  created_at    timestamptz not null default now()
);
create index idx_rsets_rex on routine_sets(routine_exercise_id);

-- =====================================================================
-- workouts / workout_exercises / sets  (actuals)
-- =====================================================================
create table workouts (
  id              uuid primary key,                  -- shared with Watch session for dedup
  user_id         uuid not null references auth.users(id) on delete cascade,
  routine_id      uuid references routines(id),
  title           text,
  started_at      timestamptz not null,
  ended_at        timestamptz,
  hk_workout_uuid uuid,                               -- HealthKit HKWorkout linkage
  source_device   text,                              -- 'iphone'|'watch'
  total_volume    numeric(12,2),                     -- denormalized cache (server-computed)
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);
create index idx_workouts_user_started on workouts(user_id, started_at desc);
create unique index uq_workouts_hk on workouts(user_id, hk_workout_uuid)
  where hk_workout_uuid is not null;
create trigger trg_workouts_updated before update on workouts
  for each row execute function set_updated_at();

create table workout_exercises (
  id           uuid primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  workout_id   uuid not null references workouts(id) on delete cascade,
  exercise_id  uuid not null references exercise_library(id),
  position     int not null default 0,
  superset_group int,
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index idx_wex_workout on workout_exercises(workout_id);
create trigger trg_wex_updated before update on workout_exercises
  for each row execute function set_updated_at();

create table sets (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  workout_exercise_id uuid not null references workout_exercises(id) on delete cascade,
  position      int not null default 0,
  set_type      set_type not null default 'working',
  weight_mode   weight_mode not null default 'external',

  -- core metrics (all nullable; presence depends on exercise/set type)
  reps          int,
  weight        numeric(7,2),          -- the load the user entered
  rpe           numeric(3,1),
  rir           int,
  duration_s    int,                   -- timed sets/cardio-ish holds
  hold_s        int,                   -- isometric hold time
  partial_reps  int,                   -- partials appended to full reps

  -- bodyweight handling
  added_weight       numeric(7,2),     -- weighted pullup/dip plate load
  assistance_weight  numeric(7,2),     -- assist machine/band offset
  bodyweight_kg      numeric(6,2),     -- snapshot of BW at time of set (for true load)

  -- unilateral handling
  is_unilateral  boolean not null default false,
  implement_weight numeric(7,2),       -- weight of ONE dumbbell/implement
  limb_count     int not null default 2,

  -- modifiers
  is_eccentric   boolean not null default false,  -- negative/eccentric emphasis
  is_paused      boolean not null default false,

  -- machine/cable context
  machine_settings jsonb,              -- {seat:4, pin:'cable_mid', incline:30,...}

  -- computed (server, via Edge Function / generated): true working volume
  effective_load numeric(8,2),         -- resolved per-rep load after mode/unilateral
  total_volume   numeric(12,2),        -- effective_load * reps * (unilateral? limb_count : 1)
  est_1rm        numeric(7,2),

  completed_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_sets_wex on sets(workout_exercise_id);
create index idx_sets_user on sets(user_id);
create trigger trg_sets_updated before update on sets
  for each row execute function set_updated_at();

-- =====================================================================
-- cardio_sessions  (summary metrics; high-res telemetry offloaded to Storage)
-- =====================================================================
create table cardio_sessions (
  id              uuid primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  workout_id      uuid references workouts(id) on delete set null,  -- optional link
  modality        cardio_modality not null,
  started_at      timestamptz not null,
  ended_at        timestamptz,
  hk_workout_uuid uuid,
  source_device   text,

  -- shared summary
  duration_s      int,
  distance_m      numeric(10,2),
  active_energy_kcal numeric(8,1),
  avg_hr          int,
  max_hr          int,
  hr_zone_seconds int[],               -- [z1,z2,z3,z4,z5] seconds in each zone

  -- modality-specific summary (nullable)
  floors_climbed   int,                -- stairmaster
  total_steps      int,                -- stairmaster/walk/run
  steps_per_min    int,
  avg_pace_s_per_km numeric(7,2),      -- run/walk/hike
  split_500m_s     numeric(7,2),       -- rowing split
  stroke_rate      int,                -- rowing
  avg_power_w      numeric(7,1),       -- row/cycle/run power
  avg_cadence      int,                -- cycle/run
  resistance_level int,                -- cycle/elliptical/stairmaster
  incline_pct      numeric(5,2),       -- elliptical/walk
  strides_per_min  int,                -- elliptical
  elevation_gain_m numeric(8,1),       -- hike/walk/run
  avg_stride_length_m numeric(5,2),    -- run
  avg_vertical_oscillation_cm numeric(5,2), -- run
  avg_running_power_w numeric(7,1),    -- run

  -- HIIT
  interval_count   int,
  peak_hr          int,
  recovery_hr_60s  int,                -- HR drop 60s post-effort

  -- load
  tss              numeric(7,1),       -- TSS-like score (Edge Function)

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);
create index idx_cardio_user_started on cardio_sessions(user_id, started_at desc);
create index idx_cardio_modality on cardio_sessions(user_id, modality);
create trigger trg_cardio_updated before update on cardio_sessions
  for each row execute function set_updated_at();

-- =====================================================================
-- cardio_telemetry_files  (pointers to Storage objects)
-- =====================================================================
create table cardio_telemetry_files (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  cardio_session_id uuid not null references cardio_sessions(id) on delete cascade,
  kind          text not null,        -- 'hr_series','power_series','pace_series','route','heartbeat_series'
  storage_path  text not null,        -- telemetry/<user_id>/<session>/<kind>.json.gz
  format        text not null default 'json_gz',
  sample_count  int,
  byte_size     bigint,
  created_at    timestamptz not null default now()
);
create index idx_telemetry_session on cardio_telemetry_files(cardio_session_id);

-- =====================================================================
-- health_metrics  (daily biometric ingestion from HealthKit)
-- =====================================================================
create table health_metrics (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  metric_date   date not null,
  hrv_sdnn_ms   numeric(6,2),
  hrv_rmssd_ms  numeric(6,2),          -- derived from heartbeat series when available
  hrv_sample_count int,
  resting_hr    int,
  sleep_total_min int,
  sleep_rem_min  int,
  sleep_deep_min int,
  sleep_core_min int,
  sleep_sample_count int,
  sleep_debt_hours numeric(5,2),
  respiratory_rate numeric(5,2),
  wrist_temp_c   numeric(4,2),
  spo2_pct       numeric(5,2),
  vo2max         numeric(5,2),
  data_quality_flags text[] not null default '{}',
  source         text,                 -- 'apple_watch','iphone','manual'
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (user_id, metric_date)
);
create index idx_health_user_date on health_metrics(user_id, metric_date desc);
create trigger trg_health_updated before update on health_metrics
  for each row execute function set_updated_at();

-- =====================================================================
-- body_metrics  (weight & composition history)
-- =====================================================================
create table body_metrics (
  id           uuid primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  measured_at  timestamptz not null,
  body_weight_kg numeric(6,2),
  body_fat_pct numeric(5,2),
  lean_mass_kg numeric(6,2),
  source       text,
  created_at   timestamptz not null default now()
);
create index idx_body_user_time on body_metrics(user_id, measured_at desc);

-- =====================================================================
-- readiness_scores
-- =====================================================================
create table readiness_scores (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  score_date    date not null,
  score         int not null check (score between 0 and 100),
  hrv_component numeric(5,2),
  rhr_component numeric(5,2),
  sleep_component numeric(5,2),
  baseline_window_days int,
  used_rmssd    boolean not null default false,   -- true=heartbeat-series path, false=fallback
  formula_version text not null default 'readiness_v1',
  confidence    numeric(5,2),
  missing_inputs text[] not null default '{}',
  sleep_debt_hours numeric(5,2),
  recommended_action recommendation_action,
  explanation   text,                              -- plain-language "why"
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (user_id, score_date)
);
create index idx_readiness_user_date on readiness_scores(user_id, score_date desc);
create trigger trg_readiness_updated before update on readiness_scores
  for each row execute function set_updated_at();

-- =====================================================================
-- progression_rules
-- =====================================================================
create table progression_rules (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  name          text not null,
  strategy      progression_strategy not null,
  percent_step  numeric(5,2),         -- e.g. 2.5 for +2.5%
  fixed_step    numeric(7,2),         -- e.g. 2.5 kg
  rep_target_low  int,
  rep_target_high int,
  rpe_target    numeric(3,1),
  applies_scope text not null default 'exercise', -- 'exercise'|'global'
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create trigger trg_prules_updated before update on progression_rules
  for each row execute function set_updated_at();

-- now that progression_rules exists, wire routine_exercises fk
alter table routine_exercises
  add constraint fk_rex_progression
  foreign key (progression_rule_id) references progression_rules(id) on delete set null;

-- =====================================================================
-- progression_recommendations
-- =====================================================================
create table progression_recommendations (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  exercise_id   uuid not null references exercise_library(id),
  routine_exercise_id uuid references routine_exercises(id) on delete set null,
  recommended_for_date date,
  prev_workout_id uuid references workouts(id) on delete set null,
  suggested_weight numeric(7,2),
  suggested_reps_low int,
  suggested_reps_high int,
  delta_pct     numeric(5,2),
  rationale     text,                 -- "hit 12 vs target 8-10 -> +2.5%"
  status        text not null default 'pending' check (status in ('pending','accepted','rejected','expired')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index idx_precs_user on progression_recommendations(user_id, recommended_for_date desc);
create trigger trg_precs_updated before update on progression_recommendations
  for each row execute function set_updated_at();

-- =====================================================================
-- training_load_daily  (CTL/ATL/TSS rollups)
-- =====================================================================
create table training_load_daily (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  load_date     date not null,
  daily_load     numeric(8,1) not null default 0,  -- universal load, usually sRPE fallback or modality load
  strength_load  numeric(8,1) not null default 0,  -- tonnage + proximity-to-failure proxy
  cardio_load    numeric(8,1) not null default 0,  -- TSS/TRIMP/zone-derived when available
  daily_tss     numeric(8,1) not null default 0,
  strength_tonnage numeric(12,2),
  ctl           numeric(8,2),         -- chronic training load (fitness), ~42d EWMA
  atl           numeric(8,2),         -- acute training load (fatigue), ~7d EWMA
  tsb           numeric(8,2),         -- training stress balance = ctl - atl (form)
  acwr          numeric(6,3),         -- spike heuristic, not an injury prediction
  monotony      numeric(6,3),
  strain        numeric(8,1),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (user_id, load_date)
);
create index idx_load_user_date on training_load_daily(user_id, load_date desc);
create trigger trg_load_updated before update on training_load_daily
  for each row execute function set_updated_at();

-- =====================================================================
-- mesocycles (ADV — block planning)
-- =====================================================================
create table mesocycles (
  id          uuid primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  block_type  meso_block_type not null,
  start_date  date,
  end_date    date,
  config      jsonb,                  -- volume/intensity progression params
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);
create index idx_meso_user on mesocycles(user_id);
create trigger trg_meso_updated before update on mesocycles
  for each row execute function set_updated_at();

-- =====================================================================
-- integrations  (OAuth tokens & provider state)  -- highly sensitive
-- =====================================================================
create table integrations (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  provider      integration_provider not null,
  access_token  text,                 -- consider Vault; never exposed to client reads
  refresh_token text,
  expires_at    timestamptz,
  scopes        text[],
  external_user_id text,
  enabled       boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (user_id, provider)
);
create trigger trg_integrations_updated before update on integrations
  for each row execute function set_updated_at();

-- =====================================================================
-- sync_events  (server-side audit/cursor of device sync ops)
-- =====================================================================
create table sync_events (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  device_id     text not null,
  table_name    text not null,
  row_id        uuid not null,
  op            sync_op not null,
  client_ts     timestamptz not null,
  server_ts     timestamptz not null default now()
);
create index idx_sync_user_server on sync_events(user_id, server_ts desc);

-- =====================================================================
-- forgefit_records  (local-first device mirror)
-- =====================================================================
create table forgefit_records (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  record_type text        not null,
  record_id   uuid        not null,
  updated_at  timestamptz not null,
  deleted_at  timestamptz,
  payload     jsonb       not null,
  primary key (user_id, record_type, record_id)
);
create index idx_forgefit_records_user_updated
  on forgefit_records(user_id, record_type, updated_at);

create or replace function forgefit_records_keep_newest() returns trigger as $$
begin
  if tg_op = 'UPDATE' and old.updated_at > new.updated_at then
    return old;
  end if;
  return new;
end; $$ language plpgsql;

create trigger trg_forgefit_records_lww
  before update on forgefit_records
  for each row execute function forgefit_records_keep_newest();

-- =====================================================================
-- ROW LEVEL SECURITY
-- Pattern: enable RLS, then a single policy per user-owned table.
-- exercise_library / exercise_aliases also allow reading GLOBAL rows.
-- =====================================================================

-- user-owned tables: full CRUD scoped to auth.uid()
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','user_exercise_notes','routines','routine_exercises','routine_sets',
    'workouts','workout_exercises','sets','cardio_sessions','cardio_telemetry_files',
    'health_metrics','body_metrics','readiness_scores','progression_rules',
    'progression_recommendations','training_load_daily','mesocycles','integrations','sync_events',
    'forgefit_records'
  ] loop
    execute format('alter table %I enable row level security;', t);
    -- profiles keys on id; the rest key on user_id
    if t = 'profiles' then
      execute format($f$
        create policy %1$s_owner on %1$I
        using (id = auth.uid()) with check (id = auth.uid());
      $f$, t);
    else
      execute format($f$
        create policy %1$s_owner on %1$I
        using (user_id = auth.uid()) with check (user_id = auth.uid());
      $f$, t);
    end if;
  end loop;
end $$;

-- exercise_library: read global (owner_id is null) OR your own; write only your own
alter table exercise_library enable row level security;
create policy exlib_read on exercise_library
  for select using (owner_id is null or owner_id = auth.uid());
create policy exlib_write on exercise_library
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- exercise_aliases: read global or your own; write only your own
alter table exercise_aliases enable row level security;
create policy alias_read on exercise_aliases
  for select using (owner_id is null or owner_id = auth.uid());
create policy alias_write on exercise_aliases
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- NOTE: integrations.access_token/refresh_token should additionally be protected by
-- column privileges or moved to Supabase Vault; clients never need to read raw tokens.

-- =====================================================================
-- profiles auto-provision on signup
-- =====================================================================
create or replace function handle_new_user() returns trigger as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', null))
  on conflict (id) do nothing;
  return new;
end; $$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- =====================================================================
-- Storage bucket (run via Supabase API/dashboard or storage migration):
--   bucket 'telemetry' (private). Path convention: <user_id>/<session_id>/<kind>.json.gz
--   Policy: a user may read/write only objects whose first path segment = auth.uid().
-- =====================================================================
