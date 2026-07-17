# Yoga Pose Illustration Generation Kit

> **Current status:** The catalog ships **16 poses** that have finished color
> illustrations (licensed "026 Yoga Pose" set), wired as `yoga_pose_<slug>`
> assets. The pose catalog, built-in flows, and picker are trimmed to exactly
> these 16 so users never see a pose without real art. To grow the catalog,
> add artwork for any pose below and re-add its entry to
> `ForgeFit/Resources/yoga_poses.json` (plus a `yoga_pose_figures.json` fallback
> figure) — the pose then reappears everywhere automatically.
>
> **Illustrated (live):** pigeon, butterfly, low lunge, high lunge, tree, cobra,
> downward-facing dog, warrior II, camel, bow, boat, dancer, upward-facing dog,
> hero, child's pose, extended side angle.
>
> **Not yet illustrated** (in the prompt table below, available to add): the
> remaining ~35 poses — mountain, warrior I, triangle, half moon, bridge,
> seated folds, twists, and the rest.

The app resolves pose art in this order, so generated images drop in with **zero code changes**:

1. `yoga_pose_<slug>` asset — full-color image, rendered as-is
2. `yoga_<slug>` asset — **template** (tinted to the theme accent automatically)
3. Built-in drawn stick figure (`yoga_pose_figures.json`)
4. SF Symbol (custom user poses only)

## Recommended: black line art as template assets

Generate **black single-weight line art on a transparent background** and bundle under the
`yoga_<slug>` template names. Why:

- Line art is the most *style-consistent* thing image models produce across 51 generations.
- Template rendering means the app tints it to the theme accent — perfect in dark and light
  mode, and it matches the app's existing iconography instead of fighting it.
- Transparent output: ChatGPT (gpt-image-1) supports "transparent background" directly;
  Midjourney users should generate on plain white and ask me to knock the background out.

**Per-image settings:** PNG, 1024×1024, transparent background, figure centered filling
~85% of the frame, no text, no watermark, no mat/props unless the prompt says so.

**Consistency tips:** generate all 51 in one session with the identical style block below;
in ChatGPT, after the first image you like, say "same character, same style" for the rest.
In Midjourney, pick your favorite first result and reuse it as `--sref` for all others.

## Critical orientation rule

For one-sided poses the app mirrors the image for the right side, so **the leading/bent
leg must be on the LEFT side of the image** in every side-view pose. This is baked into
the per-pose prompts below — don't flip them.

## Shared style block (prepend to every prompt)

> Minimalist black ink line illustration for a yoga instruction app: a single person with
> a simple, softly stylized body (no facial features, short tied-back hair), drawn in
> clean confident single-weight lines with no shading, no color fill, no background.
> Anatomically correct and instructionally clear. Centered, transparent background,
> no text.

## Per-pose prompts

Asset name → append this description to the shared style block.

| Asset name | Pose | Prompt continuation |
|---|---|---|
| `yoga_mountain_pose` | Mountain Pose (Tadasana) | Standing tall facing the viewer, feet together, arms relaxed at the sides with palms facing forward, spine long. |
| `yoga_upward_salute` | Upward Salute (Urdhva Hastasana) | Standing tall facing the viewer, arms sweeping straight overhead in a wide V, palms facing each other, gaze slightly up. |
| `yoga_standing_forward_fold` | Standing Forward Fold (Uttanasana) | Side view facing left: standing with legs straight, torso folded completely over the legs, head hanging down, fingertips reaching toward the floor. |
| `yoga_halfway_lift` | Halfway Lift (Ardha Uttanasana) | Side view facing left: legs straight, torso lifted parallel to the floor with a flat back, fingertips on the shins, neck long. |
| `yoga_chair_pose` | Chair Pose (Utkatasana) | Side view facing left: knees deeply bent as if sitting in an invisible chair, hips back, torso leaning slightly forward, arms straight overhead alongside the ears. |
| `yoga_downward_facing_dog` | Downward-Facing Dog (Adho Mukha Svanasana) | Side view: body in an inverted V, hands planted on the floor at the left, hips high, legs straight with heels reaching toward the floor at the right, head relaxed between the arms. |
| `yoga_plank_pose` | Plank Pose (Phalakasana) | Side view: body in one straight line from head at the left to heels at the right, arms straight and vertical under the shoulders, toes tucked. |
| `yoga_low_lunge` | Low Lunge (Anjaneyasana) | Side view: left leg lunging forward with foot flat and knee over ankle, right knee resting on the floor with shin extended back, torso upright, arms reaching straight overhead. |
| `yoga_high_lunge` | High Lunge (Utthita Ashwa Sanchalanasana) | Side view: left leg lunging forward with knee bent over the ankle, right leg extended straight back on the ball of the foot with heel lifted, torso upright, arms overhead. |
| `yoga_warrior_i` | Warrior I (Virabhadrasana I) | Side view: left leg lunging forward with knee bent, right leg straight back with the foot flat and angled, hips squared forward, arms reaching straight up overhead. |
| `yoga_warrior_ii` | Warrior II (Virabhadrasana II) | Side view: left knee bent in a wide lunge to the left, right leg straight to the right with foot flat, torso upright between the legs, arms extended in a T at shoulder height, gaze over the left hand. |
| `yoga_reverse_warrior` | Reverse Warrior (Viparita Virabhadrasana) | Side view: left knee bent in a wide lunge, right leg straight, torso leaning back toward the right, left arm sweeping up and overhead, right hand resting lightly on the right thigh. |
| `yoga_extended_side_angle` | Extended Side Angle (Utthita Parsvakonasana) | Side view: left knee bent in a wide lunge, right leg straight, torso tilted left over the front thigh, left forearm or hand reaching down inside the left foot, right arm extended in a straight diagonal line over the ear. |
| `yoga_triangle_pose` | Triangle Pose (Trikonasana) | Side view: both legs straight in a wide stance, torso hinged sideways to the left, left hand on the left shin, right arm reaching straight up, forming a triangle. |
| `yoga_pyramid_pose` | Pyramid Pose (Parsvottanasana) | Side view: both legs straight, left foot forward, right foot back, torso folded deeply over the front leg, hands framing the front foot. |
| `yoga_tree_pose` | Tree Pose (Vrksasana) | Facing the viewer: balancing on the right leg, left foot pressed to the inner right thigh with the knee opening out, palms pressed together overhead. |
| `yoga_eagle_pose` | Eagle Pose (Garudasana) | Facing the viewer: standing on a softly bent right leg, left leg wrapped over and around the right, arms wrapped and entwined in front of the chest with forearms lifted. |
| `yoga_dancer_pose` | Dancer Pose (Natarajasana) | Side view facing left: balancing on the left leg, right leg lifted behind and up with the right hand holding the inner foot, left arm reaching forward, chest lifted in a gentle backbend. |
| `yoga_standing_figure_four` | Standing Figure Four | Side view facing left: balancing on a softly bent right leg, left ankle crossed over the right knee making a figure four, hips sitting back, arms reaching forward for balance. |
| `yoga_wide_legged_forward_fold` | Wide-Legged Forward Fold (Prasarita Padottanasana) | Facing the viewer: feet very wide apart, legs straight, torso folded down through the center, crown of the head toward the floor, hands flat on the floor between the feet. |
| `yoga_goddess_pose` | Goddess Pose (Utkata Konasana) | Facing the viewer: wide stance with toes turned out, knees deeply bent in a squat, torso upright, arms in a cactus shape with elbows at shoulder height and forearms up. |
| `yoga_half_moon_pose` | Half Moon Pose (Ardha Chandrasana) | Side view: balancing on the straight left leg with the left fingertips on the floor, right leg extended straight back parallel to the floor, torso horizontal, right arm reaching straight up. |
| `yoga_cat_pose` | Cat Pose (Marjaryasana) | Side view: on all fours with hands under shoulders and knees under hips, spine rounded strongly upward, head dropped down. |
| `yoga_cow_pose` | Cow Pose (Bitilasana) | Side view: on all fours with hands under shoulders and knees under hips, belly dropping so the spine sways down, chest and gaze lifted. |
| `yoga_thread_the_needle` | Thread the Needle (Parsva Balasana) | Side view: kneeling with hips high over the knees, left arm threaded under the body along the floor with the left shoulder and ear resting down, right arm extended forward. |
| `yoga_puppy_pose` | Puppy Pose (Uttana Shishosana) | Side view: kneeling with hips high directly over the knees, arms stretched far forward on the floor, chest melting down, forehead resting on the mat. |
| `yoga_cobra_pose` | Cobra Pose (Bhujangasana) | Side view facing left: lying prone with legs and hips on the floor, chest curling up, elbows softly bent, hands under the shoulders. |
| `yoga_upward_facing_dog` | Upward-Facing Dog (Urdhva Mukha Svanasana) | Side view facing left: arms straight and vertical, chest lifted tall, hips and thighs off the floor, only the palms and tops of the feet touching down. |
| `yoga_sphinx_pose` | Sphinx Pose (Salamba Bhujangasana) | Side view facing left: lying prone, gentle chest lift supported on the forearms which rest flat on the floor, elbows under the shoulders, legs extended back. |
| `yoga_locust_pose` | Locust Pose (Salabhasana) | Side view facing left: lying prone with the chest and both straight legs lifted off the floor simultaneously, arms sweeping back alongside the body with palms down. |
| `yoga_bow_pose` | Bow Pose (Dhanurasana) | Side view facing left: lying prone, knees bent with feet lifted toward the ceiling, hands reaching back to hold the ankles so the body curves like a bow. |
| `yoga_childs_pose` | Child's Pose (Balasana) | Side view facing left: kneeling and folded forward with hips resting on the heels, chest on the thighs, forehead on the floor, arms extended forward on the mat. |
| `yoga_seated_forward_fold` | Seated Forward Fold (Paschimottanasana) | Side view facing left: seated with both legs extended straight forward, torso folding over the legs, hands reaching toward flexed feet. |
| `yoga_head_to_knee_pose` | Head-to-Knee Pose (Janu Sirsasana) | Side view facing left: seated with the left leg extended straight, right knee bent out with the sole of the foot against the inner left thigh, torso folding over the straight leg. |
| `yoga_seated_twist` | Seated Twist (Ardha Matsyendrasana) | Three-quarter view: seated tall with the left leg extended, right knee bent and drawn up, torso twisting toward the bent knee, left arm hugging the knee, right fingertips on the floor behind. |
| `yoga_butterfly_pose` | Butterfly Pose (Baddha Konasana) | Facing the viewer: seated with the soles of the feet pressed together, knees opening wide to the sides, hands holding the feet, spine tall. |
| `yoga_pigeon_pose` | Pigeon Pose (Eka Pada Rajakapotasana) | Side view facing left: left shin folded on the floor in front of the hips, right leg extended straight back along the floor, torso upright, fingertips on the floor beside the hips. |
| `yoga_lizard_pose` | Lizard Pose (Utthan Pristhasana) | Side view: left foot planted forward outside the hands, right leg extended long behind with the knee down, both forearms resting on the floor inside the front foot, torso low. |
| `yoga_half_splits` | Half Splits (Ardha Hanumanasana) | Side view: right knee kneeling under the hip, left leg extended straight forward with heel on the floor and foot flexed, torso folding over the straight front leg, hands on the floor. |
| `yoga_happy_baby` | Happy Baby (Ananda Balasana) | Side view: lying on the back, knees drawn wide toward the armpits, feet flexed toward the ceiling, hands holding the outer edges of the feet. |
| `yoga_supine_twist` | Supine Twist (Supta Matsyendrasana) | Side view: lying on the back with both bent knees dropped together to the left touching the floor, shoulders flat, one arm extended along the floor, head turned away. |
| `yoga_bridge_pose` | Bridge Pose (Setu Bandhasana) | Side view facing left: lying on the back with knees bent and feet flat, hips lifted high so the body forms a ramp from knees to shoulders, arms flat along the floor. |
| `yoga_reclined_figure_four` | Reclined Figure Four (Supta Kapotasana) | Side view: lying on the back, right thigh drawn up vertical, left ankle crossed over the right knee with the left knee opening out, hands clasped behind the right thigh. |
| `yoga_legs_up_the_wall` | Legs Up the Wall (Viparita Karani) | Side view: lying on the back with the hips close to a wall on the left, both legs extended straight up resting against the wall, arms relaxed on the floor. |
| `yoga_boat_pose` | Boat Pose (Navasana) | Side view facing left: balancing on the sit bones, torso leaning back slightly, both straight legs lifted so the body forms a V, arms extended forward parallel to the floor. |
| `yoga_camel_pose` | Camel Pose (Ustrasana) | Side view: kneeling upright with the shins flat on the floor, hips pressing forward, spine arching back, hands reaching back to the heels, head dropping gently back. |
| `yoga_hero_pose` | Hero Pose (Virasana) | Side view facing left: kneeling and seated between the heels with the shins folded alongside the thighs, spine tall, hands resting on the thighs. |
| `yoga_corpse_pose` | Corpse Pose (Savasana) | Side view: lying flat on the back completely relaxed, legs extended with feet falling open, arms resting slightly away from the body with palms up. |
| `yoga_standing_side_bend` | Standing Side Bend (Parsva Urdhva Hastasana) | Facing the viewer: standing tall with feet together, both arms overhead, whole torso curving in a smooth arc to the left. |
| `yoga_melting_heart` | Melting Heart (Anahatasana) | Side view: kneeling with hips high directly over the knees, chest melted deeply toward the floor, chin or forehead down, arms stretched long overhead on the mat. |
| `yoga_dragon_pose` | Dragon Pose (Yin) | Side view: deep low lunge with the left foot far forward, right leg long behind with the knee resting down, torso low over the front thigh, both hands on the floor inside the front foot. |

## When the images are ready

Put the 51 PNGs in a folder named with the asset names above (e.g. `yoga_camel_pose.png`)
and tell Claude — importing them into `Assets.xcassets` as template imagesets and QA-ing
each pose against the catalog is scripted from there. Any pose that comes out wrong can be
regenerated individually; the drawn figure remains the fallback until its image lands.
