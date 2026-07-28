# The First Day — Godot port

Port of *The First Day* (originally `AsylumJam2016`), a game made in Unity 5.4 for
Asylum Jam 2016, rebuilt in **Godot 4.7 with C# (.NET)**.

The original Unity source lives in a sibling repository and is used as the reference
for behaviour, level layout and assets.

## Requirements

- **Godot 4.7.x — .NET / Mono build** (`godot-mono`)
- **.NET SDK 8.0** (the project targets `net8.0`)

## Getting started

```bash
godot-mono --editor --path .
```

To build the C# assembly from the command line:

```bash
dotnet build TheFirstDay.sln
```

## Layout

```
assets/     art, audio, models and materials imported from the Unity project
scenes/     Godot scenes (.tscn)
scripts/    C# gameplay code
shaders/    .gdshader files
```

## Porting notes

- Original engine: Unity 5.4.2f2. Original scenes: `Main Menu.unity`, `nivelEscena.unity`.
- Input actions in `project.godot` mirror the original Unity input axes
  (`keyboard_up/down/left/right`, `keyboard_jump`, `keyboard_run`, `keyboard_attack`,
  `keyboard_attack2`) with gamepad bindings alongside.
- The original had a WebGL build. Godot's .NET web export is still experimental, so a
  browser build is not guaranteed to be a like-for-like replacement.
