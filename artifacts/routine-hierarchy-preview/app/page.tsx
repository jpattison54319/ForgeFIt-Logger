"use client";

import { useState } from "react";

type LibraryState = "flat" | "single" | "nested" | "mixed";
type Presentation = "proposed" | "current";
type DropState = "normal" | "accepted" | "rejected";

const stateLabels: Record<LibraryState, string> = {
  flat: "Routines only",
  single: "One folder",
  nested: "Nested cycle",
  mixed: "Mixed library",
};

const routines = {
  push: ["Push 1 + mile", "Bench Press", "Incline Press", "Shoulder Press"],
  pull: ["Pull 1", "Deadlift", "Pullups", "Cable Row"],
  lower: ["Lower", "Back Squat", "Romanian Deadlift", "Leg Press"],
  run: ["Zone 2 5K", "Easy Run", "5 km · Zone 2"],
  hotel: ["Hotel Workout", "Goblet Squat", "Pushups", "Rows"],
};

function RoutineCard({ data }: { data: string[] }) {
  return (
    <article className="routine-card">
      <div className="routine-topline">
        <h3>{data[0]}</h3>
        <button className="start-button" aria-label={`Start ${data[0]}`}>
          <span aria-hidden="true">▶</span> Start
        </button>
        <button className="drag-handle" aria-label={`Reorder ${data[0]}`}>≡</button>
        <button className="more-button" aria-label={`Options for ${data[0]}`}>•••</button>
      </div>
      <ul>
        {data.slice(1).map((item) => <li key={item}>{item}</li>)}
      </ul>
    </article>
  );
}

function FolderHeader({
  name,
  count,
  active = false,
  child = false,
}: {
  name: string;
  count: number;
  active?: boolean;
  child?: boolean;
}) {
  return (
    <div className={`folder-header ${child ? "child-header" : ""}`}>
      <button className="folder-title" aria-label={`Collapse ${name}`}>
        <span className="chevron" aria-hidden="true">⌄</span>
        <span className="folder-symbol" aria-hidden="true">{active ? "★" : "▰"}</span>
        <span>{name}</span>
        <span className="count">{count}</span>
        {active && <span className="active-pill">ACTIVE</span>}
      </button>
      <button className="more-button" aria-label={`Options for ${name}`}>•••</button>
    </div>
  );
}

function ProgressPanel() {
  return (
    <div className="progress-panel">
      <div className="progress-icon" aria-hidden="true">▣</div>
      <div>
        <strong>MICROCYCLE PROGRESS</strong>
        <span>Day 4 of 9 · 2 of 6 workouts</span>
      </div>
      <span className="progress-arrow" aria-hidden="true">›</span>
    </div>
  );
}

function DropMessage({ state }: { state: DropState }) {
  if (state === "normal") return null;
  const accepted = state === "accepted";
  return (
    <div className={`drop-message ${accepted ? "accepted" : "rejected"}`}>
      <span aria-hidden="true">{accepted ? "✓" : "!"}</span>
      <div>
        <strong>{accepted ? "Move Pull 1 into Hybrid Athlete" : "Can’t add routines here"}</strong>
        <small>{accepted ? "Release to place it after Push 1 + mile" : "Macro 1 contains subfolders only"}</small>
      </div>
    </div>
  );
}

function ProposedLibrary({ libraryState, dropState }: { libraryState: LibraryState; dropState: DropState }) {
  if (libraryState === "flat") {
    return (
      <div className="flat-list">
        <RoutineCard data={routines.push} />
        <RoutineCard data={routines.pull} />
        <RoutineCard data={routines.run} />
      </div>
    );
  }

  if (libraryState === "single") {
    return (
      <section className={`section-list ${dropState !== "normal" ? `drop-${dropState}` : ""}`}>
        <FolderHeader name="Hybrid Athlete" count={3} active />
        <ProgressPanel />
        <div className="section-content">
          <RoutineCard data={routines.push} />
          <RoutineCard data={routines.pull} />
          <RoutineCard data={routines.lower} />
        </div>
        <DropMessage state={dropState} />
      </section>
    );
  }

  if (libraryState === "nested") {
    return (
      <section className="cycle-list">
        <FolderHeader name="Macro 1" count={2} active />
        <div className="nested-rail">
          <section className={`child-section ${dropState !== "normal" ? `drop-${dropState}` : ""}`}>
            <FolderHeader name="Hybrid Athlete" count={3} active child />
            <ProgressPanel />
            <div className="section-content">
              <RoutineCard data={routines.push} />
              <RoutineCard data={routines.pull} />
              <RoutineCard data={routines.lower} />
            </div>
            <DropMessage state={dropState} />
          </section>
          <FolderHeader name="Running" count={1} child />
        </div>
      </section>
    );
  }

  return (
    <div className="mixed-list">
      <section className="root-routines">
        <h2>Ungrouped <span>1</span></h2>
        <RoutineCard data={routines.hotel} />
      </section>
      <section className={`section-list ${dropState !== "normal" ? `drop-${dropState}` : ""}`}>
        <FolderHeader name="Hybrid Athlete" count={2} active />
        <div className="section-content">
          <RoutineCard data={routines.push} />
          <RoutineCard data={routines.pull} />
        </div>
        <DropMessage state={dropState} />
      </section>
      <section className="section-list">
        <FolderHeader name="Running" count={1} />
        <div className="section-content"><RoutineCard data={routines.run} /></div>
      </section>
    </div>
  );
}

function CurrentLibrary({ libraryState }: { libraryState: LibraryState }) {
  const folders = libraryState === "nested"
    ? [{ name: "Macro 1", nested: true }]
    : libraryState === "mixed"
      ? [{ name: "Hybrid Athlete", nested: false }, { name: "Running", nested: false }]
      : [{ name: "Hybrid Athlete", nested: false }];

  if (libraryState === "flat") {
    return (
      <div className="current-flat">
        <h2>Ungrouped</h2>
        <RoutineCard data={routines.push} />
        <RoutineCard data={routines.pull} />
        <RoutineCard data={routines.run} />
      </div>
    );
  }

  return (
    <div className="current-library">
      {libraryState === "mixed" && <section className="current-flat"><h2>Ungrouped</h2><RoutineCard data={routines.hotel} /></section>}
      {folders.map((folder) => (
        <section className="current-folder" key={folder.name}>
          <FolderHeader name={folder.name} count={folder.nested ? 1 : 3} active={folder.name !== "Running"} />
          {folder.nested ? (
            <section className="current-folder nested-current">
              <FolderHeader name="Hybrid Athlete" count={3} active child />
              <ProgressPanel />
              <RoutineCard data={routines.push} />
              <RoutineCard data={routines.pull} />
            </section>
          ) : (
            <>
              {folder.name === "Hybrid Athlete" && <ProgressPanel />}
              <RoutineCard data={folder.name === "Running" ? routines.run : routines.push} />
              {folder.name === "Hybrid Athlete" && <RoutineCard data={routines.pull} />}
            </>
          )}
        </section>
      ))}
    </div>
  );
}

export default function Home() {
  const [presentation, setPresentation] = useState<Presentation>("proposed");
  const [libraryState, setLibraryState] = useState<LibraryState>("nested");
  const [dropState, setDropState] = useState<DropState>("normal");

  return (
    <main>
      <header className="page-header">
        <p className="eyebrow">ForgeFit approval preview</p>
        <h1>Routine hierarchy refresh</h1>
        <p>Compare the current nested containers with a quieter hierarchy that becomes explicit only when moving something.</p>
      </header>

      <section className="control-panel" aria-label="Preview controls">
        <div className="segmented" role="group" aria-label="Presentation">
          {(["proposed", "current"] as Presentation[]).map((value) => (
            <button key={value} className={presentation === value ? "selected" : ""} onClick={() => setPresentation(value)}>
              {value === "proposed" ? "Proposed" : "Current"}
            </button>
          ))}
        </div>
        <div className="state-tabs" role="group" aria-label="Library state">
          {(Object.keys(stateLabels) as LibraryState[]).map((value) => (
            <button key={value} className={libraryState === value ? "selected" : ""} onClick={() => setLibraryState(value)}>
              {stateLabels[value]}
            </button>
          ))}
        </div>
        <div className="drop-controls">
          <span>Drop feedback</span>
          <div role="group" aria-label="Drop feedback state">
            {(["normal", "accepted", "rejected"] as DropState[]).map((value) => (
              <button
                key={value}
                disabled={presentation === "current" || libraryState === "flat"}
                className={dropState === value ? "selected" : ""}
                onClick={() => setDropState(value)}
              >
                {value[0].toUpperCase() + value.slice(1)}
              </button>
            ))}
          </div>
        </div>
      </section>

      <section className="preview-stage">
        <div className="phone-shell">
          <div className="status-bar"><span>9:41</span><span>▮▮▮ ◉ ▰</span></div>
          <div className="phone-content">
            <h2 className="screen-title">Workout</h2>
            <button className="empty-workout">＋ <span>Start Empty Workout</span></button>
            <div className="routines-heading">
              <h2>Routines</h2>
              <button>Edit Order</button>
              <button aria-label="New folder">▱<sup>＋</sup></button>
            </div>
            <div className="top-actions">
              <button>＋ New Routine</button><button>✦ Explore</button>
            </div>
            <div className="library-scroll">
              {presentation === "proposed"
                ? <ProposedLibrary libraryState={libraryState} dropState={dropState} />
                : <CurrentLibrary libraryState={libraryState} />}
            </div>
          </div>
          <div className="home-indicator" />
        </div>
      </section>

      <section className="decision-notes">
        <article><span>1</span><div><h2>One mental model</h2><p>The data hierarchy never changes. Only unnecessary resting decoration disappears.</p></div></article>
        <article><span>2</span><div><h2>Depth means something</h2><p>The hierarchy rail appears only for a real mesocycle-to-microcycle relationship.</p></div></article>
        <article><span>3</span><div><h2>Borders become functional</h2><p>Strong boundaries return while hovering over an accepted or rejected destination.</p></div></article>
      </section>
    </main>
  );
}
