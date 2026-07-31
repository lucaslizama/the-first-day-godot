# Level port scope — `nivelEscena.unity`

Recon of the Unity level, to size the remaining work. Every number here was read
out of the project, not estimated. Source: `../the-first-day-unity`.

## What the level actually is

A **large vertical structure**, measured from the imported geometry in Godot:

| | |
|---|---|
| `nivel.fbx` | 125.7 × 57.6 × 186.2 m |
| `nivel_p2.fbx` | 51.0 × 40.5 × 77.2 m |
| Assembled shell | 125.7 × 57.6 × **262.1 m**, z from −186.2 to +75.9 |
| Import scale | `root_scale = 100` (Unity `globalScale: 100`) |

Corroborated against Unity: the `CheckPointZone` kill volume is scaled
152 × 1 × 321, the checkpoints sit at y = 9.55 / 21.36, and a `plataforma`
BoxCollider is 1.96 × 0.41 × 2.03 m. The player starts at (0, 0, 4.02) and the
last Trigger Zone is at (−0.02, 11.97, −101.14), so play runs **downward in z
and upward in y** — which is what the falling platforms are for.

> **Correction.** An earlier revision of this document claimed a
> "8.7 × 3.2 × 71.1 m corridor". That was wrong twice over: it sampled only the
> 11 *root* transforms while 132 prefab instances are nested under containers,
> and it merged mesh-local AABBs computed in `_initialize()`, where
> `global_transform` returns identity and every mesh's own placement is
> discarded. Measure bounds after the tree is live, or the numbers are
> meaningless.

The level can still be ported in **slices along z**, one checkpoint stretch at a
time, with the sandbox scene as the harness — that part holds. Nothing requires
the whole level standing up before any of it is playable.

### Unity → Godot placement convention

> **Correction.** This section said positions transfer **unchanged**. That is true
> for Y and Z and **false for X**, and the error put every prop, coworker, platform
> and zone in the wrong place — mirrored relative to the shell, which is why doors
> sat inside walls and coworkers hung over holes. The claim that "Godot's importer
> and Unity's agree numerically on these files" was the mistake: they agree on Y
> and Z and disagree on X. Only Z had actually been measured.

Positions transfer **conjugated by `M = diag(-1, 1, 1)`**: X negates, Y and Z do
not. Rotation quaternions go `(x, y, z, w) → (x, −y, −z, w)`, which is `M R M`.
Scales and box sizes are untouched, since `M S M = S` for diagonal `S`, so props
keep the handedness Unity gave them and mirrored props stay mirrored.

Applied in exactly one place, `tools/unity_space.py`, called by all three
extractors, so no generator carries mirror logic of its own. Do not apply it
twice. `tools/generate_table_pcs_scene.py` is the exception and conjugates its own
numbers, because those are prefab-local and never pass through the extractors.

**Z is unchanged, and that part was measured correctly.** The last Trigger Zone is
at Unity z = −101.14 and must lie inside the level; Godot's imported `nivel` spans
z ∈ [−110.4, +75.9]. Unchanged puts it inside, negated puts it outside the
geometry altogether. `tools/check_mirror.gd` re-tests this against independent
evidence and agrees: negating Z makes everything much worse.

**Why X is different, and how it was caught.** Two independent proofs:

- **Local, exact.** `tablePcs` flattens `table.fbx` into its prefab root, so Unity
  stores the table's five planes as plain children. Their positions are Godot's
  imported positions with X negated, to five decimals on all five, Z identical
  throughout. `book.fbx`'s two children agree the same way.
- **Global, statistical.** `tools/check_mirror.gd` probes all 173 placed nodes in
  the built level for a surface beneath them and for contact with geometry, under
  all four axis conventions. The models were already mirrored by the importer while
  the placements were not, so the two disagreed:

  | convention | <0.1 m | <0.5 m | <2 m | <10 m | nothing | contact |
  |---|---|---|---|---|---|---|
  | as placed (before) | 13 | 1 | 7 | 34 | **118** | 21 |
  | −x | 19 | 21 | 13 | 64 | **56** | 67 |
  | −z | 1 | 0 | 5 | 33 | 134 | 5 |
  | −x −z | 1 | 3 | 2 | 31 | 136 | 10 |

Two pre-existing tools corroborate the fix independently. `verify_coworkers.gd`
went from 64 of 74 coworkers with nothing beneath them to **24**, and
`verify_level_placement.gd` went from 2 of 3 landmarks supported to **3 of 3**.

Since Godot's handedness differs from Unity's, a consistently conjugated scene
renders the way Unity's did — the fix is not "the level is mirrored now", it is
"the level and its models finally agree".

**Rotations are the exception.** A Unity directional light shines along +Z while
Godot's shines along −Z, so its basis needs its X and Z columns negated — a 180°
turn about Y that keeps the determinant positive. This is the same correction
Fortunato's model needed (`rotation.y = π`). Taking Unity's quaternion at face
value points the sun *upward*.

### Two authoring scale groups

The models split in two, and mixing them up produces geometry off by 100×:

- **`globalScale: 1`** — `book`, `cable`, `cake`, `interruptor`, `meta`, `pc`,
  `pc2`, `puerta`, `puertaInicio`, `silla`, `table`. Already metre-scale: the
  chair measures 1.33 m tall, the table 0.95 m.
- **`globalScale: 100`** — `nivel`, `nivel_p2`, `plataforma`, `plataformaCae`,
  `martillo`, `piezaParede`.

## Scene inventory

`nivelEscena.unity` is 17,756 lines / 632 KB.

| Unity type | Count |
|---|---|
| Transform | 189 |
| **Prefab instance** | **132** (30 distinct prefabs) |
| GameObject | 129 |
| MonoBehaviour | 90 |
| MeshCollider | 60 |
| Animator | 33 |
| SpriteRenderer | 31 |
| AudioSource | 14 |
| MeshFilter / MeshRenderer | 9 / 9 |
| BoxCollider | 2 |
| Light | 2 |
| ParticleSystem | 1 — **done**, `scenes/confetti.tscn` |
| Camera / AudioListener | 1 / 1 |

Only 9 MeshRenderers sit directly in the scene — effectively all geometry
arrives through prefab instances.

### Prefab instances

| Count | Prefab | Role |
|---|---|---|
| 24 | `Models/silla.fbx` | chairs |
| 21 | `Models/puerta.fbx` | doors |
| 18 | `plataforma_prefab` | platforms |
| 13 | `Mono 1/mono1` | coworker (sprite) |
| 8 | `plataformaCae` | falling platforms |
| 5 | `coworkers_group2` | coworker cluster |
| 5 | `Mono 2/mono2_prefab` | coworker (sprite) |
| 5 | `martillo_prefab` | hammers (hazard) |
| 5 | `Models/table.fbx` | tables |
| 4 | `tablePcs` | desk + PCs |
| 2 each | `Models/pc.fbx`, `Models/pc2.fbx`, `Trigger Zone`, `coworkers_group 1` | |
| 1 each | `nivel.fbx`, `nivel_p2.fbx`, `meta.fbx`, `cake.fbx`, `cable.fbx`, `interruptor.fbx`, `piezaParede.fbx`, `Fortunato`, `Yelena`, `UI`, `InputManager`, `CheckPointZone`, `Timer Zone`, `puertaInicio`, `coworkers_group3`, `particleSys_conffeti` | |

`tablePcs` is not one model but four on one node — a `table`, a `pc`, a `pc2` and a
`book`, 11 meshes in all — with the table flattened into the prefab root as
`pPlane23`–`pPlane27`. Counting it as a single prop is what let the static-props
pass skip it.

`nivel.fbx` + `nivel_p2.fbx` are the level shell. `Yelena` is the **disabled**
leftover prototype — do not port it. Its `m_IsActive: 0` is a prefab-instance
override rather than a field on a GameObject document, so it is invisible to a
naive scan of the scene; confirmed against prefab guid `65a06b95…`.

### Assets

| Kind | Count | Weight |
|---|---|---|
| Level FBX models | 13 | **936 KB total** |
| Coworker sprite frames | 153 (mono1) + 70 (mono2) | **19 MB** → 175 KB packed, only the 81 + 70 the clips use |
| Coworker anim clips / controllers | 2 / 2 | |
| Audio (WAV) referenced by this scene | 3 | **22.8 MB** |
| Materials | 12 | |
| AudioMixer | 1 | |

The geometry is *tiny* — under 1 MB for the whole level, versus the 67 MB of
Fortunato animation FBX we already declined to vendor. The heavy assets are
sprites and audio.

Audio referenced by the level scene:

- `susurro_loko.wav` — 2.4 MB, referenced 12×, the whisper driven by `SoundAttenuationByDeath`
- `guille_experimental.wav` — 11.8 MB
- `robinhood76__looping-hollow-open-air-wind.wav` — 8.6 MB

Two more WAVs exist in the project but are **not** referenced by this scene:

- `step.wav` (6 KB) — referenced by `Fortunato.prefab`, i.e. the footstep sound
  the missing `PlayStepSound` animation event triggered. Needed, but it arrives
  with the character, not the level.
- `susurro_ambience.wav` (4.3 MB) — referenced by **nothing** anywhere in the
  project. Orphaned; do not port it without asking.

### Lighting

Two lights only, plus flat ambient:

- Directional, warm `(1, 0.9569, 0.8392)`, intensity 1
- Point, cool `(0.7509, 0.7719, 0.9118)`, intensity 2.39
- Ambient: **Flat** mode, `(0.2235, 0.2353, 0.2235)`, intensity 1

This is already encoded in `shaders/character_lit.gdshader`'s `ambient_color`
default, so the character and the level will agree by construction.

Both lights are ported, the ambient matches, and the skybox is ported too, so the
level's lighting and its backdrop are faithful.

#### The skybox was an ending-area problem, not a detail — **done**

`scenes/level.tscn` used to set `background_mode = 1`, a flat near-black colour,
because `mat_skyboxFernandito` was unported. Inside the office that is invisible:
walls and ceilings fill the frame, so nothing ever shows sky.

The far end of the level is **exterior**. Past roughly z = −152 the geometry opens
into a forest of tower blocks with a long central walkway between them, platforms off
to the sides, and coworkers standing on the tower tops — 13 meshes spanning x ∈ [−22,
22], y ∈ [−20, 20.5], z ∈ [−186.2, −152], with the last checkpoint and trigger zone at
y ≈ 13. With no sky, everything around and above those towers was pure black, so the
whole climax read as unlit void rather than a city. `mat_skyboxFernandito`'s "1
reference" was misleading in the same way the per-asset collider counts were: one
reference, but the backdrop of the entire final section.

Now `background_mode = 2` with `materials/sky_fernandito.tres`. Unity used the
built-in **Skybox/6 Sided** shader (`fileID: 104`) with six 1016×1016 faces, and Godot
has no six-sided sky material, so `tools/build_skybox_panorama.py` resamples them into
one 4096×2048 equirectangular panorama for `PanoramaSkyMaterial`. Tint
`(0.5, 0.5, 0.5, 0.5)` and exposure 1 are that shader's neutral values and rotation is
0, so no colour correction is applied.

Two independent mappings had to be right, and both invert easily:

- **Face assignment.** Unity's inspector labels are Front `[+Z]`, Back `[-Z]`, Left
  `[+X]`, Right `[-X]` — Left really does mean +X. The material then *crosses* the
  horizontal pair (`_LeftTex` = `right.tif`), and the `diag(-1, 1, 1)` conjugation
  crosses them back, so the filenames end up matching Godot's axes. Two independent
  facts that happen to cancel; do not "simplify" either away.
- **Inside vs outside.** Skybox faces are painted to be seen from *inside* the cube,
  while OpenGL cubemap faces are defined from *outside* — a horizontal mirror on all
  four sides. Using the GL formulas gives a sky that is **continuous but mirrored**,
  and seam continuity cannot detect that, because a mirrored sky is exactly as
  continuous. Derived instead from `r = cross(f, up)`, checked against the one case
  Godot fixes for us: its camera looks along −Z with +X to the right, and
  `cross(-Z, +Y) = +X`. So looking along +Z puts +X on the **left**.

Verified three ways. Seam continuity across the four vertical seams fell from ~9.0 to
**≤1.19** of 255 once the mirror was right. The two pole faces have no derivable up
vector, so their orientation was *measured* against the derived sides — both land on
`rot180`, with clear margins (0.33 vs 0.92, and 1.00 vs 2.17). And `front.tif`'s glow
lands at the panorama's wrap edges, which is exactly +Z, where that face belongs.

**Ambient deliberately stays flat colour.** Unity's `m_AmbientMode: 3` is Flat at
`(0.2235, 0.2353, 0.2235)`, so `ambient_light_source` remains 2 (Color), not Sky.
Deriving ambient from the sky would relight the entire level off a backdrop Unity never
lit with. Reflections are a separate question and go the other way: Unity's
`m_DefaultReflectionMode: 0` **is** Skybox at intensity 1, so Godot taking reflections
from the sky is faithful. That is the only reason the interior changed at all — 0.2%
RMSE from an identical camera.

Screenshots of the area, for reference when porting it, can be regenerated with:

    xvfb-run -a godot-mono --path . --script tools/shot_at.gd -- \
        /tmp/far.png 0 15 -184 0 13 -155

`shot_at.gd` takes an optional eighth argument for the scene, and asserts it actually
owns the viewport before writing — it used to ignore its camera arguments entirely,
which is why this area went unlooked-at for so long.

## Remaining work

### 1. Materials and shaders

Three ShaderLab shaders still to port, following the method proven on
Fortunato (gamma-space math, `LIGHT_COLOR / PI`, `ALBEDO = vec3(1.0)`):

| Shader | Used by | Refs |
|---|---|---|
| `shader_generalTransparencia` | `mat_generalTransparencia` | **57** |
| `shader_general` | `mat_general` | 27 |
| ~~`shader_torta`~~ | `mat_torta` | **done** — `shaders/cake_glow.gdshader`, on the cake's `GEO_Torta` |
| `shader_fade` | UI fade | — |
| ~~skybox~~ | `mat_skyboxFernandito` | **done** — `materials/sky_fernandito.tres`; it was the whole ending area's backdrop, see Lighting |

Plus `MAT_Platic`, `MAT_Screen`, `lambert2`, `lambert3` (likely plain
`StandardMaterial3D`), and four tutorial-key materials (`wasd`, `space_key_l`,
`shift_key`, `controller`).

`mat_generalTransparencia` at 57 references is the single most impactful
material in the level — worth doing first and doing right.

### 2. Gameplay scripts — 557 lines across 16 files

Everything left is small. Largest is 78 lines.

| Lines | Script | Instances | Notes |
|---|---|---|---|
| 78 | `Fortunato.cs` | 1 | **done** — `Die`/`Revive` on `PlayerCharacter` |
| 55 | `FadeUI.cs` | — | superseded: the level uses `GUIFadeEffect`, already ported as `FadeOverlay` |
| 51 | `ParentPlayer.cs` | — | **not ported**, and not needed — see below |
| 50 | `FallingPlatform.cs` | 8 | **done**, `scripts/Gameplay/FallingPlatform.cs` |
| 43 | `TriggerZone.cs` | 2 | **done** — wired directly in `RespawnChain.cs`, not as a generic emitter |
| 39 | `SoundAttenuationByDeath.cs` | 7 on clusters | **done**, `WhisperEmitter.cs` |
| 34 | `Credits.cs` | 1 | **done**, `scripts/UI/Credits.cs` |
| 31 | `FortunatoAnimFunctions.cs` | — | **done** — footstep events re-added; `Die`/`Cry` have no clips to fire from |
| 30 | `TimerZone.cs` | 1 | **done**, `scripts/Gameplay/TimerZone.cs` — carries the ending chain |
| 30 | `PauseMenu.cs` | — | **done**, `scripts/UI/PauseMenu.cs` |
| 24 | `RandomizeMonoAnimStart.cs` | **74** | **done**, `CoworkerSprite.cs` |
| 23 | `YBillboardFollow.cs` | **74** | **done** — a billboard mode, no script |
| 23 | `Door.cs` | 1 | **done**, `scripts/Gameplay/Door.cs` + `scenes/puerta_inicio.tscn` |
| 20 | `CamControllerFunctionAccess.cs` | 1 | **nothing to port** — `PauseMenu`'s reference to it is `fileID: 0`, unassigned, and never read |
| 19 | `ResetLocalPosition.cs` | 1 | **done** — it sat on Camera Target; `RespawnChain` resets it |
| 7 | `UnityEventContainer.cs` | 1 | **done** — collapsed into `TimerZone.OnFadeOutCompleted`; it only existed to box a call list as an object argument |

### 3. The coworkers are 2D sprites — **done**

The coworkers are **billboarded sprite-sheet animations**, not 3D models. See
"Coworkers" below; the count in this section was wrong and is corrected there.

### 4. Not needed

- `Antialiasing.cs` — Godot has MSAA (already `msaa_3d=2`) and FXAA built in.
- `VignetteAndChromaticAberration` — **done**, see `shaders/death_distortion.gdshader`.
- `EventSystem` — the unresolved script guid `f5f67c52…` is Unity's built-in
  `UnityEngine.UI` assembly, not project code. Godot's `Control` system covers it.
- `Yelena.prefab` — disabled in the scene.

## Coworkers

> **Correction.** This document counted "31 `SpriteRenderer`s + 31
> `YBillboardFollow` + 32 `RandomizeMonoAnimStart`" and treated that as the number
> of coworkers. There are **74**: 45 mono1 and 29 mono2. Those 31 are stripped
> component *documents* in the scene, which Unity writes only for objects carrying
> overrides — the same trap this document already warns about twice for
> UnityEvents and `m_IsActive`. Three of the five coworker prefabs are clusters:
> `coworkers_group 1`, `coworkers_group2` and `coworkers_group3` each bake in seven
> coworkers, 4 mono1 and 3 mono2, as plain GameObjects rather than nested prefab
> instances. So 13 mono1 + 5 mono2 placed directly, plus 8 group instances of 7,
> comes to 74. Anything counting prefab documents in this scene is counting the
> wrong thing.

Every coworker is one node. Unity had four things per figure — a `SpriteRenderer`,
an `Animator`, `YBillboardFollow` and `RandomizeMonoAnimStart` — and all four
collapse into an `AnimatedSprite3D`:

| Unity | Godot |
|---|---|
| `SpriteRenderer` + `Animator` | `AnimatedSprite3D` over a packed atlas |
| `YBillboardFollow` | `billboard = BILLBOARD_FIXED_Y` |
| `RandomizeMonoAnimStart` | `CoworkerSprite.cs` |
| `AudioSource` + `SoundAttenuationByDeath` | `WhisperEmitter.cs` |

**The sprite pivot is the one thing that will catch you.** The frames the clips
actually use were imported with `alignment: 7` — BottomCenter — so a coworker's
Unity position is where its *feet* are, not its centre. The scenes reproduce that
with `offset = (0, 64)`. Checking the pivot on the wrong file gives the wrong
answer: `Mono 1/Sprites` holds 153 PNGs, the 81 the animation uses are the
`Untitled-4NNNN` take at `alignment: 7`, and the unused `mono1_00NN` take is
`alignment: 0`, centred. Get this wrong and all 74 are buried to the waist.

Frame order comes from the clip's PPtr curve, not from filenames — the used frames
are split across two naming schemes that do not interleave in filename order.
mono1 is 81 frames over 2.7 s, mono2 is 70 over 2.333 s, both at 30 fps, both
looping. Packed into one atlas each with a 2 px transparent gutter, **19 MB of
individual PNGs becomes 175 KB of texture**. No frame in mono1 has a
non-transparent border pixel, so the gutter is lossless there; one mono2 frame has
a border alpha of 10 out of 255, whose outermost pixel row fades slightly.

Sizes need no conversion: Unity imported at 100 pixels per unit and Godot's
default `pixel_size` is 0.01 m, so a 128 px frame is 1.28 m in both.

**24 of the 74 are scaled non-uniformly**, up to about 3.7×, because the artists
scaled whole clusters and Unity composes that component-wise onto the children.
Godot keeps X and Y scale independently through fixed-Y billboarding — measured at
2.96× and 2.00× for a (3, 2, 1) scale, not assumed, because a billboard shader that
normalised the X axis would quietly squash every one of them back to square.
Rotation is *not* emitted: `YBillboardFollow` overwrote it every frame, so what the
artists authored never reached the screen, and re-emitting it would only tilt the
coworkers whose basis carried pitch.

> **Correction, twice over.** This said "only 10 of 74 have any collision geometry
> below" and explained it away as background figures standing in open space. The
> number was an artefact of **two** independent mistakes, and the reassuring
> explanation was wrong both times:
>
> 1. **The placements were mirrored on X.** See the placement convention section.
> 2. **One-sided trimesh collision was hiding the floors.** `verify_coworkers.gd`'s
>    own docstring asserted that enabling `backface_collision` "changes nothing" —
>    but the script never set it. The claim was never tested in code. Setting it
>    takes the count with nothing beneath them from 24 to **1**.
>
> After both fixes, **73 of 74 coworkers have collision geometry beneath them.**
> Confirmed visually afterwards: every coworker stands on or above visible scenery,
> none floating. So the alarming raycast result was right twice and the rationalisation
> was wrong twice. Do not let a support probe argue that placement is fine, and do not
> let an explanation stand in for setting the flag and re-running.

Current state, with two-sided collision enabled: 73 of 74 have a surface beneath
them, 38 within 0.35 m, 5 flush within 2 cm. The remaining 35 sit further above
their nearest collision surface — consistent with figures on upper levels and behind
the outer wall around x = −60, seen through the transparent windows — and one has
nothing beneath it at all. A visual pass found none of them floating, so this is not
tracked as a defect; but the probe measures **collision coverage as much as
placement**, so do not read its gaps as placement error without looking.

What corroborates the placement beyond the raycast count is precision: coworkers land
on floor planes at gaps of exactly 0.0000 m, and direct instances ground at the same
rate as group children — which is what ruled out the group composition as the culprit. `tools/verify_coworkers.gd` reports the
distribution rather than scoring it, for exactly that reason.

The whisper — `susurro_loko`, 14.1 s, converted from 2.5 MB of WAV to 197 KB of
Ogg Vorbis — sits on the cluster roots, 7 of them: 2 at minDistance 1→10 and 5 at
40→45. Unity's logarithmic rolloff attenuates by `minDistance / distance`, which is
Godot's `ATTENUATION_INVERSE_DISTANCE` over `unit_size` exactly, so the mapping
needs no fudging. `coworkers_group3` has no `AudioSource` at all.

Two documented divergences in `WhisperEmitter.cs`. Volume follows the death
constant, where Unity set it once in `Start`; that only works if the scene reloads
on death, and this game respawns through a fade, so on the original's code path the
volume stays at its level-load value of zero and the whisper is never heard —
which the script's own comment says is not the intent. And the stagger is a random
start position rather than `PlayDelayed` of a random offset; both desynchronise the
seven emitters, but Unity's leaves each silent for up to 14 seconds first.

## Hazards and the respawn chain

**The hammers do no damage.** Both of `martillo_prefab`'s box colliders are solid,
not triggers, and the prefab carries no script — only an Animator. The hammer shoves
the player, and the fall into the kill volume is what kills. So the level needs no
health or damage system at all, which is why `Fortunato`'s clipless `damage` state
never mattered. Five of them hang in a row at z = −73 to −94.5, pivoting 8 m above
the floor with a 7 m arm, swinging −80° to +80° and back over 2.6333 s.

**The mesh had the rest pose baked in twice — fixed.** Reported in play as "the
hammers' collision seems unsynced from the animation". It was not a timing problem at
all: the physics transform tracks the node **exactly**, measured at 0.000000 over 170
ticks, so `sync_to_physics` and the physics callback mode were both innocent.

The real cause is a double rotation. Unity's animated `martillo` node carries a rest
rotation of **−80° about Z** (`m_LocalRotation` z = −0.64278764), and Godot's FBX importer
**bakes that into the mesh node** as −79.6898°. The swing animation drives `Arm` with
*absolute* angles straight from Unity's clip, −80° to +80°, so with the rest pose still
baked in the mesh received the animated angle **plus** −79.69° while the colliders
received the animated angle alone. At rest the drawn hammer sat ~80° from the thing that
hits you, and since the head is 6 m out that is metres of error — measured as a **4.485 m**
gap between mesh and collider centres. It also meant the hammer appeared to point *up*
rather than hang.

`hammer.tscn`'s `Model` transform is therefore the **exact inverse of the mesh node's own
local transform**, not the plain `-8` on Y it used to be, which cancelled the offset and
left the rotation. Do not simplify it back.

This is the general trap: **a baked rest pose plus an absolute-angle animation double-counts
the rest pose.** Either the animation is relative and the bake stays, or the animation is
absolute and the bake must be cancelled. Mixing them puts geometry and collision in
different places, and the symptom looks like a sync bug rather than a transform bug.

`tools/verify_hammer.gd` pins all four facts: the FBX's baked rest rotation matches what
the scene's correction assumes (so a reimport that changes it fails loudly), the physics
transform tracks the node, the mesh and collider volumes coincide in `Arm` space, and the
swing still covers ±80°. Confirmed to catch the original bug: restoring the old `Model`
transform fails the alignment check at 4.485 m.

The swing is baked at Unity's own 30 fps rather than transcribed as nine keys:
Unity stores a Hermite spline per quaternion component and Godot's `rotation_3d`
tracks offer neither those tangents nor a way to express them. Note the track
format — six floats per key, `time, transition, x, y, z, w`. Five is silently
rejected with only `Condition vcount % ROTATION_TRACK_SIZE is true` to go on, and
the animation then does nothing.

**The kill volume is a 152 × 1 × 322 m slab** at y = −8.3, under everything. Its
three checkpoints are children of it, and because the root is scaled, their local
offsets are in scaled space: Check Point 1's local x of −0.003 is 0.46 m and its
local z of 0.18153 is 58 m. Composed properly, Check Point 1 lands at
(−0.17, 1.25, 4.29) — a metre above Unity's player start of (0, 0, 4.018), which is
what confirms the composition is right.

The two Trigger Zones move the checkpoint on and reset the death count. Their
collider is **not** a trigger in the prefab (`m_IsTrigger: 0`); every instance
overrides it to 1. Taking the prefab at face value would give a level where the
checkpoint never advances past the first one.

### The chain was never code

None of the death sequence existed as a script. It was a UnityEvent graph across
three prefabs, with every target and half the method names stored as
prefab-instance overrides. Recovered, it is:

| Fires | Calls |
|---|---|
| `onCheckPointCollision` | `CanValidateInput = false`, `Fortunato.Die()`, **`Camera Target` → "Temporal Target Parent"**, `UI.FadeOut()`, `SumarMuerte()`, a `SetActive` on a null target |
| `OnFadeOutComplete` | **`Camera Target` → `Camera Target Parent`**, `UI.FadeIn()`, `Camera Target.ResetPosition()`, `Fortunato.Revive()`, `TransportPlayer()` |
| `OnFadeInComplete` | `CanValidateInput = true`, `SetFadeInSpeed(2)`, `SetFadeInDelay(0.5)` |

`RespawnChain.cs` reproduces it in that order, because the order is the behaviour:
the teleport happens while the screen is black and after `Revive` has cleared the
fall speed. Only the `SetActive` has no counterpart; its target is null in Unity too.

> **Correction.** This said the two reparenting calls moved **the player**, to undo
> `ParentPlayer`'s platform parenting, and that dropping them was therefore safe. Wrong
> on both counts, and the user caught it in play: *"in the original when dying, the camera
> would stop following the player once the dying animation started — it was intentional,
> to give a certain effect to death."*
>
> The reparented object is `Camera Target` (`Fortunato.prefab` fileID 4000011707492224),
> a child of `Camera Target Parent` inside Fortunato, and the camera follows it. Lifting
> it onto the static `Temporal Target Parent` freezes it — Unity's parent setter keeps
> world position — so the camera holds still while the corpse keeps falling and the player
> drops out of frame. You never watch the landing. `SetParent` and `ResetLocalPosition`
> put it back afterwards.
>
> Two things should have prevented this. The chain was read as "reparent to Temporal
> Target Parent" without resolving *which* transform the call targeted — a stripped
> prefab transform whose name only appears in `Fortunato.prefab`. And
> `ResetLocalPosition.cs` (`self.localPosition = Vector3.zero`), wired to `Camera Target`
> on the very next event, was recorded without asking why zeroing a local position would
> be needed at all: it only means something if the node has just returned from another
> parent. A call whose purpose is unexplained is not a call that can be safely dropped.
>
> Ported in `RespawnChain.DetachCameraTarget` using Godot's `TopLevel` rather than
> reparenting, so the effect needs no node outside `player.tscn`. Measured in
> `tools/verify_death_camera.gd`.

**This settles the `respawnDelay` question.** The real timing is the fade's:
1 s `fadeOutDelay`, 2 s to black at 0.5 alpha/s, then the teleport, then 1 s and
0.667 s back at 1.5 alpha/s — and the last two calls above speed every later
fade-in up to 0.5 s. Measured end to end in `tools/verify_respawn.gd`: death to
black is 3.00 s, teleport on the same tick as full black, control back 1 s later.
`respawnDelay` is 2 in the prefab and read by nothing.

A quirk worth knowing: a fade already running swallows further requests, in the
original and in the port. Dying during the level's opening fade-in therefore drops
the fade-out and the sequence never starts. It cannot happen in play — the player
stands on solid ground with input disabled until that fade finishes — but it does
mean a test has to wait for the level to open before it can kill anyone.

### Footsteps

Unity fired `PlayStepSound` and `RandomizePitch` from animation events on the walk
and run clips. Animation events do not survive an FBX export, so the clips arrived
silent; `tools/add_footstep_events.gd` puts them back as method tracks.

The footfall times are **measured off the rig**, not assumed at 0% and 50% of the
cycle. Each foot's `Toes_L`/`Toes_R` bone is sampled from the live skeleton at 120 Hz
across the clip — bone tracks are local, so the only way to get a real height is to
play the animation and read the global pose — and a footfall is where a contact
*begins*: the first frame of each run below the lower third of that foot's own height
range. Not a local minimum: a planted foot's height wobbles by fractions of a
millimetre for dozens of frames, which turned a two-step walk cycle into thirteen
"low points" per foot. The contact's start is also the better answer, since that is
when the foot lands rather than somewhere mid-plant.

The result is a stride pattern that stands up on its own: walk contacts at 0.000 s
and 0.783 s of a 1.533 s cycle, run at 0.100 s and 0.600 s of 1.000 s — each pair
almost exactly half a cycle apart, and walk starting on contact as an exported walk
cycle does.

Two things this needed along the way:

- **Walk and run had to be set looping.** Every clip arrived from the FBX with
  `loop_mode` 0, and a locomotion cycle that does not loop fires its events once and
  stops. Unity looped them — they are the `walk_run_tree`'s two states.
- **The key at t = 0 had to move half a frame in.** It sits exactly on the loop seam,
  where the playhead arrives by wrapping rather than by advancing onto it.

`PlayStepSound` does the pitch randomisation itself rather than relying on a second
method key at the same time, whose firing order would depend on insertion order. The
pair was always used together anyway: `Fortunato.Update` called `RandomizePitch` and
then played the same source whenever the animator sat in `land` or `land_moving`.
Neither land clip came across either, so that path is now a single play on touchdown,
which is what the short state amounted to.

`step.wav` is vendored as a WAV, not converted: at 6.5 KB and 37 ms there is nothing
for Ogg to save.

`Die` has no animation to play. The `damage` and `death` states have no clip
anywhere in the project, so it plays the fall clip: the closest thing the project
owns, and correct for the only way the player dies. `Revive` clears the velocity,
standing in for `charController.Move(Vector3.zero)` — without it the fall speed
survives the teleport and drops the player straight back through the floor.

## Platforms

Both platform prefabs are the same single box: **2 × 20 × 2 m, top face at
y = 0**. A 2 m square you stand on, on a 20 m column hanging into the void. The
column is meant to be seen dissolving: vertex red runs 1 along the bottom edge to
0 along the top, and `mat_generalTransparencia` turns red into transparency, so
the standable surface is solid and the column fades out below it. The two effects
that shader couples — wobble and alpha — are both on that same channel, which is
why the columns shimmer as they fade.

> **Correction.** The recon above cited "a `plataforma` BoxCollider is
> 1.96 × 0.41 × 2.03 m" as corroboration of the level's scale. The footprint is
> right and confirms `root_scale = 100` (0.02 → 2.00 exactly), but that box is the
> prefab's *trigger volume*, not the platform: 0.41 is how thick a detector sitting
> on top of the platform is, not how thick the platform is. The platform is 20 m
> deep. Anything reasoning about how these look from the numbers alone should read
> `tools/platform_report.gd` instead.

Unlike the shell, the platforms needed **no material table**: their two FBX
material names map to the same two Unity materials in both models and in every
instance, so `lambert1` → `level_general` and `lambert2` → `level_transparent` as
plain `_subresources` remaps in the `.import` files. The per-renderer-slot problem
that forced `LevelShell.cs` simply does not arise here.

`plataforma_anim` is reproduced key for key as a Bezier track in
`moving_platform.tscn`: Unity's six Hermite keys convert exactly, and the result
tracks the original to 16 µm over the whole 6.633 s loop. The FBX also ships the
artist's Maya take, which the port ignores exactly as Unity did — worth knowing
only because it independently agrees on both amplitude and period, differing just
in starting phase.

Two findings worth carrying forward to the hazards and the ending:

- **`ParentPlayer` has no Godot equivalent and needs none.** It existed to carry
  the player on a moving platform by reparenting. An `AnimatableBody3D` with
  `sync_to_physics` reports its own velocity and `move_and_slide` applies it, so
  a rider follows to within 3 mm with no script and no trigger volume. This is
  the same kind of substitution as `YBillboardFollow` becoming a property.
- **The moving node has to *be* the body.** With `sync_to_physics` on, the body
  writes its own transform back from the physics server every tick, so moving a
  parent `Node3D` moves the mesh and the trigger while the collision body stays
  put — the player ends up standing on an invisible collider while the platform
  descends beneath them. `FallingPlatform` is therefore an `AnimatableBody3D`
  itself. This will apply to the hammers too.

`tools/verify_platforms.gd` checks all of this — curve fidelity, that a rider is
carried, and that the fall delay, speed, reset distance and carry match the
prefab. `tools/platform_report.gd` measures the models and the placement, and
`tools/shot_platforms.gd` renders the platforms without the shell around them.

## Suggested order

1. ~~**`shader_general` + `shader_generalTransparencia`**~~ — **done**, plus
   `shader_torta`. See `shaders/level_lit.gdshader`, `level_fade.gdshader`,
   `cake_glow.gdshader`.
2. ~~**Level shell**~~ — **done**. `scenes/level.tscn` holds both halves with
   trimesh collision on all 53 meshes and 73 per-surface materials applied from
   `models/level/level_materials.json`. The player is not in it yet.
3. ~~**Static props**~~ — **done**. `scenes/props.tscn` places 61 instances across
   9 entries. These are the `globalScale: 1` group: imported at `root_scale = 1`,
   not 100.

   The first pass missed the four `tablePcs` desk clusters, because the
   generator's `STATIC` set listed only `.fbx` models and `tablePcs` is a prefab
   assembling four of them. They are in now, as `scenes/table_pcs.tscn` from
   `tools/generate_table_pcs_scene.py`, which also required vendoring
   `book.fbx`. Read the two "Risks" entries on per-instance collision and the
   `diag(-1, 1, 1)` importer mirror before touching them — neither is guessable
   from the scene.
4. ~~**Platforms**~~ — **done**. `scenes/platforms.tscn` places all 26 from
   `scenes/moving_platform.tscn` and `scenes/falling_platform.tscn`.
   `ParentPlayer` was not needed. See "Platforms" below.
5. ~~**Coworkers**~~ — **done**. `scenes/coworkers.tscn` places all 74 plus the
   7 whisper emitters, which closes the death-constant loop `GameManager` was
   ported for. See "Coworkers" above.
6. ~~**Hazards and the respawn chain**~~ — **done**, footstep events included.
   See "Hazards and the respawn chain" above.
7. **Ending and UI** — remaining: the five tutorial key props (`WASD`, `WASD (1)`,
   `Spacebar`, `Shift`, `Tutorial`, on Unity's built-in cube mesh, with four unported
   key materials). Everything else in this step is done.
   `WASD (1)`, `Spacebar`, `Shift`, `Tutorial`, on Unity's built-in cube mesh) and
   `Door` for `puertaInicio`.

   Done so far in this step:
   - `mat_skyboxFernandito` — the ending area is exterior, so without it the whole
     climax rendered against black. See "The skybox was an ending-area problem"
     under Lighting.
   - **`meta.fbx` and `cake.fbx`** — see "The ending pair" below.
   - **`TimerZone`, `Credits` and `UnityEventContainer`** — the ending chain now
     runs end to end. See "The ending chain" below.
   - **`particleSys_conffeti`** — see "The confetti" below.

### The confetti — `particleSys_conffeti`

Unity's only `ParticleSystem`, and Godot has no equivalent object, so every module was
read out of the prefab and mapped by hand into `scenes/confetti.tscn`. It sits 4 m above
the FINISH banner at Unity `(-0.02, 16.22, -183.531)`, conjugated to negate X, turned 90°
about X — which aims the emitter's local +Z straight down, verified as `(0, -1, 0)` in
world space — so the confetti rains onto the finish line.

| Unity | Godot |
|---|---|
| `lengthInSec` 2, `looping` 0 | `one_shot`, plus `explosiveness` — see below |
| `EmissionModule` rate 50/s, no bursts | `amount` 100 = 50/s × 2 s |
| `startLifetime` 10 constant | `lifetime` 10 |
| `startSpeed` 0.5 constant | `initial_velocity_min/max` 0.5 |
| `startSize` random 0–0.04 | `scale_min` 0, `scale_max` 0.04 on a 1 m quad |
| `startRotation` random 0–π rad | `angle_min` 0, `angle_max` 180° |
| `gravityModifier` 0.5 | `gravity` (0, −4.905, 0) = 0.5 × −9.81 |
| `ShapeModule` Cone, radius 1, angle 25° | Ring emission r = 1 + `spread` 25° |
| `startColor` 5-key gradient | `color_initial_ramp` |
| `ColorModule` alpha 0/1/1/0 | `color_ramp` |
| Renderer billboard, `mat_conffeti` | `QuadMesh` + billboarded material |

Three places it is **not** a one-to-one translation, all documented in the scene:

1. **The emission window.** Godot emits `amount` particles spread over `lifetime`, so a
   2-second burst of 10-second particles cannot be expressed by those two numbers alone.
   `explosiveness` compresses emission into `lifetime × (1 − explosiveness)`, so 0.8
   gives exactly 2 s of emission at 50/s out of a 10 s life. Verified: 2.00 s, 50.0/s.
2. **The start colour is a five-colour rainbow, not two colours.** `minMaxState` is 1
   (Gradient) with keys red `#FF0000`, blue `#000CFF`, green `#00FF41`, purple
   `#A81FFF`, yellow `#DCFF00` at t = 0, 0.265, 0.591, 0.797, 0.988. The material's
   leftover `minColor`/`maxColor` (cyan and red) are unused in that mode and are a trap.
   A five-colour rainbow as a *start* colour only makes sense sampled randomly per
   particle, which is what `color_initial_ramp` does; evaluating it at t = 0 instead
   would make every piece red.
3. **The blend mode is a judgement call.** `mat_conffeti`'s active shader is a Unity
   built-in referenced only by `fileID: 203`, which cannot be resolved without Unity's
   builtin resource manifest, and the material carries orphaned properties from two
   shaders at once — Standard (`_Metallic`, `_Mode`, `_SrcBlend`) alongside the legacy
   particle ones (`_TintColor`, `_InvFade`). Its `_MainTex` is empty and `_TintColor` is
   the neutral default. Alpha blending was chosen over additive on two grounds: the
   `ColorModule` alpha curve (in over the first 4.7%, out over the last 12.6%) is what
   alpha blending is for, and additive would blow the saturated palette out to white
   wherever pieces overlap, reading as sparks rather than paper. **If it should be
   additive, that is `blend_mode = 1` on the material and nothing else.**

**It also fires once at level load, and that is faithful.** `playOnAwake` is 1 in the
prefab and the scene does **not** override `m_IsActive`, so Unity fires it the moment the
level starts — 187 m from the player, invisible. `emitting = true` with `one_shot`
reproduces that rather than hiding it; `TimerZone` calls `Restart()` for the real one.

The shower is brief by construction: 4.2 m from emitter to banner under 4.905 m/s²
gravity is about 1.2 s, after which the pieces fall past the walkway edge. Screenshots
therefore have to be taken early — around frame 70 of a fresh load — or the confetti has
already gone. Pieces are 0–4 cm, so they read as small specks rather than paper, which
is what `startSize` says.

### The ending chain — `TimerZone`, `Credits`

`TimerZone` is a generic two-event timer in Unity: `onTriggerEnter` fires at once,
`onAfterDelay` `delay` seconds later, and **everything specific to the ending lived in
the UnityEvent wiring, not the script**. Reading only the two `.cs` files would have
produced a working timer that does nothing. The wiring, out of `nivelEscena`
(`delay: 5`) and `UI.prefab` (`scrollspeed: 3`, `creditsTime: 10`):

| when | calls |
|---|---|
| on enter | `InputManager.set_CanValidateInput(false)`, `Fortunato.Cry()`, `GUIFadeEffect.SetOnFadeOutComplete(Event Container)`, `particleSys_conffeti.Play()` |
| +5 s | `GUIFadeEffect.FadeOut()` |
| fade fully black | `Credits panel.SetActive(true)`, `Credits.RollCredits()` |
| +10 s of rolling | `GoToMainMenu()` |

Reproduced directly in `TimerZone.cs`, the same choice `RespawnChain` made for the
death chain, rather than building a generic UnityEvent emulation for one instance.
Three details worth keeping:

- **The fade's completion callback is armed in the *first* event**, before `FadeOut` is
  ever called in the second. Arming it after would be a race.
- **`UnityEventContainer` was pure plumbing.** `SetOnFadeOutComplete` takes a single
  `UnityEvent` object argument, so a list of calls had to be boxed in a component to be
  passed at all. Here it is just the body of `OnFadeOutCompleted`.
- **The trigger** is at Unity `(0.02, 12.0, -182.32)` — conjugated to negate X — with a
  4 × 4 × 1 box offset `(0, 2, 0)`, which puts it in the FINISH banner's opening. It is
  hand-authored in `level.tscn`, so outside `unity_space.py`'s reach.

`Fortunato.Cry()` is `anim.SetTrigger("Cry")`, and the "Cry" state has **no clip
anywhere in the project** — same as the death state. Unlike `Die`, it gets no
substitute: the fall clip was a defensible stand-in for dying by falling, but nothing
in the project reads as crying and inventing an animation is not porting.
`PlayerCharacter.Cry()` therefore leaves the pose alone and exists so the chain matches
call for call, and so the hook is wired for whoever adds the animation.

`Credits` is a **timed** scroll, not a scroll-until-offscreen: after `creditsTime` the
text stops wherever it reached, which at 3 units/s for 10 s is 30 units. The text block
is far taller than that, so most of it never arrives. Both numbers are the instance's,
so this is faithful rather than a bug — but it is the first thing to check if the
credits ever look wrong. Godot's Y axis runs opposite to Unity's `anchoredPosition`,
hence a subtraction where Unity added.

`tools/verify_ending.gd` drives the whole chain and checks the order and timing, which
is where the failure modes are. Entry → input disabled 0.03 s, entry → fully black
8.02 s (5 s delay + 1 s `fadeOutDelay` + 2 s at 0.5 alpha/s), black → credits shown
0.02 s, roll duration 10.00 s. It also asserts `MainMenuScenePath` resolves *before*
blanking it to keep the scene from being torn down mid-test.

> **Note on the verifier.** An earlier version sampled `fade.color.a >= 0.999` to
> detect black. That passed once and failed on the next run: the tween reaches 1.0 on
> the same frame the signal fires, so a sampled threshold is a coin flip. It subscribes
> to `FadeOutCompleted` instead, which is what the chain actually depends on. If a
> check is racy, test the event, not the value it happens to leave behind.

`particleSys_conffeti.Play()` is wired as an optional `ConfettiPath` export that does
nothing while unset, so the confetti drops in without touching the chain.

### The ending pair — `meta.fbx` and `cake.fbx`

Both are `globalScale: 1`, so `root_scale = 1`, and both are plain solid meshes in
Unity: no `MonoBehaviour`, no trigger, no animator on the instances. So they are static
props in `scenes/props.tscn` and the ending's *behaviour* stays with `TimerZone` and
`Credits`, which are still unported.

| | `meta_01` | `cake_01` |
|---|---|---|
| world position | (−0.03, 12.0, −182.54) | (−0.078, 11.989, −184.986) |
| scale | 1 | 0.91587 uniform |
| world size | 2.84 × 3.13 × 0.64 m | 1.07 × 0.43 × 1.07 m |
| meshes | `GEO_Cartel`, `GEO_Soportes`, `GEO_Liston`, `typeMesh1` | `GEO_Plate`, `GEO_Torta`, `GEO_Trozo5`, `GEO_Trozos` |
| solid | `GEO_Cartel`, `GEO_Soportes` | `GEO_Plate` |

`meta` is the finish line: a FINISH banner on two poles, with a cut red ribbon
(`GEO_Liston`) and the lettering as its own mesh (`typeMesh1`). The cake sits 2.4 m
behind it. Every material they need was already ported — `MAT_Cartel`, `MAT_Barras`,
`MAT_Liston`, `lambert5`, `MAT_Platic`, `MAT_Chocolate` — so both `.import` files just
map them externally.

**Which sub-meshes are solid was resolved, not guessed.** Unity references collided
meshes by fileID, and an FBX's meshes are `4300000 + 2i` in the order they appear in
the file. That order was read out of the binary FBX (the names sit in the Objects
section at even ~520-byte spacing) and matches Godot's imported child order exactly.
The same convention is independently confirmed by the cake's material override, which
targets MeshRenderer `2300002` — index 1, `GEO_Torta` — the one mesh whose native
material `lambert1` is what `mat_torta` sensibly replaces. Two routes, same answer, so
the collider mapping is trustworthy rather than plausible.

**The cake body is deliberately not a solid cake.** `mat_torta` on `GEO_Torta` is
`shaders/cake_glow.gdshader`, an emission-only additive pulsing rim glow — the ported
`shader_torta`, which declares no properties at all. So the cake renders as a glowing
outline that fades in and out, while the plate and the chocolate crumbs are ordinary
opaque surfaces. This is faithful to the shader as ported, and it is easy to mistake
for a bug: the first screenshot of it caught `sin(2·TIME)` negative at frame 160
(t ≈ 2.67 s, sin ≈ −0.81), where the clamp makes the body vanish entirely. If the cake
was in fact meant to be solid, the thing to re-examine is the `shader_torta` port, not
the material mapping — the mapping is confirmed above by fileID.

Steps 2–4 are mostly mechanical volume. Steps 5–6 are where the real
behavioural work is.

## Risks and open questions

- **`respawnDelay` is unread.** Confirmed in the Unity source; the actual delay
  is the fade duration. Timing has to be recovered from the fade, not the field.
- **Animation events were missing; the footsteps and the jump foot are back.**
  `PlayStepSound` and `RandomizePitch` are Godot method tracks again, at footfalls
  measured off the rig — see "Footsteps" below. `SetLeftJump`/`SetRightJump` are now
  method tracks too, on the same footfalls, which is where Unity fired them.

  > **Correction.** This said `SetLeftJump`/`SetRightJump` "stay in code, where
  > `PlayerCharacter` alternates the take-off foot directly". That was wrong. Unity
  > fired them from animation events on **walk and run**, at the same frames as the
  > footstep sounds (walk: right 0.167 s, left 1.0 s; run: right 0.2 s, left 0.7 s), so
  > `LeftJump` means *"the left foot landed last"* — the airborne pose matches the
  > stride you took off from. Alternating per take-off gives strict L/R/L/R regardless
  > of gait, which the animator never did. See "The airborne clips" below.

  > **Correction.** This also said "`Die` and `Cry` have no clip to fire from: neither
  > state has one anywhere in the project." Both do. The Fortunato Controller's `death`
  > state points at `fall.anim` and its `cry` state at `cry.anim` (11.4 s), and both
  > import fine. Only **`damage`** is genuinely clipless — its motion guid resolves to
  > nothing. `PlayerCharacter.Cry` had been written as a deliberate no-op on the
  > strength of this claim; it now plays `cry`.
- **`damage` is the only clipless animator state.** Its motion guid resolves to nothing
  in FBX or `.anim` form, and nothing calls it — `Fortunato.Die` uses the `Death`
  trigger, not `damage`. Nothing to port.
- **`jumpR1Frame` was a degenerate export, and it was OURS — now restored.**

  > **Correction.** This once said the degeneracy was "a pre-existing defect in the jam
  > project" and that "Unity had exactly the same behaviour", so the descent holding
  > leftovers was faithful. **Unity's `jumpR1Frame.anim` animates all 43 deformation
  > bones.** Ours carried **2**: `Hip_L` and `Scapula_L`. A body pose where only those two
  > bones differ is not plausible, so it was missing source data, not compression - and it
  > had been rationalised as a feature rather than chased.

  Restored from Unity's own values by `tools/restore_clip_bones.gd`. The outcome is the
  best kind: the restored descent pose is **identical to 0.00°** to the take-off pose the
  degenerate clip used to leave behind, so **nothing changed visually** — Unity's
  `jumpR1Frame` genuinely *is* the jump-end pose, and the "airborne tuck" was Unity's
  intent arrived at by accident. What changed is that the descent no longer depends on
  what played before it: measured 0.00° whether the player arrives from `jumpR`, `walk` or
  `idle`, where previously 41 bones were inherited.
- **The `_moving` suffix is a misnomer.** Nothing in those states tests movement. The
  sub-machine's entry transition is the **only** use of `LeftJump` anywhere in the
  controller — `grep` the file, there is exactly one condition on it — and it selects
  the `_moving` set when `LeftJump` is true. They are the left-foot variants.
- **`fall.anim` is the death clip, not the falling clip.** The `death` state points at
  it; the airborne states use the single-frame jump clips. Our port played `"fall"`
  whenever `IsFalling`, and since a jump spends most of its arc descending, **every jump
  looked like dying** — the reported bug. Naming alone makes this very easy to get
  wrong, so it is the first thing to check if the jump ever looks off again.
- **`LeftJump` is gait state, not a counter.** See the correction above.

`tools/verify_jump_clips.gd` drives this through real simulated input rather than by
poking state, and asserts all four properties: the death clip never plays while
airborne, ascending uses `jumpL`/`jumpR`, descending uses the single-frame clips, and
both feet get selected across a run. Its walk stage waits exactly 60 physics ticks
(1.0 s at 60 Hz), which lands just past the measured left footfall at 0.783 s so the
left case actually runs — an earlier 130-tick wait landed past the right footfall and
the left branch was never exercised while the check still passed three of four.

One thing Unity has that this port does not: the **`land`/`land_moving` states**, which
hold the same single-frame clip briefly on touchdown before handing to `idle` or
`walk_run_tree`, with `hasExitTime` on their way back to falling. The port goes straight
from falling to grounded. Since the land states use the same clip as the fall states the
visible difference is small, and the exit timing was not recovered — worth doing if the
landing ever needs to read as a distinct beat.
- **The cursor is captured by the level, not by the camera asset.** The
  AdvancedUtilities camera's own `CursorComponent` has `Enabled = 0`, which reads as
  "this game never locks the cursor" and is why the camera port originally recorded
  exactly that. It is wrong: `GameManager.Start` invokes `onGameStart`, which the scene
  wires to `BloquearCursor` on the manager itself — `Cursor.lockState = Locked`,
  `Cursor.visible = false`. Godot's equivalent is `MouseMode.Captured`.

  The call has to come from something **level-scoped**. Unity's GameManager was a scene
  object, so its `Start` meant "a level began"; here it is an autoload whose `_Ready`
  fires when the *process* starts, before the main menu, whose buttons need a cursor. So
  `ThirdPersonCamera._Ready` calls `GameManager.StartGame()` — one per level, and the
  node the capture exists for — and `MainMenu._Ready` calls `ReleaseMouse()`, without
  which the menu is unclickable on the second visit because the credits return there
  with the mouse still captured. `StartGame` previously had **no caller anywhere in the
  project**, so the mouse was never captured at all.

  **This cannot be verified headlessly.** The dummy display server ignores
  `Input.MouseMode` and reports Visible throughout, so a headless check passes while the
  game is broken. Under `xvfb-run` the transitions are menu Visible → level Captured →
  menu Visible.

  `PauseMenu`, still unported, toggled the lock in Unity (`Locked` ↔ `None` with
  visibility flipped). `GameManager.CaptureMouse`/`ReleaseMouse` are the hooks for it.
- **The camera's vertical axis needed the OPPOSITE of Unity's flag.** Unity's scene sets
  `Invert.Vertical = 1` and this port copied it across, which inverted the look twice.
  The two engines' vertical mouse axes already run opposite ways — Unity's `Mouse Y` is
  positive when the mouse moves **up**, Godot's `Relative.Y` is positive when it moves
  **down** — and in the asset `RotateVertically(degrees)` pitches *down* for positive
  degrees, so Unity's flag is what gave the original mouse-up = look-up. Copying it gave
  aeroplane controls. `InvertVertical` is now `false`, which is the setting that
  reproduces the original's feel. **"Matches Unity's flag" and "matches Unity's feel" are
  not the same thing when an axis convention differs.**

  `tools/verify_camera_look.gd` asserts all four directions as *directions* — where the
  forward vector actually points after a synthetic mouse move — rather than as a sign, so
  it survives a refactor of how pitch is stored. Confirmed to catch the regression: with
  the flag back at `true` it fails the two vertical checks and passes the horizontal ones.
- **A finished non-looping clip must not be re-triggered.** Godot clears
  `current_animation` the moment a non-looping clip ends, so `if (CurrentAnimation !=
  next) Play(next)` re-plays it on the very next tick and keeps doing so for as long as
  the state holds. The jump clips are 0.167 s against an ascent of roughly 0.23 s, so a
  single jump replayed its take-off several times over. `PlayerCharacter` now compares
  against the clip it last *asked for*, which lets a clip end and hold its final pose —
  the behaviour the airborne, death and cry states all rely on.

  Only `idle`, `walk` and `run` loop, per Unity's `m_LoopTime`, and `idle` was importing
  as non-looping. `tools/set_clip_loops.gd` sets all nine from that table and warns about
  any clip not in it. At 12.7 s, idle's restart read as an occasional hitch rather than a
  loop bug, which is why it went unnoticed.

  `tools/verify_jump_clips.gd` counts clip completions via `animation_finished`: each
  take-off clip must finish at most once per jump. Note that once a clip ends,
  `current_animation` is empty while the pose it left is still on screen, so anything
  measuring "which clip is showing" has to fall back to `assigned_animation` — the first
  version of that check under-counted the descent by 22 ticks for exactly this reason.
- **A verifier that fails one run in three is worse than none.** `verify_footsteps.gd`
  did, for two independent reasons, and both are the same mistake: a bound set to a value
  the measurement can actually take. It played exactly 2.0 cycles, so whether the second
  stride's last footfall fell inside the window was decided by frame pacing; and its
  0.05 s tolerance was exactly equal to one of the gaps that legitimately occur. The gap
  is *quantised* — a method key fires on the first frame past it and the sound is polled a
  frame later, so it is always a multiple of 1/60 s, measured at 2, 3 or 4 frames. The
  limit now sits strictly above the largest legitimate value, at five frames, and the
  window is 2.25 cycles. Zero failures in eight consecutive runs.

  Its key-count check also had to learn about the second method track: the clips carry
  `PlayStepSound` *and* `SetLeftJump`/`SetRightJump`, so counting every method key made it
  fail at 4 when the footsteps were fine. It counts `PlayStepSound` specifically now.
### The entrance door — `puertaInicio`

`Door` is one line: `OnTriggerEnter` sets the animator's `Open` trigger. Note what is
**not** there — no tag check, unlike `TimerZone`'s `CompareTag("Player")` — so anything
entering the volume opens it. Reproduced as-is rather than tightened.

The animator has one trigger, a default state with **no clip** (the closed door is the
rest pose, not an animation), one transition to `puertaAbrir`, and no way back. So the
door opens once and stays open.

`puertaAbrir.anim` is 11 keys at 30 fps over 0.3333 s, rotating only the leaf about Y —
its position and scale curves are constant. Hand-keyed on threes: 0, 10.63, 53.16, 95.69,
106.32 degrees, with values repeating then jumping. Ported as a `rotation_3d` track with
the y component negated, which is the `diag(-1, 1, 1)` conjugation applied to a *rotation*
rather than a position.

Three traps, all of which cost a debugging cycle here:

- **`marquito`'s prefab transform is not the shipped arrangement.** `puertita` agrees
  between prefab and FBX under the usual X negation — Godot `(0.65450, 2.02803, -0.06647)`
  against Unity `(-0.6545, 2.0280, -0.0665)` — but `marquito` does not, and the FBX's own
  value is the right one. Measured, not assumed: with the FBX transform the frame centres
  on the leaf at x = −0.081 against the leaf's −0.079 and encloses it; the conjugated
  prefab value puts it 0.5–0.8 m adrift in three axes. Rendering confirms a leaf sitting
  flush in its frame. **Do not "restore" the prefab value.**
- **Godot's `ROTATION_TRACK_SIZE` is 6, not 5.** A rotation key is `time, transition, x, y,
  z, w`. Writing five floats fails the *whole track* with
  `vcount % ROTATION_TRACK_SIZE`, the animation loads with **no keys at all**, and the door
  dutifully reports itself open without moving. The error goes to stderr among the import
  noise and is easy to miss.
- **The trigger belongs on the root, not the leaf.** Unity's `BoxCollider` (2 × 3.97 × 1,
  centre (0, 2, −0.24), `isTrigger`) was added to the root in the scene, not the prefab.
  Parent it to the leaf and it swings away with the door.

The root of `scenes/puerta_inicio.tscn` deliberately carries **no transform**: the
extractor's world transform already includes the prefab root's 0.5511577 scale, so
`props.tscn` applies it once. The trigger box is therefore in unscaled local space, as
Unity's was, and the instance's scale brings it to size.

`tools/verify_door.gd` checks the leaf is solid and the frame is not (only `puertita` had
a `MeshCollider`), that the trigger is not parented to the leaf, that the door starts
closed, that it ends at **−106.32°**, and that a second trigger does not replay the clip.
The final-angle assertion is deliberately signed: the magnitude comes from the clip and
the sign from the conjugation, and the sign is the part most likely to be wrong.

### The death pose — why dying looked wrong

Not the clip choice. The animator's `death` state really does use `fall.anim`, ours *is*
that clip at the same 0.300 s, and the other similarly named file — `falling.anim` — turns
out to be **empty**: 0 curve paths, referenced by no state. A dead asset, and a red
herring by name.

The cause was **missing data producing a history-dependent pose**. Unity's clips animate
all 43 deformation bones and every animator state has `m_WriteDefaultValues: 1`, so
entering `death` there always produced the same pose. Our imported clips do not:
`animation/remove_immutable_tracks` drops any track that never changes, so bones the clip
holds still have **no track at all** and retain whatever the previous clip left them at.
Measured on the death pose, reached after walking versus after idling:

| bone | difference |
|---|---|
| `Scapula_L` | **45.7°** |
| `MiddleFinger1_L` | 31.9° |
| `Scapula_R` | 25.9° |

A 45.7° scapula moves the whole arm, which is why dying looked wrong in one situation and
fine in another. History dependence is now **0 at 0.04°**.

> **Correction.** The first fix filled the gaps with each bone's **rest** rotation. That
> made the pose deterministic, which cured the reported symptom, but it was not Unity's
> pose: Unity's `Scapula_R` in this clip is **72.7° away from rest**. Rest is only right
> when the missing track was removed for being immutable *and* its constant happened to be
> the rest value, and that assumption was never checked. `tools/restore_clip_bones.gd`
> replaced it, using Unity's own values.

**The conversion is measurable, not guessable.** A Unity bone-local quaternion becomes
`(x, −y, −z, w)` in ours — the same `diag(-1, 1, 1)` conjugation the whole port uses,
expressed on a quaternion. Established by comparing the **35 bones** our `jumpL1Frame`
shares with Unity's, where it reproduces every one (allowing for `q ≡ −q`).
`restore_clip_bones.gd` re-validates it on every shared bone of every clip it touches and
refuses to write if agreement breaks, because a silent coordinate error here would put
limbs in arbitrary places. Worst residual across all nine clips is **2.42°**, on `run`'s
`Hip_R` — a *moving* bone, where `animation/trimming` means our t = 0 is not Unity's first
key. That is why the threshold is 5° rather than a fraction of one: it must clear
legitimate trimming offsets while still catching the 42–72° errors rest-filling produced.

Applied to all nine clips: `fall` +12 bones, `cry` +7, `jumpR1Frame` +41, `jumpL1Frame` +8,
`idle` +4, `jumpL`/`jumpR`/`walk` +1 each, `run` already complete.

Separately, `Die` now **blends over 0.1 s**, which is the `Any State -> death` transition's
`m_TransitionDuration`. The port cut instantly. `Cry` deliberately does not blend — its
transition's duration is 0.

`tools/verify_death_pose.gd` asserts all three: the clip specifies every bone, the pose is
identical from three different prior clips, and the blend matches Unity's transition.
Confirmed to catch the original bug — restoring the pre-fix `fall.res` fails two of its
three checks.

- **Gamepad movement not ported.** `YelenaGamePadMovement` (139 lines) is
  unported; keyboard only for now.
- **Audio is 22.8 MB of WAV for this scene** (27 MB across the project). Worth
  converting to Ogg Vorbis rather than vendoring raw, given the repo already
  avoids large binaries. Done for `susurro_loko` — 2.5 MB to 197 KB at
  `ffmpeg -c:a libvorbis -q:a 5`, same 14.1 s. Note the `.ogg` import defaults to
  `loop=false`, so looping clips need it set and **reimported**: an emitter that
  starts near the end of a non-looping clip stops within a frame or two, which is
  how six of seven whispers can play while one is silent.
- **Unity's sprite pivots are per-file and the used take is not the obvious one.**
  See "Coworkers": the animated frames are `alignment: 7`, BottomCenter, while the
  unused take beside them is centred. Any further sprite work should read the pivot
  from a frame the clip actually names.
- **The falling platforms had a 20 cm reset bug, and the port drops it.**
  `FallingPlatform` captured `platform.position` — a world position — and restored
  it with `platform.localPosition`. Every instance sits under a container called
  `Obstaculos` at (-0.2, 0, 0), so each platform reappeared 20 cm to the -x of
  where it started, once, on its first cycle. The port stores the rest position in
  the space it assigns back to. If the original's exact behaviour is ever wanted,
  this is the divergence to undo.
- **`animation/import=false` is ignored by the FBX importer in 4.7.** Both platform
  models therefore carry an inert `AnimationPlayer` into every instance. Harmless,
  but it means an unused clip is visible on 26 nodes, and it cannot be turned off
  from the `.import` file.
- **Prop collision is per-instance, not per-model, so `addColliders: 0` is a lie
  and `.import` physics is usually the wrong tool.** Every prop `.fbx.meta` has
  `addColliders: 0`, which makes it look like the props carry no collision at all.
  They do: the colliders are `MeshCollider` components added to *instances* in
  `nivelEscena.unity`, hanging off stripped prefab GameObjects that reference the
  model only through `m_Mesh`. All 60 are `m_Convex: 0`, `m_IsTrigger: 0` — concave
  trimesh, solid. Attribute them by walking each collider's GameObject up to its
  owning prefab instance, **not** by counting them per asset: per asset it reads as
  "`table` 5, `pc` 2, `pc2` 2, `book` 2", which invites the wrong fix. Per instance
  it is one thing — **a single `tablePcs` cluster**, the desk beside the player's
  spawn, carrying 11 real colliders (5 table planes, 2 per pc, 2 per pc2, 2 book)
  plus 3 inert `MeshCollider`s with no mesh assigned on the `pc`/`pc2`/`book`
  parents. The other three `tablePcs` clusters and every standalone `table`, `pc`
  and `pc2` instance are walk-through, as are all 24 `silla` and all 21 `puerta`.
  So generating physics in `table.fbx.import` would wrongly solidify nine props.
  Two fixes, chosen by instance count:
  - `piezaParede` has exactly one instance, so its `.import` generates a static
    trimesh body per sub-mesh (`pCube1`–`pCube6`, `pCube21`). Seven
    `_subresources` entries beat a script.
  - `tablePcs` has four instances that disagree, so the cluster root carries
    `PropCollision.cs`, off by default, and `props.tscn` sets
    `GenerateCollision` on the one instance Unity made solid. `SOLID_CLUSTERS` in
    `generate_props_scene.py` keys it by world position and the generator exits
    non-zero if it stops matching.

  Still unported, under "Ending and UI": the 5 colliders on Unity's built-in cube mesh
  belong to the **tutorial key props** (`WASD`, `WASD (1)`, `Spacebar`, `Shift`,
  `Tutorial`). `meta` (2) and `cake` (1) are **done** — see "The ending pair".
- **The two importers disagree by a mirror on X, per model.** Unity's `tablePcs`
  flattens `table.fbx`, so the prefab holds `pPlane23`–`pPlane27` as direct
  children — and their positions are Godot's imported positions with X negated, to
  five decimals on all five planes, with Z identical throughout. `book.fbx`'s two
  children agree the same way. So each model's local space differs between the
  engines by exactly `M = diag(-1, 1, 1)`, and a Unity child transform has to be
  **conjugated, not copied**: `R = M R_u M` (a Y rotation by θ becomes −θ) and
  `p = M p_u`. Copying Unity's numbers straight across mirrors the layout — the
  book lands at +0.542 on a table top spanning [−0.888, +0.667] instead of −0.542,
  and the monitors swap sides. Two consequences: the cluster's table needs **no**
  transform at all, since Godot's `table.fbx` already holds the planes where the
  conjugation puts them; and a model with its own internal chain needs
  `R = M R_u M A⁻¹`, `p = M p_u − R A d`. Only `book.fbx` does: Godot puts a
  −12.521363° Y rotation on an intermediate `libro` node Unity has no node for, and
  Unity's `book` origin sits 0.064442 above `libro`'s. `tools/verify_table_pcs.gd`
  re-derives all of it from the raw prefab numbers and pins both constants, so a
  reimport that changes either fails instead of sliding the book off the desk.
  **Resolved, and it was level-wide.** The mirror applies to `nivel`/`nivel_p2`
  too, so props placed at unmirrored Unity X sat mirrored relative to the shell and
  the whole level was wrong — doors inside walls, coworkers over holes. Fixed by
  conjugating every placement; see "Unity → Godot placement convention" above for
  the evidence and `tools/unity_space.py` for the one place it is applied. The
  `globalScale` groups had nothing to do with it: the mirror is uniform across
  every model in the project.

  Three things did **not** come from the extractors and were conjugated by hand in
  `scenes/level.tscn`: the `Sun`'s basis, the `PointLight`'s X, and the `Shell`'s
  `Obstaculos` offset (−0.2 → +0.2). `ShellP2` and the player start are at X = 0,
  so the conjugation leaves them alone. Anything hand-authored in a scene is
  outside `unity_space.py`'s reach — check for it when adding placements.
- **Two UnityEvent-heavy structures hide from naive greps.** Prefab-instance
  overrides store method names and active flags as `propertyPath`/`value` pairs,
  not as `m_MethodName:` or `m_IsActive:` fields. This already caused one wrong
  conclusion during the GameManager port (the death system looked like dead
  code) and one here (Yelena looked enabled). Any further scene archaeology has
  to read overrides, not just documents.
- **Materials are assigned per renderer-slot, not per material name.** The same
  FBX material resolves differently in different places: `lambert1` is
  `mat_generalTransparencia` on `nivel`'s `pPlane*` meshes but `mat_general` on
  its `polySurface` slot 1, and `nivel_p2` reverses the `polySurface` mapping.
  Godot's importer keys external materials by name and **cannot express this**,
  which is why the shell cannot get its materials from import settings. It did not
  recur on the platforms, whose slot mapping is consistent, so it is a shell
  problem rather than a project-wide one — but it is still worth checking per
  model rather than assuming.

> **Correction, and it shipped a visible bug.** This used to conclude the shell
> therefore "needs `LevelShell.cs` and a data table" — that Godot could not express
> the mapping at all. Wrong, and the correct statement is only slightly narrower:
> the **importer** cannot express it, because it keys by material *name* and there
> are two names for four different (mesh-set, slot) outcomes. The **scene** expresses
> it exactly. `surface_material_override/N` is per mesh *and* per slot, which is
> Unity's own granularity, and setting a property on a child of an instanced scene is
> ordinary `.tscn` syntax. No code was ever required.
>
> The cost: because the materials came from a `[Tool]` C# script, **the level's
> appearance depended on a compiled C# assembly existing.** A collaborator cloned the
> repo and saw the whole level tinted red in the editor while the running game looked
> correct. A fresh clone has neither `.godot/` nor `bin/` — both gitignored — so the
> first editor session has no assembly, no `[Tool]` script runs, and every mesh falls
> back to the FBX's own `lambert1`/`lambert2`. Both of those have
> `vertex_color_use_as_albedo = true`, and the level's vertex colours are **pure red**
> (mean `(0.457, 0.000, 0.000)`, every sampled vertex `(1, 0, 0, 1)`) because that
> channel is *data* for `level_fade.gdshader`'s wobble and alpha, not paint. Albedo ×
> red = a red level. Restarting the editor fixed it, which is the signature of the
> assembly loading at editor start.
>
> Now generated into `level.tscn` by `tools/generate_shell_overrides.gd` — 53 node
> blocks, 73 surfaces — and `LevelShell.cs` is reduced to runtime collision only and
> is no longer `[Tool]`. It was the project's only `[Tool]` script, so this failure
> mode is gone rather than reduced.
>
> Note which check would *not* have caught it: "every surface has the right material"
> passed the entire time, because the verifier always ran with the assembly built.
> `tools/verify_level_shells.gd` now also reads the `PackedScene`'s stored state and
> asserts every surface has its material **before `_ready` runs** — the state the
> editor is in on a fresh clone.
- **One table entry targets a non-mesh node.** Unity had a renderer on `pPlane30`;
  Godot imports it as a plain `Node3D` whose `polySurface*` children hold the
  geometry and their own materials. Harmless, and reported as an informational
  line rather than a warning — but it means 73 of 74 assignments apply.
- **A prefab instance can override a CHILD's transform, and the FBX-instanced shell
  will not have it.** Reported in play as "something is wrong with `nivel_p2`, the
  geometry is not where it should be": a long platform floating in the middle of
  the moving platforms, plus two platforms missing from the end of the level, which
  made it unbeatable. **One cause, both symptoms.** `nivelEscena` moves two of
  `nivel_p2`'s children after instancing it, and instancing the FBX directly gets
  the positions Maya exported instead:

  | mesh | FBX exports it at | `nivelEscena` puts it at |
  | --- | --- | --- |
  | `polySurface16` | (51.791214, 50.000011, 40.291302) | (37.26, 48.98, −0.23) |
  | `polySurface17` | (51.791214, 50.000011, 50.000000) | (−46.13, 50.54, 9.94) |

  Both slabs were 40 m further along +Z than they belong — present where nothing
  should be, absent where the player needs them. Note the node positions say almost
  nothing about where the geometry lands: these meshes' vertices carry a large baked
  offset, so the actual footprints move from world x ≈ 0, z ≈ −113 (dead centre of
  the platform run, which spans z −132…−18, and 1 m higher — exactly "slightly high
  up, in the middle of the platforms") to z ≈ −154…−157 with their tops at y ≈ 3–4.5,
  past the end of the run at ground level. Fixed as node overrides on the instance in
  `level.tscn`; `tools/verify_level_shells.gd` now requires every one of the 53 shell
  meshes to be at the FBX's transform *except* these two, so a reimport that
  renumbers children cannot move the overrides onto the wrong meshes.

  `nivel`'s instance carries overrides too, but every one of them is inert:
  `m_RootOrder` and `m_StaticEditorFlags` (neither places geometry), plus a
  `m_LocalPosition` on `mesa` and an `m_Enabled` on `pPlane20`, which are objects only
  an **older export** of `nivel.fbx` contained. They are dead in Unity as well.

> **Correction.** While diagnosing the above I also reported that four `nivel_p2`
> materials were wrong — `polySurface17`/`18` painted opaque and `polySurface30`/`31`
> painted transparent. **That was not a real bug.** It came from my own bad mapping of
> Unity's renderer fileIDs to mesh names. I had assumed `2300000 + 2j` indexes the FBX's
> **Model record order**; it does not. Unity's renderer order for `nivel_p2` is
> `polySurface6, 10, 11, … 31, 7, 9, 32, 34` — Maya's export order and Unity's import
> order disagree, and 7 and 9 land at the *end*. Regenerating the table from the correct
> mapping reproduces the shipped `level_materials.json` **exactly, all 74 entries across
> both shells**. The materials were right all along.
>
> The authority for the mapping is the FBX's **`.meta` file**, which carries a
> `fileIDToRecycleName:` table naming the object behind every fileID Unity minted. Two
> cautions: it is a *recycle* table, so it retains names from earlier exports —
> `nivel.fbx`'s lists 53 renderers where the current FBX has 27 — so its size says
> nothing about what the FBX contains; and a retained fileID stays bound to its old
> name, which is how `mesa` above was identified as gone rather than renamed.
>
> The mapping is now cross-checked against something it cannot influence: a mesh has a
> second material slot only if it has a second submesh, so the names carrying a slot 1
> must be exactly the meshes Godot imports with 2 surfaces. They are — 6 for `nivel`,
> 14 for `nivel_p2`. The Model-order guess fails this check, which is what exposed it.
> `tools/extract_level_materials.py` regenerates the table; it had no generator in the
> repo before, so it could not be re-derived or audited at all.
