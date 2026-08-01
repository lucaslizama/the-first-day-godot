using System.Collections.Generic;
using Godot;

namespace TheFirstDay.Utils;

/// <summary>
/// Player settings, persisted to <c>user://settings.cfg</c>.
///
/// A DELIBERATE ADDITION. The 2016 original had no options screen, no volume control and no
/// remapping - it used no PlayerPrefs at all - and this port had no ConfigFile and no user://
/// write anywhere in scripts/ before this. So there is nothing here to be faithful to, and every
/// decision below is a decision rather than a reproduction. The reasoning lives in
/// docs/level-port-scope.md under "Deliberate additions (not in the original)".
///
/// Two rules shape the whole class:
///
/// EVERY DEFAULT REPRODUCES THE SHIPPED 1.0.0 BUILD EXACTLY. A player who never opens the options
/// screen, and a machine with no settings.cfg, must get the game as tagged. That is why the
/// volumes are offsets rather than absolute levels, why the sensitivities are multipliers of the
/// camera's own exported values, and why the video defaults restate project.godot's.
///
/// MUTATION HAS ONE EXIT, <see cref="MarkChanged"/>. The UI writes a property and calls it; it
/// applies, schedules the save and emits. Nothing else may apply or save, so "someone changed a
/// setting and forgot to persist it" is not a reachable bug.
/// </summary>
public partial class GameSettings : Node
{
    /// <summary>
    /// Bumped when the file layout changes in a way that old files cannot be read as. Stored so a
    /// future version can migrate rather than guess; nothing reads it yet beyond the round trip.
    /// </summary>
    public const int FormatVersion = 1;

    private const string SectionMeta = "meta";
    private const string SectionGame = "game";
    private const string SectionAudio = "audio";
    private const string SectionVideo = "video";
    private const string SectionInput = "input";

    /// <summary>Seconds of quiet after the last change before the file is written.</summary>
    private const double SaveDebounceSeconds = 0.5;

    /// <summary>
    /// The floor a volume slider may attenuate to before it becomes a mute instead. Matches
    /// WhisperEmitter's SilenceDb, which is the value this project already means by "silent".
    /// </summary>
    private const float SilenceDb = -80.0f;

    public static GameSettings? Instance { get; private set; }

    /// <summary>
    /// Which group of settings changed. Consumers filter on it so a volume slider does not make
    /// every camera in the tree recompute its sensitivity.
    /// </summary>
    public enum Section
    {
        Game,
        Audio,
        Video,
        Input,
    }

    /// <summary>Keyboard-and-mouse, or gamepad. A rebind only ever replaces its own family.</summary>
    public enum BindingFamily
    {
        KeyboardMouse,
        Gamepad,
    }

    /// <summary>Emitted after a section has been applied. The argument is a <see cref="Section"/>.</summary>
    [Signal]
    public delegate void SectionChangedEventHandler(int section);

    /// <summary>
    /// Settable, and that is the point: a verifier points it at a scratch file so a headless run
    /// can exercise the real save path without clobbering the developer's own settings.
    /// </summary>
    public string ConfigPath { get; set; } = "user://settings.cfg";

    // ---------------------------------------------------------------- Game

    /// <summary>
    /// MULTIPLIERS, not absolute rates. ThirdPersonCamera.SensitivityHorizontal = 2.0f stays the
    /// single written-down definition of the ported feel; this scales it. Storing an absolute 2.0
    /// here would fork that number into two places, and a later correction to the camera's export
    /// would then silently not reach anybody who had ever opened the options screen.
    /// </summary>
    public float LookSensitivityX
    {
        get => _lookSensitivityX;
        set => _lookSensitivityX = Mathf.Clamp(value, MinSensitivity, MaxSensitivity);
    }

    /// <inheritdoc cref="LookSensitivityX"/>
    public float LookSensitivityY
    {
        get => _lookSensitivityY;
        set => _lookSensitivityY = Mathf.Clamp(value, MinSensitivity, MaxSensitivity);
    }

    /// <summary>
    /// Flips the vertical look. false is the shipped value, and note that this is NOT Unity's flag:
    /// see the long note on ThirdPersonCamera.InvertVertical for why copying that flag across
    /// produced aeroplane controls.
    /// </summary>
    public bool InvertLookY { get; set; }

    /// <summary>Flips the horizontal look. No such control existed before; the field is new.</summary>
    public bool InvertLookX { get; set; }

    /// <summary>
    /// Vertical field of view in degrees. 75 is Camera3D's own default, which is what both cameras
    /// in the project run at today because nothing sets fov anywhere - so 75 is "the shipped look".
    /// </summary>
    public float FieldOfView
    {
        get => _fieldOfView;
        set => _fieldOfView = Mathf.Clamp(value, MinFieldOfView, MaxFieldOfView);
    }

    /// <summary>
    /// How much of the death distortion to apply, 0..1. Scales the DEATH-DRIVEN RANGE ONLY, never
    /// the resting values, so at 1.0 the screen is bit-identical to the shipped build and at 0.0 it
    /// sits at its resting look and stops escalating as the player dies.
    ///
    /// A slider rather than an on/off switch because that escalation is the game's central feedback
    /// loop - the screen smearing and the voices closing in ARE the horror - and a binary off is a
    /// blunter instrument than most players reaching for this actually want.
    /// </summary>
    public float ScreenEffects
    {
        get => _screenEffects;
        set => _screenEffects = Mathf.Clamp(value, 0.0f, 1.0f);
    }

    /// <summary>
    /// The ranges the stored values are held to.
    ///
    /// CLAMPED ON WRITE, not only when read back off disk. The options screen's sliders carry their
    /// own min/max IN THE SCENE FILE so a designer can retune them in the editor without touching
    /// C# - which means the UI is no longer the thing that guarantees a sane value. Widening the FOV
    /// slider to 500 in the editor now produces a clamped 110 rather than a stored 500 that
    /// silently became 110 on the next load.
    /// </summary>
    public const float MinSensitivity = 0.25f;

    /// <inheritdoc cref="MinSensitivity"/>
    public const float MaxSensitivity = 3.0f;

    /// <inheritdoc cref="MinSensitivity"/>
    public const float MinFieldOfView = 60.0f;

    /// <inheritdoc cref="MinSensitivity"/>
    public const float MaxFieldOfView = 110.0f;

    private float _lookSensitivityX = 1.0f;
    private float _lookSensitivityY = 1.0f;
    private float _fieldOfView = 75.0f;
    private float _screenEffects = 1.0f;

    // --------------------------------------------------------------- Audio

    /// <summary>
    /// The buses a player may attenuate, paired with the config key that stores each. Looked up BY
    /// NAME, never by index: an index would quietly address the wrong bus if default_bus_layout.tres
    /// were ever reordered.
    ///
    /// Labels on screen are Master / Music / Ambience / Whispers / Footsteps - "Coworkers" and
    /// "Fortunato" are the mix's names for them and mean nothing to a player.
    /// </summary>
    private static readonly (string Key, StringName Bus)[] Buses =
    {
        ("master", "Master"),
        ("music", "Music"),
        ("ambience", "Ambience"),
        ("whispers", "Coworkers"),
        ("footsteps", "Fortunato"),
    };

    /// <summary>Linear amplitude 0..1 per bus, keyed by the config key in <see cref="Buses"/>.</summary>
    private readonly Dictionary<string, float> _volumes = new();

    /// <summary>
    /// Each bus's dB as default_bus_layout.tres authored it, snapshotted before anything is applied.
    ///
    /// THIS IS WHAT MAKES THE SLIDERS SAFE. CLAUDE.md is explicit that the mix's balance lives in
    /// the bus layout and not in the emitters - Fortunato is deliberately +9.5 dB where Unity's
    /// mixer said +20, which clipped the master by 7.5 dB - and tools/verify_music.gd asserts all
    /// five values. A slider that SET a bus would overwrite that tuning; a slider that offsets it
    /// cannot, and at 1.0 the offset is exactly 0 dB so the shipped mix is reproduced to the
    /// decimal. Nothing here ever writes back to default_bus_layout.tres.
    /// </summary>
    private readonly Dictionary<StringName, float> _authoredBusDb = new();

    // --------------------------------------------------------------- Video

    /// <summary>Window modes offered, in the order the OptionButton lists them.</summary>
    private static readonly DisplayServer.WindowMode[] WindowModes =
    {
        DisplayServer.WindowMode.Windowed,
        DisplayServer.WindowMode.Maximized,
        DisplayServer.WindowMode.Fullscreen,
    };

    private static readonly DisplayServer.VSyncMode[] VSyncModes =
    {
        DisplayServer.VSyncMode.Disabled,
        DisplayServer.VSyncMode.Enabled,
        DisplayServer.VSyncMode.Adaptive,
    };

    private static readonly Viewport.Msaa[] MsaaModes =
    {
        Viewport.Msaa.Disabled,
        Viewport.Msaa.Msaa2X,
        Viewport.Msaa.Msaa4X,
        Viewport.Msaa.Msaa8X,
    };

    /// <summary>0 means unlimited, which is Engine.MaxFps's own meaning for it.</summary>
    private static readonly int[] FpsCaps = { 0, 30, 60, 120, 144 };

    /// <summary>Index into <see cref="WindowModes"/>. 1 is Maximized, matching window/size/mode=2.</summary>
    public int WindowModeIndex { get; set; } = 1;

    /// <summary>
    /// Index into <see cref="VSyncModes"/>. 1 is Enabled, which is the engine default - project.godot
    /// carries no vsync key at all, so "the shipped behaviour" is the engine's.
    /// </summary>
    public int VSyncIndex { get; set; } = 1;

    /// <summary>Index into <see cref="MsaaModes"/>. 2 is 4x, matching anti_aliasing/quality/msaa_3d=2.</summary>
    public int MsaaIndex { get; set; } = 2;

    /// <summary>Index into <see cref="FpsCaps"/>. 0 is unlimited.</summary>
    public int MaxFpsIndex { get; set; }

    // --------------------------------------------------------------- Input

    /// <summary>
    /// The actions the options screen offers, in the order it lists them.
    ///
    /// attack_alt IS DELIBERATELY ABSENT. project.godot binds it to right-click and gamepad B, and
    /// no script in the project reads it - grep for it and the only hits are project.godot itself.
    /// Offering a row that rebinds nothing would be a lie, so it is left bound and unlisted.
    /// </summary>
    public static readonly string[] RemappableActions =
    {
        "move_forward",
        "move_back",
        "move_left",
        "move_right",
        "jump",
        "run",
        "attack",
        "pause",
    };

    /// <summary>
    /// Every remappable action's events exactly as project.godot shipped them, duplicated so
    /// nothing downstream can mutate them, and captured BEFORE any override is applied.
    ///
    /// project.godot therefore stays the only place the default bindings are written down. A
    /// hand-copied table in C# would be a second definition, and the two would drift the first time
    /// somebody retuned a deadzone.
    /// </summary>
    private readonly Dictionary<string, List<InputEvent>> _defaultEvents = new();

    /// <summary>Overrides, keyed "&lt;action&gt;/&lt;family&gt;". Absent means "use the default".</summary>
    private readonly Dictionary<string, InputEvent> _bindingOverrides = new();

    // ---------------------------------------------------------------- State

    private Timer _saveTimer = null!;
    private bool _dirty;

    public override void _EnterTree()
    {
        Instance = this;

        // The debounce timer below must keep ticking while the tree is paused, because the options
        // screen is reachable from the pause menu and a paused Timer never fires - the same trap
        // PauseMenu and FadeOverlay already carry notes about.
        ProcessMode = ProcessModeEnum.Always;
    }

    public override void _ExitTree()
    {
        FlushIfDirty();

        if (Instance == this)
        {
            Instance = null;
        }
    }

    public override void _Ready()
    {
        _saveTimer = new Timer
        {
            Name = "SaveDebounce",
            OneShot = true,
            ProcessMode = ProcessModeEnum.Always,
        };
        _saveTimer.Timeout += FlushIfDirty;
        AddChild(_saveTimer);

        SnapshotAuthoredState();

        // NOTHING IS LOADED OR APPLIED UNDER --script, AND THAT IS LOAD-BEARING.
        //
        // Autoloads DO instantiate when --script replaces the main loop - measured, not assumed:
        // a probe run of `godot-mono --headless --path . --script ...` printed MCPRuntimeServer,
        // PlayerInput and GameManager as children of root, and reported "--script" present in
        // OS.get_cmdline_args().
        //
        // Which means that without this guard, every headless verifier would run against whatever
        // the developer last set in their own user://settings.cfg. tools/verify_music.gd asserts
        // the five bus levels to the decimal, so a music slider left at 60% would fail it for a
        // reason that has nothing to do with the code under test - the worst kind of red build.
        // The snapshot above still happens, so an instance found this way is usable; the verifiers
        // that do want to exercise this class point ConfigPath at a scratch file and call Load()
        // themselves.
        if (IsToolRun())
        {
            return;
        }

        Load();
    }

    /// <summary>
    /// True when the engine was started with a script as its main loop, i.e. this is one of
    /// tools/verify_*.gd rather than the game. See the note in <see cref="_Ready"/>.
    /// </summary>
    public static bool IsToolRun()
    {
        foreach (string arg in OS.GetCmdlineArgs())
        {
            if (arg == "--script" || arg == "-s")
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Records the pristine engine state the defaults are expressed relative to: each bus's
    /// authored dB, and each remappable action's shipped events. Both are read from state the
    /// engine has already set up from default_bus_layout.tres and project.godot, so this must run
    /// before anything is applied - and it must not depend on the config file existing.
    /// </summary>
    private void SnapshotAuthoredState()
    {
        foreach ((string key, StringName bus) in Buses)
        {
            _volumes[key] = 1.0f;

            int index = AudioServer.GetBusIndex(bus);
            if (index < 0)
            {
                GD.PushError($"{Name}: no audio bus named '{bus}'; its volume slider will do nothing.");
                continue;
            }

            _authoredBusDb[bus] = AudioServer.GetBusVolumeDb(index);
        }

        foreach (string action in RemappableActions)
        {
            if (!InputMap.HasAction(action))
            {
                GD.PushError($"{Name}: project.godot has no action '{action}'; it cannot be remapped.");
                continue;
            }

            List<InputEvent> events = new();
            foreach (InputEvent shipped in InputMap.ActionGetEvents(action))
            {
                events.Add((InputEvent)shipped.Duplicate(true));
            }

            _defaultEvents[action] = events;
        }
    }

    // ------------------------------------------------------- Read and write

    /// <summary>
    /// Reads <see cref="ConfigPath"/> and applies everything. A missing file is the normal first
    /// run, not an error, and every individual read falls back to its default - so a truncated or
    /// hand-mangled file yields a playable game at the shipped settings rather than a crash or a
    /// silent mix.
    /// </summary>
    public void Load()
    {
        ConfigFile config = new();
        Error error = config.Load(ConfigPath);

        if (error == Error.FileNotFound)
        {
            ApplyAll();
            return;
        }

        if (error != Error.Ok)
        {
            GD.PushWarning($"{Name}: could not read '{ConfigPath}' ({error}); using defaults.");
            ApplyAll();
            return;
        }

        LookSensitivityX = ReadFloat(config, SectionGame, "look_sensitivity_x", 1.0f, MinSensitivity, MaxSensitivity);
        LookSensitivityY = ReadFloat(config, SectionGame, "look_sensitivity_y", 1.0f, MinSensitivity, MaxSensitivity);
        InvertLookY = config.GetValue(SectionGame, "invert_look_y", false).AsBool();
        InvertLookX = config.GetValue(SectionGame, "invert_look_x", false).AsBool();
        FieldOfView = ReadFloat(config, SectionGame, "field_of_view", 75.0f, MinFieldOfView, MaxFieldOfView);
        ScreenEffects = ReadFloat(config, SectionGame, "screen_effects", 1.0f, 0.0f, 1.0f);

        foreach ((string key, StringName _) in Buses)
        {
            _volumes[key] = ReadFloat(config, SectionAudio, key, 1.0f, 0.0f, 1.0f);
        }

        WindowModeIndex = ReadIndex(config, SectionVideo, "window_mode", 1, WindowModes.Length);
        VSyncIndex = ReadIndex(config, SectionVideo, "vsync", 1, VSyncModes.Length);
        MsaaIndex = ReadIndex(config, SectionVideo, "msaa", 2, MsaaModes.Length);
        MaxFpsIndex = ReadIndex(config, SectionVideo, "max_fps", 0, FpsCaps.Length);

        LoadBindings(config);

        ApplyAll();
    }

    /// <summary>Writes every section to <see cref="ConfigPath"/>. Idempotent.</summary>
    public void Save()
    {
        ConfigFile config = new();

        config.SetValue(SectionMeta, "format_version", FormatVersion);

        config.SetValue(SectionGame, "look_sensitivity_x", LookSensitivityX);
        config.SetValue(SectionGame, "look_sensitivity_y", LookSensitivityY);
        config.SetValue(SectionGame, "invert_look_y", InvertLookY);
        config.SetValue(SectionGame, "invert_look_x", InvertLookX);
        config.SetValue(SectionGame, "field_of_view", FieldOfView);
        config.SetValue(SectionGame, "screen_effects", ScreenEffects);

        foreach ((string key, StringName _) in Buses)
        {
            config.SetValue(SectionAudio, key, _volumes[key]);
        }

        config.SetValue(SectionVideo, "window_mode", WindowModeIndex);
        config.SetValue(SectionVideo, "vsync", VSyncIndex);
        config.SetValue(SectionVideo, "msaa", MsaaIndex);
        config.SetValue(SectionVideo, "max_fps", MaxFpsIndex);

        // Only overrides are written. An action the player never touched has no key at all, so the
        // defaults keep coming from project.godot even for a file written by an older build.
        foreach (KeyValuePair<string, InputEvent> pair in _bindingOverrides)
        {
            string? token = EncodeBinding(pair.Value);
            if (token is not null)
            {
                config.SetValue(SectionInput, pair.Key, token);
            }
        }

        Error error = config.Save(ConfigPath);
        if (error != Error.Ok)
        {
            GD.PushError($"{Name}: could not write '{ConfigPath}' ({error}); settings will not persist.");
            return;
        }

        _dirty = false;
    }

    /// <summary>
    /// The one way a changed setting reaches the engine and the disk. Applies immediately so the
    /// player hears and sees the change while dragging, and restarts a short debounce rather than
    /// writing a file per pixel of slider travel.
    /// </summary>
    public void MarkChanged(Section section)
    {
        ApplySection(section);
        _dirty = true;
        _saveTimer.Start(SaveDebounceSeconds);
        EmitSignal(SignalName.SectionChanged, (int)section);
    }

    /// <summary>Writes now if anything is pending. Called on the ways out, and by the debounce.</summary>
    public void FlushIfDirty()
    {
        if (_dirty)
        {
            Save();
        }
    }

    public void ApplyAll()
    {
        foreach (Section section in new[] { Section.Game, Section.Audio, Section.Video, Section.Input })
        {
            ApplySection(section);
            EmitSignal(SignalName.SectionChanged, (int)section);
        }
    }

    /// <summary>
    /// Pushes one section into the engine. Game is absent on purpose: nothing global owns
    /// sensitivity, FOV or the distortion strength - the per-scene nodes that do pull them in their
    /// own _Ready and on <see cref="SectionChanged"/>, the same shape DeathDistortion already uses
    /// for GameManager.DeathConstantChanged.
    /// </summary>
    public void ApplySection(Section section)
    {
        switch (section)
        {
            case Section.Audio:
                ApplyAudio();
                break;
            case Section.Video:
                ApplyVideo();
                break;
            case Section.Input:
                ApplyBindings();
                break;
        }
    }

    /// <summary>Puts one section back to the shipped defaults, applies, saves and announces it.</summary>
    public void ResetSection(Section section)
    {
        switch (section)
        {
            case Section.Game:
                LookSensitivityX = 1.0f;
                LookSensitivityY = 1.0f;
                InvertLookY = false;
                InvertLookX = false;
                FieldOfView = 75.0f;
                ScreenEffects = 1.0f;
                break;

            case Section.Audio:
                foreach ((string key, StringName _) in Buses)
                {
                    _volumes[key] = 1.0f;
                }

                break;

            case Section.Video:
                WindowModeIndex = 1;
                VSyncIndex = 1;
                MsaaIndex = 2;
                MaxFpsIndex = 0;
                break;

            case Section.Input:
                _bindingOverrides.Clear();
                break;
        }

        MarkChanged(section);
    }

    // ---------------------------------------------------------------- Audio

    /// <summary>Linear amplitude 0..1 for a bus, by the config key in <see cref="Buses"/>.</summary>
    public float GetVolume(string key) => _volumes.TryGetValue(key, out float v) ? v : 1.0f;

    public void SetVolume(string key, float linear)
    {
        if (_volumes.ContainsKey(key))
        {
            _volumes[key] = Mathf.Clamp(linear, 0.0f, 1.0f);
        }
    }

    /// <summary>The keys the Sound section builds its sliders from, in listing order.</summary>
    public static IEnumerable<string> VolumeKeys()
    {
        foreach ((string key, StringName _) in Buses)
        {
            yield return key;
        }
    }

    private void ApplyAudio()
    {
        foreach ((string key, StringName bus) in Buses)
        {
            int index = AudioServer.GetBusIndex(bus);
            if (index < 0 || !_authoredBusDb.TryGetValue(bus, out float authored))
            {
                continue;
            }

            float linear = _volumes[key];

            // Zero mutes rather than being passed through: LinearToDb(0) is negative infinity, and
            // writing that into a bus volume is not something to find out about later.
            if (linear <= 0.0005f)
            {
                AudioServer.SetBusMute(index, true);
                AudioServer.SetBusVolumeDb(index, authored + SilenceDb);
                continue;
            }

            AudioServer.SetBusMute(index, false);

            // AN OFFSET, NEVER AN ABSOLUTE LEVEL. At linear == 1 this is authored + 0, so every
            // value tools/verify_music.gd asserts survives a default install untouched. And because
            // the offset can only ever be <= 0 dB, no slider setting can push the mix further into
            // the master limiter than the shipped build already does - which is what keeps
            // verify_whispers.gd's headroom budget valid at every setting, not just the default.
            AudioServer.SetBusVolumeDb(index, authored + Mathf.Max(Mathf.LinearToDb(linear), SilenceDb));
        }
    }

    /// <summary>The dB default_bus_layout.tres authored for a bus. Exposed for the verifiers.</summary>
    public float AuthoredBusDb(StringName bus) =>
        _authoredBusDb.TryGetValue(bus, out float db) ? db : 0.0f;

    // ---------------------------------------------------------------- Video

    public DisplayServer.WindowMode SelectedWindowMode => WindowModes[Wrap(WindowModeIndex, WindowModes.Length)];

    public DisplayServer.VSyncMode SelectedVSyncMode => VSyncModes[Wrap(VSyncIndex, VSyncModes.Length)];

    public Viewport.Msaa SelectedMsaa => MsaaModes[Wrap(MsaaIndex, MsaaModes.Length)];

    public int SelectedMaxFps => FpsCaps[Wrap(MaxFpsIndex, FpsCaps.Length)];

    public static int WindowModeCount => WindowModes.Length;

    public static int VSyncCount => VSyncModes.Length;

    public static int MsaaCount => MsaaModes.Length;

    public static int FpsCapCount => FpsCaps.Length;

    public static int FpsCapAt(int index) => FpsCaps[Wrap(index, FpsCaps.Length)];

    private void ApplyVideo()
    {
        Engine.MaxFps = SelectedMaxFps;

        // The root Window IS the Viewport every scene renders into - this project has no
        // SubViewport - so setting MSAA here is global and survives ChangeSceneToFile. Doing it
        // per-scene would mean every future scene having to remember.
        if (GetTree()?.Root is Window root)
        {
            root.Msaa3D = SelectedMsaa;
        }

        // Inert under the headless display server, which is fine: it is also inert there for
        // anything that would care. The verifier says so out loud rather than asserting it.
        DisplayServer.WindowSetMode(SelectedWindowMode);
        DisplayServer.WindowSetVsyncMode(SelectedVSyncMode);
    }

    // ---------------------------------------------------------------- Input

    /// <summary>The event currently bound for an action's family, default or override.</summary>
    public InputEvent? BindingFor(string action, BindingFamily family)
    {
        if (_bindingOverrides.TryGetValue(OverrideKey(action, family), out InputEvent? overridden))
        {
            return overridden;
        }

        if (!_defaultEvents.TryGetValue(action, out List<InputEvent>? shipped))
        {
            return null;
        }

        foreach (InputEvent shippedEvent in shipped)
        {
            if (FamilyOf(shippedEvent) == family)
            {
                return shippedEvent;
            }
        }

        return null;
    }

    /// <summary>
    /// Keys the menus themselves navigate on, which therefore cannot become gameplay bindings.
    ///
    /// THIS IS NOT TIDINESS, IT IS A MENU THAT WOULD RUN BACKWARDS. MainMenu.NavigateWithMoveKeys
    /// reads the move_* ACTIONS and consumes the event before Godot's own ui_* navigation sees it.
    /// So binding move_back to the Up arrow makes Up move focus DOWN in every menu - the action
    /// matches first and wins. Enter is worse: bound to a gameplay action it would fire that action
    /// and activate the focused button on the same press.
    ///
    /// Space is deliberately NOT here. It is already both `jump` and `ui_accept` in the shipped
    /// game, so it is a collision the port has always had and not one a rebind can introduce.
    /// </summary>
    private static readonly Key[] ReservedKeys =
    {
        Key.Up,
        Key.Down,
        Key.Left,
        Key.Right,
        Key.Enter,
        Key.KpEnter,
        Key.Escape,
    };

    /// <summary>
    /// Binds <paramref name="captured"/> to <paramref name="action"/>. Returns an empty string on
    /// success, or the sentence to show the player when it refuses.
    ///
    /// A RETURNED MESSAGE RATHER THAN `bool TryRebind(..., out string)`, which is the shape a C#
    /// reader would expect. Godot cannot marshal an `out` parameter: calling such a method through
    /// Object.Call from GDScript hangs the engine outright, with no error - measured, and it cost a
    /// killed process to find. The verifiers drive this method, so it has to be callable from them.
    ///
    /// Refuses, rather than swapping or clearing, when another listed action already holds the same
    /// event in the same family - and names it, so the player knows which row to change first.
    /// Swapping leaves a second action bound to something they never chose and have to discover;
    /// clearing strands an action unbound. Refusing is also the only policy whose outcome is
    /// trivially assertable: both bindings are unchanged afterwards.
    /// </summary>
    public string Rebind(string action, InputEvent captured)
    {
        InputEvent? binding = NormaliseCapture(captured);
        if (binding is null)
        {
            return "That input cannot be used as a binding.";
        }

        if (binding is InputEventKey key)
        {
            foreach (Key reserved in ReservedKeys)
            {
                if (key.PhysicalKeycode == reserved)
                {
                    return "The arrow keys and Enter operate the menus.";
                }
            }
        }

        BindingFamily family = FamilyOf(binding);

        foreach (string other in RemappableActions)
        {
            if (other == action)
            {
                continue;
            }

            InputEvent? existing = BindingFor(other, family);
            if (existing is not null && SameBinding(existing, binding))
            {
                return $"{Describe(binding)} is already used by {ActionLabel(other)}.";
            }
        }

        _bindingOverrides[OverrideKey(action, family)] = binding;
        MarkChanged(Section.Input);
        return string.Empty;
    }

    /// <summary>
    /// Turns a captured event into a storable binding, or null if it is not a kind we bind.
    ///
    /// MODIFIER FLAGS ARE STRIPPED, and that is not cosmetic. `run` is bound to bare Shift, so a
    /// player rebinding a movement key while resting a finger on Shift would otherwise store a
    /// Shift+W they cannot reproduce deliberately. project.godot's own bindings carry no modifiers
    /// either.
    ///
    /// KEYS KEEP ONLY THEIR PHYSICAL CODE, with Keycode left None. Every binding in project.godot
    /// is written that way - "keycode": 0 with physical_keycode set - so bindings are
    /// layout-independent and an AZERTY or Dvorak player gets the same key positions. Because this
    /// is the only place a binding is constructed, that invariant is structural: there is nowhere
    /// for a Keycode to come from.
    /// </summary>
    private static InputEvent? NormaliseCapture(InputEvent captured)
    {
        switch (captured)
        {
            case InputEventKey key when !key.IsEcho() && key.PhysicalKeycode != Key.None:
                return new InputEventKey
                {
                    Device = -1,
                    PhysicalKeycode = key.PhysicalKeycode,
                    Keycode = Key.None,
                };

            case InputEventMouseButton mouse:
                return new InputEventMouseButton
                {
                    Device = -1,
                    ButtonIndex = mouse.ButtonIndex,
                };

            case InputEventJoypadButton pad:
                return new InputEventJoypadButton
                {
                    Device = -1,
                    ButtonIndex = pad.ButtonIndex,
                };

            // A stick push, kept because four of the eight actions are bound to axes on the gamepad
            // side and "the gamepad is remappable" would be false without it. Only a decisive push
            // counts, so drift near the deadzone cannot be captured as a binding.
            case InputEventJoypadMotion motion when Mathf.Abs(motion.AxisValue) > 0.5f:
                return new InputEventJoypadMotion
                {
                    Device = -1,
                    Axis = motion.Axis,
                    AxisValue = motion.AxisValue > 0.0f ? 1.0f : -1.0f,
                };

            default:
                return null;
        }
    }

    /// <summary>Drops an override so the action falls back to what project.godot ships.</summary>
    public void ResetBinding(string action, BindingFamily family)
    {
        if (_bindingOverrides.Remove(OverrideKey(action, family)))
        {
            MarkChanged(Section.Input);
        }
    }

    public void ResetAllBindings() => ResetSection(Section.Input);

    /// <summary>
    /// Rewrites InputMap from the defaults plus any overrides.
    ///
    /// ActionEraseEvents, NOT ActionEraseAction + ActionAddAction. The latter resets the action's
    /// deadzone to the engine default, and this project's deadzones are deliberate - 0.2 on the
    /// four move_* actions, 0.5 on the rest - so the pair would silently change how far a stick has
    /// to travel before the character moves. Erasing only the events leaves the deadzone alone.
    ///
    /// Each family is filled independently, so rebinding a key cannot disturb the joypad event
    /// beside it. That is what keeps tools/verify_gamepad.gd - which asserts move_left/right on
    /// axis 0 and move_forward/back on axis 1 - valid after a keyboard remap.
    /// </summary>
    private void ApplyBindings()
    {
        foreach (string action in RemappableActions)
        {
            if (!_defaultEvents.ContainsKey(action))
            {
                continue;
            }

            InputEvent? keyboard = BindingFor(action, BindingFamily.KeyboardMouse);
            InputEvent? gamepad = BindingFor(action, BindingFamily.Gamepad);

            // AN ACTION IS NEVER LEFT WITH NOTHING. `pause` is the one that makes the game
            // unrecoverable - no way back to the menu, no way to reach these settings again - but
            // an empty action is a bug for any of them, so the guard is unconditional rather than
            // special-cased and the shipped events are the fallback.
            if (keyboard is null && gamepad is null)
            {
                GD.PushWarning($"{Name}: '{action}' would have been left unbound; restoring its defaults.");
                _bindingOverrides.Remove(OverrideKey(action, BindingFamily.KeyboardMouse));
                _bindingOverrides.Remove(OverrideKey(action, BindingFamily.Gamepad));
                keyboard = BindingFor(action, BindingFamily.KeyboardMouse);
                gamepad = BindingFor(action, BindingFamily.Gamepad);
            }

            InputMap.ActionEraseEvents(action);

            if (keyboard is not null)
            {
                InputMap.ActionAddEvent(action, keyboard);
            }

            if (gamepad is not null)
            {
                InputMap.ActionAddEvent(action, gamepad);
            }
        }
    }

    private void LoadBindings(ConfigFile config)
    {
        _bindingOverrides.Clear();

        if (!config.HasSection(SectionInput))
        {
            return;
        }

        foreach (string key in config.GetSectionKeys(SectionInput))
        {
            string token = config.GetValue(SectionInput, key, string.Empty).AsString();
            InputEvent? binding = DecodeBinding(token);

            if (binding is null)
            {
                // The default stays in force. A corrupt line must not leave an action unbound.
                GD.PushWarning($"{Name}: could not read binding '{key}' = '{token}'; keeping the default.");
                continue;
            }

            _bindingOverrides[key] = binding;
        }
    }

    /// <summary>
    /// A compact token rather than a serialised Object(InputEventKey, ...).
    ///
    /// The serialised form is engine-version-dependent and carries every field of the event -
    /// including `keycode`, which is exactly the thing that must never come back. A token that can
    /// only express a physical code cannot smuggle one in.
    /// </summary>
    private static string? EncodeBinding(InputEvent binding) => binding switch
    {
        InputEventKey key => $"key:{(int)key.PhysicalKeycode}",
        InputEventMouseButton mouse => $"mouse:{(int)mouse.ButtonIndex}",
        InputEventJoypadButton pad => $"joyb:{(int)pad.ButtonIndex}",
        InputEventJoypadMotion motion => $"joyaxis:{(int)motion.Axis}:{(motion.AxisValue > 0.0f ? 1 : -1)}",
        _ => null,
    };

    private static InputEvent? DecodeBinding(string token)
    {
        string[] parts = token.Split(':');
        if (parts.Length < 2 || !int.TryParse(parts[1], out int value))
        {
            return null;
        }

        switch (parts[0])
        {
            case "key":
                return new InputEventKey { Device = -1, PhysicalKeycode = (Key)value, Keycode = Key.None };
            case "mouse":
                return new InputEventMouseButton { Device = -1, ButtonIndex = (MouseButton)value };
            case "joyb":
                return new InputEventJoypadButton { Device = -1, ButtonIndex = (JoyButton)value };
            case "joyaxis":
                if (parts.Length < 3 || !int.TryParse(parts[2], out int sign))
                {
                    return null;
                }

                return new InputEventJoypadMotion
                {
                    Device = -1,
                    Axis = (JoyAxis)value,
                    AxisValue = sign >= 0 ? 1.0f : -1.0f,
                };
            default:
                return null;
        }
    }

    public static BindingFamily FamilyOf(InputEvent binding) =>
        binding is InputEventJoypadButton or InputEventJoypadMotion
            ? BindingFamily.Gamepad
            : BindingFamily.KeyboardMouse;

    /// <summary>
    /// Whether two bindings are the same button. Deliberately not InputEvent.IsMatch, which
    /// compares more than identity and treats a pressed and a released event differently.
    /// </summary>
    private static bool SameBinding(InputEvent a, InputEvent b) => (a, b) switch
    {
        (InputEventKey x, InputEventKey y) => x.PhysicalKeycode == y.PhysicalKeycode,
        (InputEventMouseButton x, InputEventMouseButton y) => x.ButtonIndex == y.ButtonIndex,
        (InputEventJoypadButton x, InputEventJoypadButton y) => x.ButtonIndex == y.ButtonIndex,
        (InputEventJoypadMotion x, InputEventJoypadMotion y) =>
            x.Axis == y.Axis && Mathf.Sign(x.AxisValue) == Mathf.Sign(y.AxisValue),
        _ => false,
    };

    private static string OverrideKey(string action, BindingFamily family) =>
        $"{action}/{(family == BindingFamily.Gamepad ? "pad" : "kbm")}";

    /// <summary>
    /// What to print on a binding button.
    ///
    /// A key is described by mapping its PHYSICAL code back through the player's own layout, which
    /// is the point of storing physical codes: a French AZERTY player sees "Z" on the Move Forward
    /// row while the binding stays physically W, so the label matches the key under their finger.
    /// Falls back to the raw physical code when the layout lookup gives nothing, which is what the
    /// headless display server does.
    /// </summary>
    public static string Describe(InputEvent? binding)
    {
        switch (binding)
        {
            case null:
                return "—";

            case InputEventKey key:
                return OS.GetKeycodeString(LayoutKeycode(key.PhysicalKeycode));

            case InputEventMouseButton mouse:
                return mouse.ButtonIndex switch
                {
                    MouseButton.Left => "Left Click",
                    MouseButton.Right => "Right Click",
                    MouseButton.Middle => "Middle Click",
                    MouseButton.WheelUp => "Wheel Up",
                    MouseButton.WheelDown => "Wheel Down",
                    _ => $"Mouse {(int)mouse.ButtonIndex}",
                };

            // Xbox labels, because Godot exposes no name function for JoyButton and every other
            // pad's face buttons sit in the same positions.
            case InputEventJoypadButton pad:
                return pad.ButtonIndex switch
                {
                    JoyButton.A => "A",
                    JoyButton.B => "B",
                    JoyButton.X => "X",
                    JoyButton.Y => "Y",
                    JoyButton.LeftShoulder => "LB",
                    JoyButton.RightShoulder => "RB",
                    JoyButton.Back => "Back",
                    JoyButton.Start => "Start",
                    JoyButton.LeftStick => "L3",
                    JoyButton.RightStick => "R3",
                    JoyButton.DpadUp => "D-Pad Up",
                    JoyButton.DpadDown => "D-Pad Down",
                    JoyButton.DpadLeft => "D-Pad Left",
                    JoyButton.DpadRight => "D-Pad Right",
                    _ => $"Button {(int)pad.ButtonIndex}",
                };

            case InputEventJoypadMotion motion:
                bool positive = motion.AxisValue > 0.0f;
                return motion.Axis switch
                {
                    JoyAxis.LeftX => positive ? "Left Stick Right" : "Left Stick Left",
                    JoyAxis.LeftY => positive ? "Left Stick Down" : "Left Stick Up",
                    JoyAxis.RightX => positive ? "Right Stick Right" : "Right Stick Left",
                    JoyAxis.RightY => positive ? "Right Stick Down" : "Right Stick Up",
                    JoyAxis.TriggerLeft => "LT",
                    JoyAxis.TriggerRight => "RT",
                    _ => $"Axis {(int)motion.Axis}{(positive ? "+" : "-")}",
                };

            default:
                return "—";
        }
    }

    /// <summary>
    /// A physical key code mapped through the player's own keyboard layout, for display only.
    ///
    /// WHY THE GUARD. DisplayServer.KeyboardGetKeycodeFromPhysical is not implemented by the headless
    /// display server: it pushes "Not supported by this display server" and returns 0. Unguarded that
    /// is one error per binding row every time a verifier builds this screen - eight rows of stack
    /// traces burying whatever the check was actually reporting. Measured, not anticipated.
    ///
    /// Falling back to the physical code is right anyway: it is the code that was stored, so a
    /// headless run prints the same label a US-layout player would see.
    /// </summary>
    private static Key LayoutKeycode(Key physical)
    {
        if (DisplayServer.GetName() == "headless")
        {
            return physical;
        }

        Key mapped = DisplayServer.KeyboardGetKeycodeFromPhysical(physical);
        return mapped != Key.None ? mapped : physical;
    }

    /// <summary>The label the options screen puts beside an action's binding buttons.</summary>
    public static string ActionLabel(string action) => action switch
    {
        "move_forward" => "Move Forward",
        "move_back" => "Move Back",
        "move_left" => "Move Left",
        "move_right" => "Move Right",
        "jump" => "Jump",
        "run" => "Run",
        "attack" => "Attack",
        "pause" => "Pause",
        _ => action,
    };

    // --------------------------------------------------------------- Helpers

    private static float ReadFloat(ConfigFile config, string section, string key, float fallback, float min, float max)
    {
        Variant stored = config.GetValue(section, key, fallback);
        float value = stored.VariantType is Variant.Type.Float or Variant.Type.Int
            ? stored.AsSingle()
            : fallback;

        return Mathf.Clamp(value, min, max);
    }

    private static int ReadIndex(ConfigFile config, string section, string key, int fallback, int count)
    {
        Variant stored = config.GetValue(section, key, fallback);
        int value = stored.VariantType is Variant.Type.Int or Variant.Type.Float ? stored.AsInt32() : fallback;

        return value >= 0 && value < count ? value : fallback;
    }

    private static int Wrap(int index, int count) => index >= 0 && index < count ? index : 0;
}
