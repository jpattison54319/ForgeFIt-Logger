# Guided yoga content audit

Status: source-audited on 2026-08-09; independent yoga-teacher review still recommended before release.

Canonical product content: [`ForgeFit/Resources/yoga_guidance.json`](../ForgeFit/Resources/yoga_guidance.json)

## Safety and editorial contract

ForgeFit’s guided yoga is prerecorded general fitness guidance. It is not an individualized assessment, a substitute for an in-person teacher, or medical advice. A disclaimer is necessary, but it does not make an incorrect physical instruction acceptable. The content therefore follows these rules:

- Gemini never invents pose instructions. It narrates fixed transcripts at build time.
- Every bundled pose has a self-contained first entry line, optional setup refinements, alignment refinements, breath cues, an accessible option, a deliberate exit, actionable considerations, and review sources.
- Generated and newly edited flows enforce the measured time needed for pose name, first entry, and exit; a legacy hold below that contract prioritizes actionable setup and exit over repeating the on-screen pose name.
- A left or right runtime step names the working, front, standing, bent, or threaded side for that pose. Side placeholders are resolved into explicit words before display or narration.
- Cues use choice-based language where bodies legitimately differ. They do not require a textbook shape, maximum range, or pain tolerance.
- Sensation is never described as universally safe or beneficial. Sharp pain, numbness, tingling, dizziness, unusual shortness of breath, and feeling unwell are stop signals.
- The content avoids unsupported therapeutic, detoxification, fascia, hormone, blood-pressure, and nervous-system promises.
- Props and smaller ranges are normal forms of the pose, not remedial failures.
- Pregnancy, injury, osteoporosis, eye conditions, blood-pressure concerns, and other health circumstances are routed to an appropriately qualified teacher or clinician rather than handled by blanket app-level rules.

The review used pose-specific instruction and modification pages from Yoga Journal and Yoga International, the [NCCIH yoga safety overview](https://www.nccih.nih.gov/health/yoga-effectiveness-and-safety), and the [Yoga Alliance scope of practice](https://yogaalliance.org/policies-priorities-progress/scope-of-practice/). Sources are retained beside each pose in the JSON so a future wording change can be reviewed as a content diff. These sources reduce risk; they do not constitute independent certification of ForgeFit’s final script.

## Problems removed from the legacy scripts

The prior two-line scripts were useful placeholders but not safe enough for a polished guided class. The reviewed layer fixes several concrete problems:

- Unilateral poses no longer say “one foot,” “one arm,” or only “same pose, other side.” Left and right transcripts are complete.
- Entries no longer assume a particular previous pose, such as “from Warrior Two” or “from a wide stance.”
- Pigeon no longer tells everyone to lay the shin across the mat. It begins with a comfortable diagonal, requires pelvic support, treats any front-knee or sacroiliac pain as an exit signal, and offers reclined figure four.
- “Square your hips,” “pressed between two panes of glass,” “rotate farther,” “sink deeper,” and similar one-shape-fits-all commands were replaced with functional, range-aware language.
- Standing-forward-fold weight is centered through the foot rather than shifted toward the toes.
- Bridge explicitly keeps the head centered while the pelvis is lifted.
- Backbends prioritize length, active support, neutral neck options, and unforced breathing rather than height.
- Considerations are actionable sentences. The old terse lists of conditions looked authoritative without explaining what to change or when to seek individual advice.

## Pose-by-pose audit

| Pose | Main instruction risk reviewed | Resolution in the canonical script |
|---|---|---|
| Downward-Facing Dog | Heel-to-floor goals, wrist loading, inversion context | Bent knees and spinal length come first; hands-at-wall/blocks option; neck stays easy; clinician/teacher routing for relevant eye or uncontrolled blood-pressure concerns. |
| Low Lunge | Ambiguous side, knee compression, forced square hips | Working foot and back knee are explicit; padding/blocks/short stance; knee tracks toes; pelvis need not be perfectly square. |
| High Lunge | Narrow balance base, knee drift, overlong stance | Side-to-side foot width, front-knee tracking, back-knee softness, wall/chair and knee-down options. |
| Warrior II | Mandatory ninety-degree knee and inward collapse | Bend is individual; knee centers over the ankle and follows toes; chair and shallower versions are normal. |
| Extended Side Angle Pose | Depends on Warrior II; weight dumped into knee; forced chest rotation | Fully self-contained setup; forearm stays light; back foot participates; chest and gaze rotate only comfortably. |
| Tree | Foot placed on knee; fall risk | Foot goes to floor, ankle, calf, or thigh, never the knee joint; wall and kickstand versions lead the options. |
| Dancer | Ambiguous standing side; forced shoulder grip/backbend | Standing and lifted sides are named; wall/strap/upright quad stretch options; lift comes with length and unforced breathing. |
| Cobra | Arm-driven height and lumbar compression | Low back-muscle-led lift, light hands, grounded pelvis/feet, long neck, and baby-cobra option. |
| Upward-Facing Dog | Commonly confused with cobra; inactive legs and lumbar sinking | Hands beside lower ribs, hands and feet bear weight, thighs lift only in the full pose, legs stay active, chest reaches forward/up; cobra is explicit fallback. |
| Bow | Uneven ankle reach, knees splaying, breath holding | Both ankles or strap are taken together, knees stay about hip-width, legs press back, and the pose lowers for breath holding or back pinching. |
| Child’s Pose | Assumed to be restful for everyone; unsupported head/knees | Knee width is chosen, forehead/torso are supported, and side/back alternatives are offered. |
| Butterfly / Bound Angle | Knees pushed toward floor; rounded forced fold | Knees open under their own weight, thighs can be supported, the seat can be raised, and any fold hinges without pulling. |
| Pigeon | Parallel-shin demand and front-knee/SI risk | Comfortable diagonal shin, supported outer hip, no knee sensation, no forced fold, reclined figure-four alternative, careful table exit. |
| Boat | “Do not round” without a usable regression; breath bracing | Feet-down and thigh-hold versions are first-class; chest/spine remain long only within a steady breathing range. |
| Camel | Dropped head, hips thrust forward, lumbar collapse | Hands stay on pelvis unless support remains; upper-back lift leads; thighs remain near vertical; head can stay neutral; chest leads the exit. |
| Hero | Sitting to the floor despite knee/ankle restriction | Seat height is mandatory as needed; weight stays on support rather than feet; pain/numbness/tingling end the pose. |
| Mountain | Feet together and locked knees treated as universal | Feet may be hip-width; knees stay responsive; wall/chair support and lightheadedness guidance are explicit. |
| Cat–Cow | Movement initiated by throwing the head; wrist/knee assumptions | Breath guides a pain-free spinal wave, neck remains part of the curve, and fists/forearms/chair options reduce joint load. |
| Thread the Needle | Unnamed arm and forced shoulder/neck twist | Threaded and supporting sides are named; head/shoulder can be padded; numbness/tingling are exit signals. |
| Standing Forward Fold | Straight-leg toe touching; weight shifted too far forward; rolling up | Knees bend and torso approaches thighs; support can raise the floor; weight stays centered; exit uses bent knees, hands to hips, and a long spine. |
| Seated Forward Fold | Pulling on feet and forcing spinal flexion | Pelvis can be elevated, knees bend, a strap/bolster can support, and the fold stops before pulling or sharp sensation. |
| Wide-Legged Forward Fold | Locked knees, unsupported head, fast rise | Knees stay responsive, hands/head may be supported, weight spans the whole foot, and the long-spine exit is slow. |
| Triangle | “Two panes of glass,” locked knees, hand pressure on knee | Torso length replaces geometric stacking; chest/gaze have choices; lower hand avoids the knee; shorter stance/wall/chair options. |
| Happy Baby | Pulling feet down while sacrum/shoulders lift | Multiple grips are offered; sacrum, head, and shoulders stay supported; wall and one-leg options reduce load. |
| Bridge | Knee splay, flattened neck, head turning | Feet and knees track, natural neck curve is respected, head stays centered, and supported bridge uses a block beneath the sacrum. |
| Seated Spinal Twist | Arm-forced depth and automatic neck rotation | Spine length precedes rotation; ribs turn without leverage; head follows last; chair and long-bottom-leg options reduce joint demand. |
| Supine Twist | Shoulder and knee forced to floor | Pelvis may roll, crossed knee is supported, shoulder need not be pinned, and the head can stay neutral. |
| Plank | Wrist-dominant loading, sagging low back, breath holding | Whole-hand pressure, broad upper back, supported ribs/pelvis, knees-down and wall/chair inclines, breath as the stop gauge. |
| Legs-Up-the-Wall | Hips required against wall; abrupt exit; inversion generalized as safe | Any comfortable wall distance, calves-on-chair option, relaxed legs, side-roll pause, and individual guidance for relevant inversion concerns. |
| Savasana | One mandatory flat symmetrical position; abrupt return | Head/knee support, side-lying/elevated/chair options, natural breath, gradual movement, side roll, and reorientation before standing. |

## Guided-class language and filler research

The modular library reflects the major domains in the [Yoga Alliance RYS credential standards](https://yogaalliance.org/Standards-for-RYS-Credentials)—asana, breath, meditation, anatomy/physiology, yoga humanities, and teaching methodology—without pretending a recording can observe the practitioner. Its physical, body-awareness, and spiritual cue categories were also cross-checked against the class-language dimensions described in a [controlled study of yoga verbal cueing](https://pmc.ncbi.nlm.nih.gov/articles/PMC7351526/). Choice and agency follow the invitational-language and choice-making principles taught by the [Center for Trauma and Embodiment](https://www.traumasensitiveyoga.com/certification).

The library therefore includes:

- foundation and entry cues before refinement;
- one physical action per concise line;
- breathing awareness without required breath retention or a pace the user must match;
- options and permission to leave the pose;
- sensory scans, contact points, gaze, effort-versus-ease, and moments of silence;
- non-sectarian introductions to ahimsa, santosha, aparigraha, prana, drishti, intention, gratitude, and witness awareness;
- encouragement that values steadiness, support, and consistency over intensity;
- closings that orient attention back to the user’s present experience.

Silence is part of the plan, not an empty interval to eliminate. The balanced planner prioritizes setup and exit, then alignment, breath, and an option. It considers reflective or spiritual material only when the hold is long enough, spaces it more widely in gentle, yin, and restorative styles, and excludes variable clips selected elsewhere in the current class or the last five completed classes.

## Remaining review and validation boundaries

- The scripts are source-audited but have not been independently signed off by a registered, experienced yoga teacher. That review should include practicing every cue on both sides and inside representative built-in flows.
- A static app cannot see joint position, equipment stability, fatigue, pain behavior, balance hazards, or whether a condition makes a pose inappropriate.
- Audio QA can confirm the file, transcript mapping, duration, signal, and manifest. It cannot prove that tone, pronunciation, pacing, or a transition feels natural; those require human listening.
- Simulator success does not verify speaker/AirPods routing, lock-screen background playback, music ducking, interruption recovery, or haptics. Those remain physical-device release checks.
