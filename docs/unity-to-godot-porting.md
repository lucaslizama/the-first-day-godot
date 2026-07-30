# Porting Unity → Godot: where the reusable knowledge lives

The general method, traps and tooling from this port have been extracted into a
user-level skill so a future port — of this game or another — does not have to
rediscover them:

    ~/.claude/skills/unity-to-godot-port/
      SKILL.md                       the method, and the order to work in
      references/
        axis-conventions.md          resolving the mirror; two proofs; the algebra
        unity-yaml.md                scene/prefab archaeology; what greps miss
        godot-import.md              .import, materials, collision, Transform3D
        verification.md              headless verification; independent re-derivation
      scripts/
        unity_space.py               generic axis conjugation, configurable
        check_axes.gd                statistical axis-convention prober

It is a Claude Code skill, so an agent working on any Unity→Godot task picks it up
automatically from its description; no need to point at this file. It is
project-agnostic on purpose — no reference to this game's assets.

## What is general vs what is here

**In the skill** — anything true of Unity→Godot ports in general:

- Measure axis conventions; never reason about them from handedness. Both proof
  methods, and the conjugation algebra for positions, rotations and scales.
- Unity YAML: stripped GameObjects, `propertyPath` overrides invisible to greps,
  per-instance rather than per-asset attribution, `addColliders: 0` being a lie.
- Godot: `Transform3D`'s row-major constructor, `.import` `_subresources`,
  per-instance vs per-model collision, trimesh one-sidedness, importer quirks.
- The extract → JSON → generate → verify pipeline, and the guard rails
  (position-keyed flags, loud count mismatches, pinned measured constants).

**Here, in `docs/level-port-scope.md`** — anything specific to *this* game: the
`diag(-1, 1, 1)` result for these files, the level's inventory and prefab counts,
the material slot table, the specific models, shaders, animation clips and audio,
and the per-instance collision map. That document is the port's ledger, including
its corrections; this file is only a pointer.

## The project's own copies

`tools/unity_space.py` here is the project-specific instance of the skill's script:
same rule, but with this project's exact key names, so an unclassified new field
raises. `tools/check_mirror.gd` is the project-specific prober; the skill's
`check_axes.gd` is the same idea with the scene and group names as arguments.

If you improve either here, consider whether the improvement is general and belongs
back in the skill.

## Write back what you learn

The skill has a "Keep this skill current" section instructing whoever uses it to add
new general knowledge to it before finishing a task, correct anything in it that turns
out to be wrong, and port improved scripts back genericised. So the expectation runs
both ways: read it at the start of porting work, and update it at the end.

The split to apply when deciding where something goes: **general → the skill,
this-game-specific → `docs/level-port-scope.md`.** A finding about how Unity writes
prefab overrides is general. The fact that *this* project's mirror is
`diag(-1, 1, 1)` is not.

## The two most expensive lessons, in short

1. **`X` is negated, `Y` and `Z` are not.** Believing "positions transfer unchanged"
   put every prop, coworker, platform and zone in the wrong place, and it survived
   review because the level stayed internally plausible — just mirrored relative to
   the shell. Doors inside walls and coworkers over holes were the symptom.
2. **A symptom you cannot explain is a bug, not a property.** This doc once recorded
   "only 10 of 74 coworkers have anything beneath them" and rationalised it as
   background figures in open space. It was lesson 1. After the fix, 50 of 74.
