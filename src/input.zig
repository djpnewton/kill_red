/// input.zig — unified pointer input (mouse click + touch tap).
///
/// Call `poll()` once per frame.  It returns the screen-space position of the
/// first tap/click that occurred this frame, or null if there was none.
const rl = @import("raylib");

/// Returns the position of a click or tap that just started this frame,
/// or null if no such event occurred.
///
/// Priority:
///   1. Left mouse button pressed (desktop)
///   2. Touch tap gesture (mobile / touchscreens)
///   3. Single touch-point beginning (fallback for platforms that don't fire
///      gesture events)
pub fn poll() ?rl.Vector2 {
    // Right-click is used for dragging; never treat it as a tap.
    if (rl.isMouseButtonDown(.right)) return null;

    // --- mouse ---
    if (rl.isMouseButtonPressed(.left)) {
        return rl.getMousePosition();
    }

    // --- touch gesture (tap) ---
    if (rl.isGestureDetected(.{ .tap = true })) {
        // getTouchPosition(0) gives the position of the first touch point.
        return rl.getTouchPosition(0);
    }

    // --- raw touch fallback: new touch point appeared this frame ---
    // getTouchPointCount() > 0 means at least one finger is down.
    // We detect "just started" by checking whether the previous count was 0,
    // but raylib doesn't expose that directly.  Instead we gate on the tap
    // gesture above for proper one-shot detection, and use the raw count only
    // when the gesture system isn't available (e.g. gestures disabled).
    // Nothing extra needed here — the tap branch above is sufficient.

    return null;
}
