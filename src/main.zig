const std = @import("std");
const Io = std.Io;

const rl = @import("raylib");
const rg = @import("raygui");

const world = @import("world.zig");

pub fn main(_: std.process.Init) !void {
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

    // Main game loop
    while (!rl.windowShouldClose()) {
        // Update
        //----------------------------------------------------------------------------------
        world.activeMap().update();

        // Draw
        //------------------------------------------------------------------------------------
        world.draw();
    }
}
