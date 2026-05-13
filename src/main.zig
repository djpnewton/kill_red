const std = @import("std");
const Io = std.Io;

const rl = @import("raylib");
const rg = @import("raygui");

const world = @import("world.zig");
const editor = @import("editor.zig");
const config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Initialization
    //--------------------------------------------------------------------------------------

    const screenWidth = 800;
    const screenHeight = 600;

    rl.setGesturesEnabled(.{ .tap = true });
    rl.setConfigFlags(rl.ConfigFlags{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(screenWidth, screenHeight, "kill red");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    //--------------------------------------------------------------------------------------

    var ed: ?editor.EditorState = null;

    // Main game loop
    while (!rl.windowShouldClose()) {
        // F2: toggle editor for the current level
        if (rl.isKeyPressed(.f2)) {
            if (ed != null) {
                // returning from editor — reload the level so physics reflect any saved changes
                ed = null;
                world.reloadCurrentLevel();
            } else {
                const map = world.activeMap();
                ed = editor.EditorState.init(world.levelDefs(map.level), map.level);
            }
        }

        if (ed) |*e| {
            e.update(io);
            e.draw();
        } else {
            if (config.DEBUG) {
                const line1 = "*DEBUG* Space: reset  |  Right-click: drag";
                const line2 = "1-9: jump to level | F2: edit current level";
                const font_size = 14;
                const full = "*DEBUG* Space: reset  |  Right-click: drag  |  1-9: jump to level | F2: edit current level";
                if (rl.getScreenWidth() >= rl.measureText(full, font_size) + 20) {
                    rl.drawText(full, 10, 10, font_size, rl.Color.init(160, 160, 160, 200));
                } else {
                    rl.drawText(line1, 10, 10, font_size, rl.Color.init(160, 160, 160, 200));
                    rl.drawText(line2, 10, 10 + font_size + 2, font_size, rl.Color.init(160, 160, 160, 200));
                }
            }

            world.activeMap().update();
            world.draw();
        }
    }
}
