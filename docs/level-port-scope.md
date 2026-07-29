# Level port scope — `nivelEscena.unity`

Recon of the Unity level, to size the remaining work. Every number here was read
out of the project, not estimated. Source: `../the-first-day-unity`.

## What the level actually is

A **corridor**, not an open space:

| | |
|---|---|
| World extents | x `-0.3 … 8.4`, y `-0.3 … 2.8`, z `-67.2 … 3.9` |
| Span | **8.7 × 3.2 × 71.1 m** |
| Root objects | 11 |

Almost all of it runs along −Z. That shape matters more than any other fact
here: it means the level can be ported and tested in **slices along Z**, one
checkpoint stretch at a time, with the sandbox scene as the harness. Nothing
requires the whole level standing up before any of it is playable.

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
| ParticleSystem | 1 |
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

`nivel.fbx` + `nivel_p2.fbx` are the level shell. `Yelena` is the **disabled**
leftover prototype — do not port it. Its `m_IsActive: 0` is a prefab-instance
override rather than a field on a GameObject document, so it is invisible to a
naive scan of the scene; confirmed against prefab guid `65a06b95…`.

### Assets

| Kind | Count | Weight |
|---|---|---|
| Level FBX models | 13 | **936 KB total** |
| Coworker sprite frames | 153 (mono1) + 70 (mono2) | **19 MB** |
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

## Remaining work

### 1. Materials and shaders

Three ShaderLab shaders still to port, following the method proven on
Fortunato (gamma-space math, `LIGHT_COLOR / PI`, `ALBEDO = vec3(1.0)`):

| Shader | Used by | Refs |
|---|---|---|
| `shader_generalTransparencia` | `mat_generalTransparencia` | **57** |
| `shader_general` | `mat_general` | 27 |
| `shader_torta` | `mat_torta` | 1 |
| `shader_fade` | UI fade | — |
| skybox | `mat_skyboxFernandito` | 1 |

Plus `MAT_Platic`, `MAT_Screen`, `lambert2`, `lambert3` (likely plain
`StandardMaterial3D`), and four tutorial-key materials (`wasd`, `space_key_l`,
`shift_key`, `controller`).

`mat_generalTransparencia` at 57 references is the single most impactful
material in the level — worth doing first and doing right.

### 2. Gameplay scripts — 557 lines across 16 files

Everything left is small. Largest is 78 lines.

| Lines | Script | Instances | Notes |
|---|---|---|---|
| 78 | `Fortunato.cs` | 1 | `Die`/`Revive`; blocks the respawn chain |
| 55 | `FadeUI.cs` | — | overlaps the ported `FadeOverlay` |
| 51 | `ParentPlayer.cs` | — | moving-platform parenting |
| 50 | `FallingPlatform.cs` | 8 | |
| 43 | `TriggerZone.cs` | 2 | enter/exit/stay UnityEvents |
| 39 | `SoundAttenuationByDeath.cs` | **11** | consumes `GameManager.DeathConstant` |
| 34 | `Credits.cs` | 1 | |
| 31 | `FortunatoAnimFunctions.cs` | — | the missing animation events |
| 30 | `TimerZone.cs` | 1 | |
| 30 | `PauseMenu.cs` | — | |
| 24 | `RandomizeMonoAnimStart.cs` | **32** | |
| 23 | `YBillboardFollow.cs` | **31** | → Godot billboard mode, near-free |
| 23 | `Door.cs` | 1 | |
| 20 | `CamControllerFunctionAccess.cs` | 1 | |
| 19 | `ResetLocalPosition.cs` | 1 | |
| 7 | `UnityEventContainer.cs` | 1 | |

### 3. The coworkers are 2D sprites

31 `SpriteRenderer`s + 31 `YBillboardFollow` + 32 `RandomizeMonoAnimStart` +
223 PNG frames + 2 animation controllers. The coworkers are **billboarded
sprite-sheet animations**, not 3D models. In Godot that's `Sprite3D` with
`billboard = enabled` and either `SpriteFrames` or a shader-driven atlas —
`YBillboardFollow` becomes a property rather than a script.

19 MB of individually-imported PNG frames is worth packing into atlases during
the port rather than after.

### 4. Not needed

- `Antialiasing.cs` — Godot has MSAA (already `msaa_3d=2`) and FXAA built in.
- `VignetteAndChromaticAberration` — **done**, see `shaders/death_distortion.gdshader`.
- `EventSystem` — the unresolved script guid `f5f67c52…` is Unity's built-in
  `UnityEngine.UI` assembly, not project code. Godot's `Control` system covers it.
- `Yelena.prefab` — disabled in the scene.

## Suggested order

1. **`shader_general` + `shader_generalTransparencia`** — 84 of the level's
   material references; nothing looks right until these exist.
2. **Level shell** — `nivel.fbx` + `nivel_p2.fbx` with the 60 mesh colliders,
   into a level scene, tested with the existing player.
3. **Static props** — chairs, doors, tables, PCs. Bulk instancing, low risk.
4. **Platforms** — `plataforma_prefab` (18) and `plataformaCae` (8) plus
   `ParentPlayer`/`FallingPlatform`. First real gameplay work.
5. **Coworkers** — sprite atlases, billboards, `RandomizeMonoAnimStart`, and
   `SoundAttenuationByDeath`, which closes the death-constant loop already
   built in `GameManager`.
6. **Hazards and the respawn chain** — hammers, `Fortunato.Die`/`Revive`,
   `FortunatoAnimFunctions` animation events, wiring `CheckpointTeleport`
   through the fade. This completes what the GameManager port deliberately left
   open.
7. **Ending and UI** — `meta.fbx`, cake, confetti, `Credits`, `PauseMenu`,
   `TimerZone`.

Steps 2–4 are mostly mechanical volume. Steps 5–6 are where the real
behavioural work is.

## Risks and open questions

- **`respawnDelay` is unread.** Confirmed in the Unity source; the actual delay
  is the fade duration. Timing has to be recovered from the fade, not the field.
- **Animation events are missing.** `PlayStepSound`, `RandomizePitch`,
  `SetLeftJump`/`SetRightJump`, `Die`, `Cry` were Unity animation events and did
  not survive the FBX clip extraction. They need re-adding as Godot method
  tracks — `PlayerCharacter` currently alternates jump feet in code as a
  stand-in.
- **`damage` and `death` animator states have no clips** anywhere in the
  project, in FBX or `.anim` form. Nothing to port; `Fortunato.Die` will need a
  substitute.
- **`jumpR1Frame` is a degenerate export** — 23 tracks (2 skeletal) against
  `jumpL1Frame`'s 221. A pre-existing defect in the jam project, not caused by
  the rig strip.
- **Gamepad movement not ported.** `YelenaGamePadMovement` (139 lines) is
  unported; keyboard only for now.
- **Audio is 22.8 MB of WAV for this scene** (27 MB across the project). Worth
  converting to Ogg Vorbis rather than vendoring raw, given the repo already
  avoids large binaries.
- **Two UnityEvent-heavy structures hide from naive greps.** Prefab-instance
  overrides store method names and active flags as `propertyPath`/`value` pairs,
  not as `m_MethodName:` or `m_IsActive:` fields. This already caused one wrong
  conclusion during the GameManager port (the death system looked like dead
  code) and one here (Yelena looked enabled). Any further scene archaeology has
  to read overrides, not just documents.
