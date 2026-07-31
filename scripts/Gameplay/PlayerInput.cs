using Godot;

namespace TheFirstDay.Gameplay;

/// <summary>
/// The eight discrete directions the keyboard can express, plus "no input".
/// Port of Unity's WASDirections; the numbering is load-bearing because
/// PlayerCharacter indexes its direction and rotation tables with it.
/// </summary>
public enum WasDirection
{
    Up = 0,
    Down = 1,
    Left = 2,
    Right = 3,
    UpRight = 4,
    UpLeft = 5,
    DownRight = 6,
    DownLeft = 7,
    NoInput = 8,
}

/// <summary>
/// Port of Unity's InputManager, which lived on a globally-tagged GameObject
/// and was looked up with FindGameObjectWithTag("InputManager"). An autoload is
/// the Godot equivalent of that single shared instance.
///
/// Only the keyboard path is ported. The original also had an XInput path
/// feeding an analog movement module (YelenaGamePadMovement) that is not ported
/// yet; the input map binds joypad axes to the same actions, so a controller
/// still reads as digital input in the meantime.
/// </summary>
public partial class PlayerInput : Node
{
    public static PlayerInput? Instance { get; private set; }

    /// <summary>
    /// When false the manager stops reporting input. Fortunato.Start() set this
    /// false so the level could open without the player being able to move, and
    /// Die() set it false again on death.
    /// </summary>
    public bool CanValidateInput { get; set; } = true;

    public WasDirection CurrentDirection { get; private set; } = WasDirection.NoInput;

    public bool Jump { get; private set; }

    public bool Attack { get; private set; }

    public bool Run { get; private set; }

    /// <summary>
    /// The left stick, deadzoned, with its MAGNITUDE intact - which is the whole point of it. A
    /// gamepad moved Fortunato at <c>runSpeed * Clamp01(magnitude)</c> in the original, so a half-
    /// pushed stick walked; the keyboard path has no such notion and uses the eight-way
    /// <see cref="CurrentDirection"/> with a separate run button.
    ///
    /// Read through the action map rather than off raw axes, so the bindings in project.godot stay
    /// the single source of truth: move_left/right are joypad axis 0 and move_forward/back axis 1.
    /// Godot's Y is positive downward on a stick, so this is negated to match Unity's convention of
    /// positive-forward, the same correction the camera's vertical axis needed.
    /// </summary>
    public Vector2 MoveVector { get; private set; }

    /// <summary>
    /// Which device was used last. Unity kept this as InputManager.CurrentType and switched it BOTH
    /// ways - any gamepad input selected XINPUT, any keyboard input selected MOUSE_KEYBOARD - so the
    /// two schemes never fought. Reproduced from the event stream, because Godot's action map merges
    /// the devices into one set of actions and IsActionPressed cannot say which one pressed it.
    /// </summary>
    public bool UsingGamepad { get; private set; }

    private bool _jumpHeldPreviously;
    private bool _attackHeldPreviously;

    public override void _Ready()
    {
        Instance = this;
        // Keep reading input while the game is paused is NOT wanted: the pause
        // menu should freeze movement, so inherit the default process mode.
    }

    public override void _ExitTree()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    /// <summary>
    /// Polled on the physics clock, not per frame: PlayerCharacter consumes these
    /// in _PhysicsProcess, and a one-frame "just pressed" edge latched in _Process
    /// can be overwritten before any physics tick ever sees it.
    /// </summary>
    public override void _PhysicsProcess(double delta)
    {
        ValidateDirection();

        // Unity's GetButtonDown semantics, derived from held state rather than
        // Input.IsActionJustPressed: the engine's "just pressed" edge is tied to
        // the frame/tick the event arrived and is unreliable for actions injected
        // programmatically, which also makes it untestable.
        bool jumpHeld = Input.IsActionPressed("jump") && CanValidateInput;
        Jump = jumpHeld && !_jumpHeldPreviously;
        _jumpHeldPreviously = jumpHeld;

        bool attackHeld = Input.IsActionPressed("attack") && CanValidateInput;
        Attack = attackHeld && !_attackHeldPreviously;
        _attackHeldPreviously = attackHeld;

        Run = Input.IsActionPressed("run") && CanValidateInput;

        MoveVector = CanValidateInput
            ? Input.GetVector("move_left", "move_right", "move_forward", "move_back") * new Vector2(1.0f, -1.0f)
            : Vector2.Zero;
    }

    /// <summary>
    /// Tracks which device is in use, the way Unity's InputManager did - last one wins. A joypad
    /// axis or button selects the gamepad; a key selects keyboard-and-mouse. Mouse motion is
    /// deliberately NOT a signal: it is part of the keyboard-and-mouse scheme, and the camera
    /// consumes it continuously, so treating it as one would make holding a stick while nudging the
    /// mouse flip modes every frame.
    /// </summary>
    public override void _Input(InputEvent @event)
    {
        if (@event is InputEventJoypadMotion or InputEventJoypadButton)
        {
            UsingGamepad = true;
        }
        else if (@event is InputEventKey)
        {
            UsingGamepad = false;
        }
    }

    /// <summary>
    /// Resolves the eight-way direction. The original checks up/down first and
    /// only then the horizontal keys, so pressing W+S+D yields UP_RIGHT rather
    /// than cancelling out — that precedence is preserved.
    /// </summary>
    private void ValidateDirection()
    {
        if (!CanValidateInput)
        {
            CurrentDirection = WasDirection.NoInput;
            return;
        }

        bool up = Input.IsActionPressed("move_forward");
        bool down = Input.IsActionPressed("move_back");
        bool left = Input.IsActionPressed("move_left");
        bool right = Input.IsActionPressed("move_right");

        if (up)
        {
            CurrentDirection = right ? WasDirection.UpRight
                : left ? WasDirection.UpLeft
                : WasDirection.Up;
        }
        else if (down)
        {
            CurrentDirection = right ? WasDirection.DownRight
                : left ? WasDirection.DownLeft
                : WasDirection.Down;
        }
        else
        {
            CurrentDirection = right ? WasDirection.Right
                : left ? WasDirection.Left
                : WasDirection.NoInput;
        }
    }
}
