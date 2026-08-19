"use client";

import { useEffect, useState } from "react";
import styles from "./myo-reps.module.css";

type Side = 1 | 2;
type Screen = "workout" | "runner" | "editor";

type SideProgress = {
  activationReps: number | null;
  minis: number[];
};

type MyoProgress = {
  weight: number;
  side1: SideProgress;
  side2: SideProgress;
};

const initialProgress = (): MyoProgress => ({
  weight: 150,
  side1: { activationReps: null, minis: [] },
  side2: { activationReps: null, minis: [] },
});

const cloneProgress = (progress: MyoProgress): MyoProgress => ({
  weight: progress.weight,
  side1: { ...progress.side1, minis: [...progress.side1.minis] },
  side2: { ...progress.side2, minis: [...progress.side2.minis] },
});

function Stepper({
  label,
  value,
  unit,
  step,
  minimum,
  onChange,
}: {
  label: string;
  value: number;
  unit?: string;
  step: number;
  minimum: number;
  onChange: (value: number) => void;
}) {
  return (
    <div className={styles.stepper}>
      <span className={styles.stepperLabel}>{label}</span>
      <div className={styles.stepperControls}>
        <button
          className={styles.stepperButton}
          type="button"
          aria-label={`Decrease ${label}`}
          onClick={() => onChange(Math.max(minimum, value - step))}
        >
          −
        </button>
        <div className={styles.stepperValue} aria-live="polite">
          <strong>{value}</strong>
          {unit ? <span>{unit}</span> : null}
        </div>
        <button
          className={styles.stepperButton}
          type="button"
          aria-label={`Increase ${label}`}
          onClick={() => onChange(value + step)}
        >
          +
        </button>
      </div>
    </div>
  );
}

function SideTabs({ side, onChange }: { side: Side; onChange: (side: Side) => void }) {
  return (
    <div className={styles.sideTabs} role="tablist" aria-label="Myo-rep side">
      {([1, 2] as const).map((candidate) => (
        <button
          type="button"
          role="tab"
          aria-selected={side === candidate}
          className={side === candidate ? styles.sideTabActive : styles.sideTab}
          onClick={() => onChange(candidate)}
          key={candidate}
        >
          Side {candidate}
        </button>
      ))}
    </div>
  );
}

function WorkoutCard({
  progress,
  completed,
  microRest,
  onStart,
  onEdit,
}: {
  progress: MyoProgress;
  completed: boolean;
  microRest: number;
  onStart: () => void;
  onEdit: () => void;
}) {
  const hasProgress = progress.side1.activationReps !== null || progress.side2.activationReps !== null;
  const actionTitle = completed ? "Edit Myo-rep Set" : hasProgress ? "Resume Myo-rep Set" : "Start Myo-rep Set";
  const summary = (side: SideProgress) => {
    const activation = side.activationReps ?? "—";
    return side.minis.length ? `${activation} + ${side.minis.join("+")}` : `${activation} activation`;
  };

  return (
    <main className={styles.workoutScreen}>
      <header className={styles.workoutTopbar}>
        <button type="button" className={styles.iconButton} aria-label="Minimize workout">⌄</button>
        <div>
          <p>Log Workout</p>
          <strong>Pull + Arms</strong>
        </div>
        <button type="button" className={styles.finishWorkout}>Finish</button>
      </header>

      <section className={styles.exerciseCard} aria-label="Atlantis Horizontal Bicep Isolator">
        <div className={styles.exerciseHeader}>
          <div className={styles.exerciseIcon} aria-hidden="true">●━●</div>
          <div className={styles.exerciseTitle}>
            <h1>Atlantis Horizontal<br />Bicep Isolator</h1>
            <span>›</span>
          </div>
          <button type="button" className={styles.iconButton} aria-label="Exercise options">•••</button>
        </div>

        <button type="button" className={styles.restMenu}>
          <span aria-hidden="true">◷</span> Rest Timer: 2:00 <span aria-hidden="true">⌄</span>
        </button>

        <div className={styles.columnHeader} aria-hidden="true">
          <span>✓</span><span>SET</span><span>PREVIOUS</span><span>LBS</span><span>REPS</span>
        </div>
        <div className={styles.regularSet}>
          <span className={styles.emptyCheck} aria-hidden="true" />
          <strong>1</strong>
          <span>150 × 10</span>
          <span className={styles.smallField}>150</span>
          <span className={styles.smallField}>10</span>
        </div>

        <article className={`${styles.myoCard} ${completed ? styles.myoCardComplete : ""}`}>
          <div className={styles.myoHeading}>
            <span className={completed ? styles.completeCheck : styles.emptyCheck} aria-hidden="true">
              {completed ? "✓" : ""}
            </span>
            <span className={styles.myoBadge}>M&nbsp; Myo-reps</span>
            <span className={styles.myoMeta}>Both sides · 4 minis · ◷ {microRest}s</span>
          </div>

          {completed ? (
            <div className={styles.completedSummary}>
              <div>
                <span>WEIGHT</span>
                <strong>{progress.weight} lb</strong>
              </div>
              <div>
                <span>SIDE 1</span>
                <strong>{summary(progress.side1)}</strong>
              </div>
              <div>
                <span>SIDE 2</span>
                <strong>{summary(progress.side2)}</strong>
              </div>
            </div>
          ) : hasProgress ? (
            <div className={styles.resumeSummary}>
              <span>Side 1 logged</span>
              <strong>{summary(progress.side1)} · {progress.weight} lb</strong>
            </div>
          ) : (
            <div className={styles.planSummary}>
              <div>
                <span>PREVIOUS MYO-REP SET</span>
                <strong>150 lb · 7 + 3+3+3+3</strong>
              </div>
              <span className={styles.readyPill}>Ready</span>
            </div>
          )}

          <button
            type="button"
            className={completed ? styles.secondaryAction : styles.primaryAction}
            onClick={completed ? onEdit : onStart}
          >
            <span aria-hidden="true">{completed ? "✎" : hasProgress ? "▶" : "▶"}</span>
            {actionTitle}
          </button>
        </article>

        <button type="button" className={styles.addSet}>＋ Add Set</button>
      </section>
    </main>
  );
}

function Runner({
  progress,
  setProgress,
  side,
  setSide,
  rest,
  setRest,
  microRest,
  setMicroRest,
  onClose,
  onFinish,
}: {
  progress: MyoProgress;
  setProgress: (progress: MyoProgress) => void;
  side: Side;
  setSide: (side: Side) => void;
  rest: number;
  setRest: (seconds: number) => void;
  microRest: number;
  setMicroRest: (seconds: number) => void;
  onClose: () => void;
  onFinish: () => void;
}) {
  const current = side === 1 ? progress.side1 : progress.side2;
  const [weightDraft, setWeightDraft] = useState(progress.weight);
  const [activationDraft, setActivationDraft] = useState(current.activationReps ?? 7);
  const [miniDraft, setMiniDraft] = useState(current.minis.at(-1) ?? (side === 2 ? progress.side1.minis[0] : undefined) ?? 3);
  const [editingMini, setEditingMini] = useState<number | null>(null);
  const [editingActivation, setEditingActivation] = useState(false);

  useEffect(() => {
    const selected = side === 1 ? progress.side1 : progress.side2;
    setActivationDraft(selected.activationReps ?? 7);
    setMiniDraft(selected.minis.at(-1) ?? (side === 2 ? progress.side1.minis[0] : undefined) ?? 3);
    setEditingMini(null);
    setEditingActivation(false);
  }, [side, progress.side1, progress.side2]);

  const updateSide = (next: SideProgress) => {
    setProgress(side === 1 ? { ...progress, side1: next } : { ...progress, side2: next });
  };

  const logActivation = () => {
    const nextProgress = {
      ...progress,
      weight: side === 1 ? weightDraft : progress.weight,
      [side === 1 ? "side1" : "side2"]: { ...current, activationReps: activationDraft },
    } as MyoProgress;
    setProgress(nextProgress);
    setEditingActivation(false);
    if (current.activationReps === null) setRest(microRest);
  };

  const logMini = () => {
    const minis = [...current.minis];
    if (editingMini === null) minis.push(miniDraft);
    else minis[editingMini] = miniDraft;
    updateSide({ ...current, minis });
    const startsNextRest = editingMini === null;
    setEditingMini(null);
    if (startsNextRest) setRest(microRest);
  };

  const beginMiniEdit = (index: number) => {
    setEditingMini(index);
    setMiniDraft(current.minis[index]);
  };

  const removeEditingMini = () => {
    if (editingMini === null) return;
    updateSide({ ...current, minis: current.minis.filter((_, index) => index !== editingMini) });
    setEditingMini(null);
  };

  const finishEnabled = progress.side1.activationReps !== null && progress.side2.activationReps !== null;

  return (
    <main className={styles.runnerScreen}>
      <header className={styles.runnerTopbar}>
        <button type="button" className={styles.iconButton} aria-label="Save progress and return to workout" onClick={onClose}>⌄</button>
        <div>
          <strong>Myo-rep Set</strong>
          <span>Atlantis Bicep Isolator</span>
        </div>
        <span className={styles.setBadge}>SET 2</span>
      </header>

      <SideTabs side={side} onChange={setSide} />

      <section className={styles.runnerBody}>
        <div className={styles.runnerIntro}>
          <div>
            <span className={styles.eyebrow}>SIDE {side}</span>
            <h1>{current.activationReps === null ? "Activation set" : "Mini-sets"}</h1>
          </div>
          <button
            type="button"
            className={styles.restChip}
            aria-label={`Change micro-rest, currently ${microRest} seconds`}
            onClick={() => setMicroRest(microRest === 15 ? 20 : microRest === 20 ? 30 : 15)}
          >
            ◷ {microRest}s
          </button>
        </div>

        {current.activationReps === null ? (
          <>
            <section className={styles.previousCard}>
              <span>PREVIOUS MYO-REP SET</span>
              <strong>150 lb · 7 activation</strong>
            </section>

            <section className={styles.controlCard}>
              {side === 1 ? (
                <Stepper label="Activation weight" value={weightDraft} unit="lb" step={5} minimum={0} onChange={setWeightDraft} />
              ) : (
                <div className={styles.sharedWeight}>
                  <span>WEIGHT · SHARED</span>
                  <strong>{progress.weight} lb</strong>
                </div>
              )}
              <Stepper label="Activation reps" value={activationDraft} step={1} minimum={1} onChange={setActivationDraft} />
            </section>

            <button type="button" className={styles.heroAction} onClick={logActivation}>
              <span aria-hidden="true">✓</span> Log Activation
            </button>
          </>
        ) : (
          <>
            <section className={styles.activationLogged}>
              <span className={styles.completeCheck} aria-hidden="true">✓</span>
              <div>
                <span>ACTIVATION LOGGED</span>
                <strong>{progress.weight} lb × {current.activationReps}</strong>
              </div>
              <button
                type="button"
                onClick={() => {
                  setActivationDraft(current.activationReps ?? 7);
                  setWeightDraft(progress.weight);
                  setEditingActivation((editing) => !editing);
                }}
                aria-label={editingActivation ? "Cancel activation editing" : "Edit activation"}
              >
                {editingActivation ? "Cancel" : "Edit"}
              </button>
            </section>

            {editingActivation ? (
              <section className={styles.controlCard}>
                {side === 1 ? (
                  <Stepper label="Activation weight" value={weightDraft} unit="lb" step={5} minimum={0} onChange={setWeightDraft} />
                ) : (
                  <div className={styles.sharedWeight}>
                    <span>WEIGHT · SHARED</span>
                    <strong>{progress.weight} lb</strong>
                  </div>
                )}
                <Stepper label="Activation reps" value={activationDraft} step={1} minimum={1} onChange={setActivationDraft} />
                <button type="button" className={styles.inlineSave} onClick={logActivation}>Save Activation</button>
              </section>
            ) : null}

            <section className={styles.timerCard} aria-live="polite">
              <div>
                <span>MICRO-REST</span>
                <strong>0:{String(rest).padStart(2, "0")}</strong>
              </div>
              <div className={styles.timerTrack} aria-hidden="true">
                <span style={{ width: `${(rest / microRest) * 100}%` }} />
              </div>
              <button type="button" onClick={() => setRest(0)}>Skip Rest</button>
            </section>

            <section className={styles.miniHistory}>
              <div className={styles.sectionHeading}>
                <div>
                  <span>MINI-SETS</span>
                  <strong>{current.minis.length} of 4 planned</strong>
                </div>
                <span>Side {side}</span>
              </div>
              <div className={styles.miniPills}>
                {current.minis.map((reps, index) => (
                  <button
                    type="button"
                    className={editingMini === index ? styles.miniPillActive : styles.miniPill}
                    onClick={() => beginMiniEdit(index)}
                    aria-label={`Edit mini-set ${index + 1}, ${reps} reps`}
                    key={`${index}-${reps}`}
                  >
                    <span>{index + 1}</span>
                    <strong>{reps}</strong>
                    <small>reps</small>
                  </button>
                ))}
                {Array.from({ length: Math.max(0, 4 - current.minis.length) }).map((_, index) => (
                  <span className={styles.miniGhost} key={`ghost-${index}`}>{current.minis.length + index + 1}</span>
                ))}
              </div>
            </section>

            <section className={styles.controlCard}>
              <Stepper
                label={editingMini === null ? `Mini-set ${current.minis.length + 1} reps` : `Edit mini-set ${editingMini + 1}`}
                value={miniDraft}
                step={1}
                minimum={1}
                onChange={setMiniDraft}
              />
              {editingMini !== null ? (
                <button type="button" className={styles.removeMini} onClick={removeEditingMini}>Remove Mini-set</button>
              ) : null}
            </section>

            <button type="button" className={styles.heroAction} onClick={logMini}>
              <span aria-hidden="true">＋</span> {editingMini === null ? `Log ${miniDraft} Reps` : "Save Mini-set"}
            </button>
          </>
        )}
      </section>

      {current.activationReps !== null ? (
        <footer className={styles.runnerFooter}>
          {side === 1 ? (
            <button type="button" className={styles.secondaryAction} onClick={() => setSide(2)}>
              Continue to Side 2 <span aria-hidden="true">→</span>
            </button>
          ) : (
            <button type="button" className={styles.finishSet} disabled={!finishEnabled} onClick={onFinish}>
              <span aria-hidden="true">✓</span> Finish Myo-rep Set
            </button>
          )}
        </footer>
      ) : null}
    </main>
  );
}

function Editor({
  draft,
  setDraft,
  onCancel,
  onSave,
}: {
  draft: MyoProgress;
  setDraft: (progress: MyoProgress) => void;
  onCancel: () => void;
  onSave: () => void;
}) {
  const updateSide = (side: Side, next: SideProgress) => {
    setDraft(side === 1 ? { ...draft, side1: next } : { ...draft, side2: next });
  };

  const updateMini = (side: Side, index: number, delta: number) => {
    const current = side === 1 ? draft.side1 : draft.side2;
    const minis = current.minis.map((value, candidate) => candidate === index ? Math.max(1, value + delta) : value);
    updateSide(side, { ...current, minis });
  };

  const removeMini = (side: Side, index: number) => {
    const current = side === 1 ? draft.side1 : draft.side2;
    updateSide(side, { ...current, minis: current.minis.filter((_, candidate) => candidate !== index) });
  };

  const addMini = (side: Side) => {
    const current = side === 1 ? draft.side1 : draft.side2;
    updateSide(side, { ...current, minis: [...current.minis, current.minis.at(-1) ?? 3] });
  };

  return (
    <main className={styles.editorScreen}>
      <header className={styles.runnerTopbar}>
        <button type="button" className={styles.textButton} onClick={onCancel}>Cancel</button>
        <div>
          <strong>Edit Myo-rep Set</strong>
          <span>Atlantis Bicep Isolator</span>
        </div>
        <span className={styles.setBadge}>DONE ✓</span>
      </header>

      <section className={styles.editorBody}>
        <div className={styles.editorWeight}>
          <Stepper label="Activation weight · shared" value={draft.weight} unit="lb" step={5} minimum={0} onChange={(weight) => setDraft({ ...draft, weight })} />
        </div>

        {([1, 2] as const).map((side) => {
          const current = side === 1 ? draft.side1 : draft.side2;
          return (
            <section className={styles.editorSide} key={side}>
              <div className={styles.editorSideHeader}>
                <span>SIDE {side}</span>
                <strong>{(current.activationReps ?? 0) + current.minis.reduce((sum, value) => sum + value, 0)} total reps</strong>
              </div>
              <Stepper
                label="Activation reps"
                value={current.activationReps ?? 1}
                step={1}
                minimum={1}
                onChange={(activationReps) => updateSide(side, { ...current, activationReps })}
              />
              <div className={styles.editorMiniList}>
                {current.minis.map((reps, index) => (
                  <div className={styles.editorMiniRow} key={`${side}-${index}`}>
                    <span>Mini-set {index + 1}</span>
                    <div>
                      <button type="button" aria-label={`Decrease side ${side} mini-set ${index + 1}`} onClick={() => updateMini(side, index, -1)}>−</button>
                      <strong>{reps}</strong>
                      <button type="button" aria-label={`Increase side ${side} mini-set ${index + 1}`} onClick={() => updateMini(side, index, 1)}>＋</button>
                      <button type="button" className={styles.trashButton} aria-label={`Remove side ${side} mini-set ${index + 1}`} onClick={() => removeMini(side, index)}>⌫</button>
                    </div>
                  </div>
                ))}
              </div>
              <button type="button" className={styles.addMini} onClick={() => addMini(side)}>＋ Add Mini-set</button>
            </section>
          );
        })}
      </section>

      <footer className={styles.runnerFooter}>
        <button type="button" className={styles.finishSet} onClick={onSave}>Save Changes</button>
      </footer>
    </main>
  );
}

export default function MyoRepsPreview() {
  const [screen, setScreen] = useState<Screen>("workout");
  const [progress, setProgress] = useState<MyoProgress>(initialProgress);
  const [completed, setCompleted] = useState(false);
  const [side, setSide] = useState<Side>(1);
  const [rest, setRest] = useState(0);
  const [microRest, setMicroRest] = useState(15);
  const [editDraft, setEditDraft] = useState<MyoProgress>(initialProgress);

  const timerRunning = screen === "runner" && rest > 0;
  useEffect(() => {
    if (!timerRunning) return;
    const timer = window.setInterval(() => setRest((seconds) => Math.max(0, seconds - 1)), 1000);
    return () => window.clearInterval(timer);
  }, [timerRunning]);

  const reset = () => {
    setProgress(initialProgress());
    setEditDraft(initialProgress());
    setCompleted(false);
    setSide(1);
    setRest(0);
    setMicroRest(15);
    setScreen("workout");
  };

  const startRunner = () => {
    setSide(
      progress.side1.activationReps === null
        ? 1
        : progress.side2.activationReps === null
          ? 2
          : side,
    );
    setScreen("runner");
  };

  const finish = () => {
    setCompleted(true);
    setRest(0);
    setScreen("workout");
  };

  const openEditor = () => {
    setEditDraft(cloneProgress(progress));
    setScreen("editor");
  };

  return (
    <div className={styles.previewShell}>
      <div className={styles.reviewBar}>
        <div>
          <span>FORGEFIT · INTERACTION MOCKUP</span>
          <strong>Dedicated Myo-rep set</strong>
        </div>
        <button type="button" onClick={reset}>Reset</button>
      </div>

      <div className={styles.phone}>
        <div className={styles.statusBar} aria-hidden="true"><strong>9:41</strong><span>●●● ㇓ ▰</span></div>
        {screen === "workout" ? (
          <WorkoutCard
            progress={progress}
            completed={completed}
            microRest={microRest}
            onStart={startRunner}
            onEdit={openEditor}
          />
        ) : screen === "runner" ? (
          <Runner
            progress={progress}
            setProgress={setProgress}
            side={side}
            setSide={setSide}
            rest={rest}
            setRest={setRest}
            microRest={microRest}
            setMicroRest={setMicroRest}
            onClose={() => setScreen("workout")}
            onFinish={finish}
          />
        ) : (
          <Editor
            draft={editDraft}
            setDraft={setEditDraft}
            onCancel={() => setScreen("workout")}
            onSave={() => {
              setProgress(cloneProgress(editDraft));
              setScreen("workout");
            }}
          />
        )}
        <div className={styles.homeIndicator} aria-hidden="true" />
      </div>
    </div>
  );
}
