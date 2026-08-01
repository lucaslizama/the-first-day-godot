using Godot;

namespace TheFirstDay.UI;

/// <summary>
/// Menu navigation for W/A/S/D, which Godot's own GUI navigation will not do.
///
/// THE ASYMMETRY THIS EXISTS TO CLOSE. Godot navigates on the <c>ui_*</c> actions, and their
/// bindings are not what you would guess: <c>ui_down</c> is Down, d-pad down AND left stick Y+1, so
/// the gamepad navigates a menu out of the box. W and S are bound only to this project's
/// <c>move_*</c> actions, which the engine's GUI knows nothing about. The result was a main menu
/// where the first W armed a button and every W after it did nothing - arming worked, so it looked
/// wired up, but WASD could never actually reach the second button.
///
/// Lifted out of <see cref="MainMenu"/> so the options screen gets the same behaviour rather than a
/// second copy of it. The extraction was made deliberately behaviour-preserving and checked against
/// <c>tools/verify_main_menu.gd</c>'s 20 checks before anything was built on top of it - eleven of
/// those checks exist because an earlier version of exactly this logic was subtly wrong.
/// </summary>
public static class MenuNavigation
{
    /// <summary>
    /// Inputs that count as "the player is reaching for the menu" and so arm the first button.
    ///
    /// Two families, because the two halves of the scheme live in different places. The arrow keys
    /// and the gamepad's d-pad and left stick arrive through Godot's built-in <c>ui_*</c> actions,
    /// which this project never redefines. W/A/S/D arrive through the project's own <c>move_*</c>
    /// actions - the level's movement bindings, which are also bound to the same sticks, so a stick
    /// push matches in both families and the first match wins.
    /// </summary>
    public static readonly string[] DirectionalActions =
    {
        "ui_up",
        "ui_down",
        "ui_left",
        "ui_right",
        "move_forward",
        "move_back",
        "move_left",
        "move_right",
    };

    /// <summary>
    /// Focuses <paramref name="first"/> the moment the player reaches for a menu with a direction -
    /// arrows, W/A/S/D, d-pad or stick. Returns true when it armed and consumed the event.
    ///
    /// This is what keeps "nothing focused on entry" from also meaning "unreachable without a
    /// mouse". Godot's navigation walk starts FROM the focus owner - Viewport::_gui_navigation_input
    /// bails when there is none - so with nothing focused every navigation input including Tab is
    /// inert, and a menu could be operated only by clicking.
    ///
    /// CONSUMED DELIBERATELY, so the press only arms focus and does not also move it. Callers run
    /// this from _Input, which the engine runs BEFORE the viewport's GUI navigation; without the
    /// consume the same ui_up or ui_down would be processed again a moment later - now with a focus
    /// owner - and step straight past the button just landed on.
    /// </summary>
    public static bool TryArm(Viewport viewport, InputEvent @event, Button first)
    {
        foreach (string action in DirectionalActions)
        {
            // Echoes are excluded by default, so holding a direction arms once rather than fighting
            // the navigation that follows.
            if (!@event.IsActionPressed(action))
            {
                continue;
            }

            first.GrabFocus();
            viewport.SetInputAsHandled();
            return true;
        }

        return false;
    }

    /// <summary>
    /// Moves focus, or adjusts a focused slider, for a W/A/S/D press. Returns true when it handled
    /// the event and has already marked it as handled on the viewport.
    ///
    /// Only KEY events are handled. The stick and d-pad match <c>move_*</c> too, but they are
    /// already on the <c>ui_*</c> actions and navigate correctly on their own; intercepting them
    /// would be re-implementing working engine behaviour for no gain.
    /// </summary>
    public static bool TryNavigateWithMoveKeys(Viewport viewport, InputEvent @event, Control focused)
    {
        if (@event is not InputEventKey)
        {
            return false;
        }

        Side side;
        if (@event.IsActionPressed("move_forward"))
        {
            side = Side.Top;
        }
        else if (@event.IsActionPressed("move_back"))
        {
            side = Side.Bottom;
        }
        else if (@event.IsActionPressed("move_left"))
        {
            side = Side.Left;
        }
        else if (@event.IsActionPressed("move_right"))
        {
            side = Side.Right;
        }
        else
        {
            return false;
        }

        // A FOCUSED SLIDER OWNS LEFT AND RIGHT, and without this the options screen would have no
        // way to adjust one with WASD. The arrow keys and the stick already work on a slider,
        // because Range handles ui_left/ui_right itself - A and D reach nothing, which is the same
        // gap that produced the original main-menu bug one layer down.
        //
        // Horizontal sliders only: a VSlider would consume ui_up/ui_down and swallow the row-to-row
        // navigation, which is why the options screen uses HSlider throughout.
        if (side is Side.Left or Side.Right && focused is Range range)
        {
            double step = range.Step > 0.0 ? range.Step : 1.0;
            range.Value += side == Side.Right ? step : -step;
            viewport.SetInputAsHandled();
            return true;
        }

        // The same walk the arrow keys take, so the controls' own focus neighbours stay the single
        // definition of a menu's layout - nothing here hard-codes one button above another.
        Control? next = focused.FindValidFocusNeighbor(side);
        if (next is null || next == focused)
        {
            // No neighbour that way - W at the top of a list, or any horizontal press in a column.
            // Left unhandled rather than swallowed, so it stays available to anything else.
            return false;
        }

        next.GrabFocus();
        viewport.SetInputAsHandled();
        return true;
    }
}
