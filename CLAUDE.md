# The First Day — working conventions

Port of *The First Day* (Unity 5.4, Asylum Jam 2016) to Godot 4.7 + C#/.NET 8.

## Do not put explanatory comments in Godot files

**No `;` comments in `.tscn`, `.tres` or `.import` files.** They do not survive, and
losing them is silent:

- A Godot **editor save** strips every `;` comment from a scene or resource.
- So does any `ResourceSaver.save()` — including
  `addons/godot_mcp_toolkit/commands/audiobus_commands.gd:264`, which rewrites
  `default_bus_layout.tres`.

Comments there are write-only memory. **`python3 tools/verify_no_resource_comments.py` enforces
this** (`--fix` strips them); the 618 lines that used to be in those files are already migrated.
Put the knowledge where it survives instead:

| what | where |
|---|---|
| Why a value is what it is; measurements; corrections | `docs/level-port-scope.md` — the port's ledger |
| Rules that must not be forgotten while working | this file |
| General Unity→Godot method and traps | `~/.claude/skills/unity-to-godot-port/` |

**The one exception, and it is not documentation.** `scenes/level.tscn` carries

```
; >>> BEGIN generated shell overrides - tools/generate_shell_overrides.gd
; <<< END generated shell overrides
```

`tools/generate_shell_overrides.gd` finds its region by these two lines and **refuses
to run** if it sees overrides without them (`:207-222`). If an editor save strips
them, `git checkout -- scenes/level.tscn` puts them back. Never delete them as
"comments" — the guard above knows to keep them.

**Generators must not write comments either**, or the migration undoes itself on the next run.
`bake_hammer_swing.py`, `pack_coworker_sprites.py`, `generate_zones_scene.py`,
`generate_whispers_scene.py` and `generate_shell_overrides.gd` all used to; each now reports the
same facts to **stdout**, which is where per-run output belongs.

## Rules that bite

- **`scenes/level.tscn` needs its two `[editable]` lines.** Godot's loader applies a
  material override on a child of an instanced sub-scene; its packer discards it unless
  the instance is marked editable. Without `[editable path="Shell/nivel"]` and
  `[editable path="ShellP2/nivel_p2"]`, the first save silently drops all 73
  `surface_material_override` blocks and the level renders red. Guarded by
  `tools/verify_scene_survives_save.gd`.
- **Positions convert as `M = diag(-1, 1, 1)`** — X negates, Y and Z do not. Applied in
  exactly one place, `tools/unity_space.py`. Do not apply it twice, and remember anything
  hand-authored in a `.tscn` is outside its reach.
- **The mix's balance is set in `default_bus_layout.tres`, not in the emitters.**
  `Fortunato` is deliberately +9.5 dB where Unity's mixer said +20 (which clipped). If the
  whispers need changing, change that bus — not `WhisperEmitter.OnsetVolumeDb`, which was
  tuned by ear. Full reasoning under "The footsteps were clipping" in the ledger.
- **A change is not done until its verifier passes.** `tools/verify_*.gd` are the port's
  memory of every bug already fixed; adding to them is part of the work.

## Commands

```bash
dotnet build TheFirstDay.sln                                    # C# assembly
godot-mono --editor --path .                                    # editor
godot-mono --headless --path . --script tools/verify_x.gd       # headless check
xvfb-run -a godot-mono --path . --script tools/verify_x.gd      # checks that render
python3 tools/verify_resource_uids.py                           # python checks
```
