using System;
using System.Collections.Generic;
using Godot;
using TheFirstDay.Utils;

namespace TheFirstDay.UI;

/// <summary>
/// The options screen: Game, Sound, Video and Input, with key remapping.
///
/// A DELIBERATE ADDITION. The 2016 original had no options at all, so nothing here is a port. The
/// reasoning behind each knob - and behind the ones deliberately left out - is in
/// docs/level-port-scope.md; <see cref="GameSettings"/> owns the state and the persistence.
///
/// ONE SCENE, MOUNTED IN TWO PLACES. The main menu and the pause menu both instantiate this at
/// runtime and show it as an overlay, so the two entry points cannot drift apart. That is why the
/// scene's root is ProcessMode.Always: reached from the pause menu it has to run while
/// SceneTree.Paused, and a paused node cannot un-pause itself.
///
/// EVERY ROW IS AUTHORED IN options_menu.tscn AND ONLY WIRED UP HERE. Open the scene and you see the
/// real screen, and the layout - slider ranges, label widths, spacing, wording - is a designer's to
/// change without touching C#. This class owns only what each control MEANS.
///
/// It was the other way round first, with the rows generated in _Ready, and the scene was useless to
/// open: four empty boxes, every metric a C# constant. On a project with more than one person on it,
/// a screen full of tunables only a programmer can reach is the wrong trade. The cost of the swap is
/// that the UI no longer guarantees a sane value, so GameSettings clamps on write.
///
/// NOTHING HERE IS TWEENED, on purpose. Tweens are bound to a node's process mode and stop dead
/// under SceneTree.Paused, so an animated overlay would work from the main menu and silently not
/// work from the pause menu - the worst kind of divergence. If an animation is ever wanted, the node
/// carrying it must be ProcessMode.Always.
/// </summary>
public partial class OptionsMenu : Control
{
    /// <summary>
    /// How long after a row is activated its own press is ignored, in seconds.
    ///
    /// The trap: `attack` is bound to the LEFT MOUSE BUTTON, so a naive capture grabs the very click
    /// that opened the prompt and rebinds the action to what it already had. Buttons emit `pressed`
    /// on release, so that click has usually finished before capture begins - but "usually" is not a
    /// guarantee across echo events and gamepad repeats, and the same guard also stops the Space or
    /// Enter that activated the row from being captured. Same shape as Credits.SkipGuardSeconds.
    /// </summary>
    private const double CaptureGuardSeconds = 0.2;

    private static readonly string[] WindowModeLabels = { "Windowed", "Maximised", "Fullscreen" };
    private static readonly string[] VSyncLabels = { "Off", "On", "Adaptive" };
    private static readonly string[] MsaaLabels = { "Off", "2x", "4x", "8x" };

    /// <summary>
    /// Each remappable action paired with the two buttons that show its bindings in the scene.
    ///
    /// The action list itself stays <see cref="GameSettings.RemappableActions"/>; this only says which
    /// node belongs to which. Kept as an explicit table rather than derived from the action name so
    /// that renaming a node in the editor is a compile-adjacent change here, not a silent mismatch.
    /// </summary>
    private static readonly (string Action, string Key, string Pad)[] BindingRows =
    {
        ("move_forward", "%BindMoveForwardKey", "%BindMoveForwardPad"),
        ("move_back", "%BindMoveBackKey", "%BindMoveBackPad"),
        ("move_left", "%BindMoveLeftKey", "%BindMoveLeftPad"),
        ("move_right", "%BindMoveRightKey", "%BindMoveRightPad"),
        ("jump", "%BindJumpKey", "%BindJumpPad"),
        ("run", "%BindRunKey", "%BindRunPad"),
        ("attack", "%BindAttackKey", "%BindAttackPad"),
        ("pause", "%BindPauseKey", "%BindPausePad"),
    };

    [Signal]
    public delegate void ClosedEventHandler();

    private Button _gameTab = null!;
    private Button _soundTab = null!;
    private Button _videoTab = null!;
    private Button _inputTab = null!;
    private ScrollContainer _gameSection = null!;
    private ScrollContainer _soundSection = null!;
    private ScrollContainer _videoSection = null!;
    private ScrollContainer _inputSection = null!;
    private Button _resetButton = null!;
    private Button _backButton = null!;
    private Control _rebindPrompt = null!;
    private Label _rebindLabel = null!;
    private Label _rebindHint = null!;
    private Button _rebindCancel = null!;

    private GameSettings.Section _section = GameSettings.Section.Game;

    /// <summary>Where focus goes when this closes - the button that opened it.</summary>
    private Control? _returnFocusTo;

    /// <summary>Re-reads every control from <see cref="GameSettings"/>. Needed after a reset.</summary>
    private readonly List<Action> _refreshers = new();

    private string? _capturingAction;
    private GameSettings.BindingFamily _capturingFamily;
    private double _captureBeganAt;

    public override void _Ready()
    {
        _gameTab = GetNode<Button>("%GameTab");
        _soundTab = GetNode<Button>("%SoundTab");
        _videoTab = GetNode<Button>("%VideoTab");
        _inputTab = GetNode<Button>("%InputTab");
        _gameSection = GetNode<ScrollContainer>("%GameSection");
        _soundSection = GetNode<ScrollContainer>("%SoundSection");
        _videoSection = GetNode<ScrollContainer>("%VideoSection");
        _inputSection = GetNode<ScrollContainer>("%InputSection");
        _resetButton = GetNode<Button>("%ResetButton");
        _backButton = GetNode<Button>("%BackButton");
        _rebindPrompt = GetNode<Control>("%RebindPrompt");
        _rebindLabel = GetNode<Label>("%RebindLabel");
        _rebindHint = GetNode<Label>("%RebindHint");
        _rebindCancel = GetNode<Button>("%RebindCancel");

        if (ProcessMode != ProcessModeEnum.Always)
        {
            GD.PushWarning($"{Name}: should be ProcessMode.Always, or it cannot be used from the pause menu.");
        }

        // THE ACTIVE TAB NEEDS A STATE OF ITS OWN, not just the focus ring. Without this the only
        // thing marking the current section was the salmon focus style, so the moment focus moved to
        // a slider no tab looked active at all - and worse, the tab the player had left behind kept
        // the highlight while a different section's rows were on screen. Caught by looking at a
        // screenshot; every headless check passed.
        //
        // ToggleMode plus a shared ButtonGroup makes them radio buttons: the group refuses to let all
        // four be off, and the toggled-on tab wears the `pressed` grey from the theme.
        ButtonGroup tabs = new();
        foreach (Button tab in new[] { _gameTab, _soundTab, _videoTab, _inputTab })
        {
            tab.ToggleMode = true;
            tab.ButtonGroup = tabs;
        }

        _gameTab.Pressed += () => ShowSection(GameSettings.Section.Game);
        _soundTab.Pressed += () => ShowSection(GameSettings.Section.Audio);
        _videoTab.Pressed += () => ShowSection(GameSettings.Section.Video);
        _inputTab.Pressed += () => ShowSection(GameSettings.Section.Input);

        _resetButton.Pressed += OnResetPressed;
        _backButton.Pressed += Close;
        _rebindCancel.Pressed += CancelCapture;

        BindGameSection();
        BindSoundSection();
        BindVideoSection();
        BindInputSection();

        _rebindPrompt.Visible = false;
        ShowSection(GameSettings.Section.Game);

        // Only listens while it is on screen. A hidden overlay that still processed input would eat
        // the Escape that opens the pause menu, which is a bug with no visible cause at all.
        SetProcessInput(false);
    }

    /// <summary>
    /// Shows the screen. <paramref name="returnFocusTo"/> is the control focus goes back to on
    /// close, so a player who never touches the mouse does not lose their place.
    /// </summary>
    public void Open(Control? returnFocusTo = null)
    {
        _returnFocusTo = returnFocusTo;

        // Idempotent, and it guarantees a cursor whichever route got here. This screen never
        // CAPTURES the mouse: closing it returns to the pause menu, which still needs one, and
        // PauseMenu.Toggle is the only thing that should ever take the cursor back.
        Gameplay.GameManager.Instance?.ReleaseMouse();

        Refresh();
        Visible = true;
        SetProcessInput(true);

        // SOMETHING IS ALWAYS FOCUSED HERE, unlike the main menu - whose "nothing focused on entry"
        // is faithfulness to Unity's null m_FirstSelected, not a preference. This screen is reached
        // by a deliberate press, so the player is already navigating, and a screen full of sliders
        // where focus can be null is a screen where a stray Enter does something surprising.
        ActiveTab().GrabFocus();
    }

    public void Close()
    {
        if (_capturingAction is not null)
        {
            CancelCapture();
            return;
        }

        // Written on the way out as well as on the debounce, so a player who alt-F4s straight from
        // the options screen still keeps what they just changed.
        GameSettings.Instance?.FlushIfDirty();

        Visible = false;
        SetProcessInput(false);
        _returnFocusTo?.GrabFocus();
        EmitSignal(SignalName.Closed);
    }

    /// <summary>
    /// Handled in <c>_Input</c> rather than <c>_UnhandledInput</c>, which is the whole reason the
    /// pause flow works.
    ///
    /// PauseMenu listens for the same `pause` action in _UnhandledInput. The engine always runs
    /// _Input for the entire tree before _UnhandledInput, so consuming it here means PauseMenu
    /// provably never sees it while this screen is open - no dependency on node order. Without that,
    /// Escape inside the options would resume the game and re-capture the mouse with the options
    /// panel still drawn on screen.
    ///
    /// ui_cancel is checked as well as `pause`, and that matters: a player may rebind `pause` to
    /// some other key, and ui_cancel is Escape, is built in and is never remappable. So Escape
    /// always closes this screen whatever else has been rebound.
    /// </summary>
    public override void _Input(InputEvent @event)
    {
        if (!Visible)
        {
            return;
        }

        // Capture comes first, so the Escape that cancels a rebind does not also close the screen.
        if (_capturingAction is not null)
        {
            HandleCapture(@event);
            return;
        }

        if (@event.IsActionPressed("ui_cancel") || @event.IsActionPressed("pause"))
        {
            Close();
            GetViewport().SetInputAsHandled();
            return;
        }

        if (GetViewport().GuiGetFocusOwner() is Control focused)
        {
            MenuNavigation.TryNavigateWithMoveKeys(GetViewport(), @event, focused);
        }
    }

    // ------------------------------------------------------------- Sections

    private void ShowSection(GameSettings.Section section)
    {
        _section = section;

        _gameSection.Visible = section == GameSettings.Section.Game;
        _soundSection.Visible = section == GameSettings.Section.Audio;
        _videoSection.Visible = section == GameSettings.Section.Video;
        _inputSection.Visible = section == GameSettings.Section.Input;

        // Marks the tab whatever moved the section - a click, a keyboard activation, or Open()
        // restoring the last one. The ButtonGroup clears the other three.
        ActiveTab().ButtonPressed = true;
    }

    private Button ActiveTab() => _section switch
    {
        GameSettings.Section.Audio => _soundTab,
        GameSettings.Section.Video => _videoTab,
        GameSettings.Section.Input => _inputTab,
        _ => _gameTab,
    };

    private void OnResetPressed()
    {
        GameSettings.Instance?.ResetSection(_section);
        Refresh();
    }

    private void Refresh()
    {
        foreach (Action refresh in _refreshers)
        {
            refresh();
        }
    }

    // --------------------------------------------------------- Binding rows

    /// <summary>
    /// Every row is AUTHORED IN THE SCENE and merely wired up here.
    ///
    /// It used to be the other way round - the .tscn carried only the chrome and this class built the
    /// twenty-odd rows in _Ready. That made the scene useless to open: the editor showed four empty
    /// boxes, and every metric (label width, slider range, button size) was a C# constant nobody but
    /// a programmer could touch. On a project with more than one person on it, a screen full of
    /// tunables that only a programmer can retune is the wrong trade.
    ///
    /// So the sliders' min/max/step, the label widths, the spacing and the wording now live in
    /// options_menu.tscn where a designer can change them, and the only thing this file owns is what
    /// each control MEANS. Consequence worth knowing: the UI no longer guarantees a sane value, so
    /// GameSettings clamps on write - see GameSettings.MinSensitivity.
    ///
    /// Controls are found by unique name (<c>%SensXSlider</c> and friends), the same idiom
    /// MainMenu and PauseMenu already use. A renamed or deleted node is reported and skipped rather
    /// than crashing the screen, because the scene is now something other people edit.
    /// </summary>
    private void BindGameSection()
    {
        GameSettings settings = GameSettings.Instance!;

        BindSlider("%SensXSlider",
            () => settings.LookSensitivityX,
            v => settings.LookSensitivityX = (float)v,
            v => $"{v:0.00}x",
            GameSettings.Section.Game);

        BindSlider("%SensYSlider",
            () => settings.LookSensitivityY,
            v => settings.LookSensitivityY = (float)v,
            v => $"{v:0.00}x",
            GameSettings.Section.Game);

        BindCheck("%InvertYCheck",
            () => settings.InvertLookY,
            v => settings.InvertLookY = v,
            GameSettings.Section.Game);

        BindCheck("%InvertXCheck",
            () => settings.InvertLookX,
            v => settings.InvertLookX = v,
            GameSettings.Section.Game);

        BindSlider("%FovSlider",
            () => settings.FieldOfView,
            v => settings.FieldOfView = (float)v,
            v => $"{v:0} deg",
            GameSettings.Section.Game);

        BindSlider("%EffectsSlider",
            () => settings.ScreenEffects,
            v => settings.ScreenEffects = (float)v,
            v => $"{v * 100.0:0}%",
            GameSettings.Section.Game);
    }

    private void BindSoundSection()
    {
        GameSettings settings = GameSettings.Instance!;

        // The bus keys, paired with the slider that drives each. Player-facing labels live in the
        // scene; "Coworkers" and "Fortunato" are the mix's names and mean nothing to a player.
        (string Unique, string Key)[] sliders =
        {
            ("%MasterSlider", "master"),
            ("%MusicSlider", "music"),
            ("%AmbienceSlider", "ambience"),
            ("%WhispersSlider", "whispers"),
            ("%FootstepsSlider", "footsteps"),
        };

        foreach ((string unique, string key) in sliders)
        {
            string captured = key;
            BindSlider(unique,
                () => settings.GetVolume(captured),
                v => settings.SetVolume(captured, (float)v),
                v => $"{v * 100.0:0}%",
                GameSettings.Section.Audio);
        }
    }

    private void BindVideoSection()
    {
        GameSettings settings = GameSettings.Instance!;

        // Cycling buttons rather than OptionButtons. An OptionButton consumes ui_up and ui_down to
        // step its own items, which would swallow the row-to-row navigation for the whole column -
        // and its Selected setter does not emit item_selected, so the handler would silently never
        // run. A Button that cycles has neither problem and needs no theme work.
        BindChoice("%WindowModeButton", WindowModeLabels,
            () => settings.WindowModeIndex,
            i => settings.WindowModeIndex = i,
            GameSettings.Section.Video);

        BindChoice("%VSyncButton", VSyncLabels,
            () => settings.VSyncIndex,
            i => settings.VSyncIndex = i,
            GameSettings.Section.Video);

        BindChoice("%MsaaButton", MsaaLabels,
            () => settings.MsaaIndex,
            i => settings.MsaaIndex = i,
            GameSettings.Section.Video);

        string[] fpsLabels = new string[GameSettings.FpsCapCount];
        for (int i = 0; i < fpsLabels.Length; i++)
        {
            int cap = GameSettings.FpsCapAt(i);
            fpsLabels[i] = cap == 0 ? "Unlimited" : cap.ToString();
        }

        BindChoice("%MaxFpsButton", fpsLabels,
            () => settings.MaxFpsIndex,
            i => settings.MaxFpsIndex = i,
            GameSettings.Section.Video);
    }

    private void BindInputSection()
    {
        foreach ((string action, string keyUnique, string padUnique) in BindingRows)
        {
            BindBindingButton(action, keyUnique, GameSettings.BindingFamily.KeyboardMouse);
            BindBindingButton(action, padUnique, GameSettings.BindingFamily.Gamepad);
        }
    }

    /// <summary>
    /// The row a control lives in, so its readout can be found without a second unique name. Each row
    /// is an HBoxContainer holding a "Name" Label, the control, and optionally a "Value" Label.
    /// </summary>
    private static Label? ReadoutFor(Control control) =>
        control.GetParent()?.GetNodeOrNull<Label>("Value");

    private T? Resolve<T>(string unique) where T : Control
    {
        T? found = GetNodeOrNull<T>(unique);
        if (found is null)
        {
            GD.PushWarning($"{Name}: options_menu.tscn has no {unique}; that row will do nothing.");
        }

        return found;
    }

    private void BindSlider(
        string unique,
        Func<double> read,
        Action<double> write,
        Func<double, string> format,
        GameSettings.Section section)
    {
        if (Resolve<Slider>(unique) is not Slider slider)
        {
            return;
        }

        Label? readout = ReadoutFor(slider);
        bool applying = false;

        slider.ValueChanged += value =>
        {
            if (applying)
            {
                return;
            }

            write(value);

            // Read BACK rather than echoing the slider: GameSettings clamps on write, so the stored
            // value and the readout cannot disagree even if the scene's range is wider than the
            // setting allows.
            if (readout is not null)
            {
                readout.Text = format(read());
            }

            GameSettings.Instance?.MarkChanged(section);
        };

        _refreshers.Add(() =>
        {
            applying = true;
            slider.Value = read();
            if (readout is not null)
            {
                readout.Text = format(read());
            }

            applying = false;
        });
    }

    private void BindCheck(
        string unique,
        Func<bool> read,
        Action<bool> write,
        GameSettings.Section section)
    {
        if (Resolve<CheckButton>(unique) is not CheckButton check)
        {
            return;
        }

        bool applying = false;

        check.Toggled += on =>
        {
            if (applying)
            {
                return;
            }

            write(on);
            GameSettings.Instance?.MarkChanged(section);
        };

        _refreshers.Add(() =>
        {
            applying = true;
            check.ButtonPressed = read();
            applying = false;
        });
    }

    /// <summary>A button that cycles through a fixed list. See the note in BindVideoSection.</summary>
    private void BindChoice(
        string unique,
        string[] labels,
        Func<int> read,
        Action<int> write,
        GameSettings.Section section)
    {
        if (Resolve<Button>(unique) is not Button button)
        {
            return;
        }

        void Step(int direction)
        {
            int next = (read() + direction + labels.Length) % labels.Length;
            write(next);
            button.Text = labels[next];
            GameSettings.Instance?.MarkChanged(section);
        }

        button.Pressed += () => Step(1);

        _refreshers.Add(() => button.Text = labels[Math.Clamp(read(), 0, labels.Length - 1)]);
    }

    private void BindBindingButton(string action, string unique, GameSettings.BindingFamily family)
    {
        if (Resolve<Button>(unique) is not Button button)
        {
            return;
        }

        button.Pressed += () => BeginCapture(action, family);
        _refreshers.Add(() => button.Text = DescribeBinding(action, family));
    }

    private static string DescribeBinding(string action, GameSettings.BindingFamily family) =>
        GameSettings.Describe(GameSettings.Instance?.BindingFor(action, family));

    // ------------------------------------------------------- Rebind capture

    private void BeginCapture(string action, GameSettings.BindingFamily family)
    {
        _capturingAction = action;
        _capturingFamily = family;
        _captureBeganAt = Time.GetTicksMsec() / 1000.0;

        _rebindLabel.Text = family == GameSettings.BindingFamily.Gamepad
            ? $"Press a gamepad input for {GameSettings.ActionLabel(action)}"
            : $"Press a key or mouse button for {GameSettings.ActionLabel(action)}";
        _rebindHint.Text = "Escape cancels";
        _rebindPrompt.Visible = true;
        _rebindCancel.GrabFocus();
    }

    private void CancelCapture()
    {
        _capturingAction = null;
        _rebindPrompt.Visible = false;
        ActiveTab().GrabFocus();
    }

    /// <summary>
    /// Consumes every event while a rebind is being captured, so nothing leaks to the buttons
    /// underneath or to the pause menu. Only a deliberate press of a bindable kind is taken.
    /// </summary>
    private void HandleCapture(InputEvent @event)
    {
        GetViewport().SetInputAsHandled();

        if (Time.GetTicksMsec() / 1000.0 - _captureBeganAt < CaptureGuardSeconds)
        {
            return;
        }

        // Escape always cancels, and is checked before anything else - which is also why Escape can
        // never be captured AS a binding. GameSettings refuses it too, so this is belt and braces.
        if (@event is InputEventKey { Pressed: true, PhysicalKeycode: Key.Escape })
        {
            CancelCapture();
            return;
        }

        bool wanted = @event switch
        {
            InputEventKey key => key.Pressed && !key.IsEcho(),
            InputEventMouseButton mouse => mouse.Pressed,
            InputEventJoypadButton pad => pad.Pressed,
            InputEventJoypadMotion motion => Mathf.Abs(motion.AxisValue) > 0.5f,
            _ => false,
        };

        if (!wanted)
        {
            return;
        }

        // Only the matching family may be captured, so a controller press cannot destroy a keyboard
        // binding by accident and the other half of the row is never touched.
        if (GameSettings.FamilyOf(@event) != _capturingFamily)
        {
            _rebindHint.Text = _capturingFamily == GameSettings.BindingFamily.Gamepad
                ? "That is not a gamepad input."
                : "That is not a key or mouse button.";
            return;
        }

        string refusal = GameSettings.Instance?.Rebind(_capturingAction!, @event) ?? "Settings are unavailable.";

        if (refusal.Length > 0)
        {
            // Stay in capture so the player can just press something else, rather than having to
            // reopen the row to try again.
            _rebindHint.Text = refusal;
            return;
        }

        _capturingAction = null;
        _rebindPrompt.Visible = false;
        Refresh();
        ActiveTab().GrabFocus();
    }
}
