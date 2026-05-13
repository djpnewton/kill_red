/// editor.zig — in-game level editor.
///
/// Toggle with F2. Edits the BodyDef list for the current level and can
/// save back to src/levels/lN.zon.
///
/// Sidebar (left, 52 px wide):
///   [->]  Select / move
///   [[] ]  Draw rect
///   [() ]  Draw circle
///   [del]  Delete selected
///   [sav]  Save to ZON
///   role colour swatches (pick role for new objects)
///
/// All positions are stored as BodyDef (fx/fy in 0-1 of 800×600 reference,
/// hw/hh/radius in reference pixels).  The canvas is treated as an 800×600
/// area scaled uniformly (same logic as loadLevel in world.zig).
const std = @import("std");
const rl = @import("raylib");
const world = @import("world.zig");

pub const Role = world.Role;
pub const ShapeKind = world.ShapeKind;
pub const BodyDef = world.BodyDef;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const SIDEBAR_W: f32 = 52;
const BTN_H: f32 = 48;
const BTN_PAD: f32 = 4;
const MAX_BODIES: usize = 64;
const REF_W: f32 = 800;
const REF_H: f32 = 600;

// ---------------------------------------------------------------------------
// Tool enum
// ---------------------------------------------------------------------------
pub const Tool = enum { select, draw_rect, draw_circle };

// ---------------------------------------------------------------------------
// EditorState
// ---------------------------------------------------------------------------
pub const EditorState = struct {
    defs: [MAX_BODIES]BodyDef,
    count: usize,
    level_index: usize,

    tool: Tool,
    active_role: Role,

    // select tool
    selected: ?usize,
    drag_offset: rl.Vector2, // canvas-space offset from body centre to mouse at grab

    // draw tool — drag to size
    draw_start: ?rl.Vector2, // canvas coords of first mouse-down
    draw_cur: rl.Vector2,

    // save feedback
    save_flash: f32, // seconds remaining for "Saved!" flash

    // rotation drag
    rotating: bool, // true while dragging the rotate handle

    // snap
    snap_grid: bool, // G key toggles; positions/sizes snap to SNAP_PX

    pub fn init(defs: []const BodyDef, level_index: usize) EditorState {
        var s = EditorState{
            .defs = undefined,
            .count = defs.len,
            .level_index = level_index,
            .tool = .select,
            .active_role = .static,
            .selected = null,
            .drag_offset = .{ .x = 0, .y = 0 },
            .draw_start = null,
            .draw_cur = .{ .x = 0, .y = 0 },
            .save_flash = 0,
            .rotating = false,
            .snap_grid = true,
        };
        for (defs, 0..) |d, i| s.defs[i] = d;
        return s;
    }

    // -----------------------------------------------------------------------
    // Canvas helpers  (screen ↔ 800×600 reference)
    // -----------------------------------------------------------------------
    fn canvasScale() f32 {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        return @min((W - SIDEBAR_W) / REF_W, H / REF_H);
    }

    fn canvasOrigin() rl.Vector2 {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        const sc = canvasScale();
        return .{
            .x = SIDEBAR_W + ((W - SIDEBAR_W) - REF_W * sc) * 0.5,
            .y = (H - REF_H * sc) * 0.5,
        };
    }

    fn screenToCanvas(screen: rl.Vector2) rl.Vector2 {
        const o = canvasOrigin();
        const sc = canvasScale();
        return .{ .x = (screen.x - o.x) / sc, .y = (screen.y - o.y) / sc };
    }

    fn canvasToScreen(canvas: rl.Vector2) rl.Vector2 {
        const o = canvasOrigin();
        const sc = canvasScale();
        return .{ .x = o.x + canvas.x * sc, .y = o.y + canvas.y * sc };
    }

    fn defCentre(d: BodyDef) rl.Vector2 {
        return .{ .x = d.fx * REF_W, .y = d.fy * REF_H };
    }

    fn hitTest(self: *EditorState, canvas_pos: rl.Vector2) ?usize {
        // iterate backwards so top-drawn body is hit first
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const d = self.defs[i];
            const c = defCentre(d);
            const hit = switch (d.shape) {
                .rect => blk: {
                    // transform into body local frame to handle rotation
                    const ca = @cos(d.angle);
                    const sa = @sin(d.angle);
                    const dx = canvas_pos.x - c.x;
                    const dy = canvas_pos.y - c.y;
                    const lx = dx * ca + dy * sa;
                    const ly = -dx * sa + dy * ca;
                    break :blk @abs(lx) <= d.hw and @abs(ly) <= d.hh;
                },
                .circle => dist(canvas_pos, c) <= d.radius,
            };
            if (hit) return i;
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Update
    // -----------------------------------------------------------------------
    pub fn update(self: *EditorState, io: std.Io) void {
        self.save_flash -= rl.getFrameTime();
        if (self.save_flash < 0) self.save_flash = 0;

        const mouse = rl.getMousePosition();
        const canvas = screenToCanvas(mouse);
        const in_canvas = mouse.x >= SIDEBAR_W;

        // G: toggle snap
        if (rl.isKeyPressed(.g)) self.snap_grid = !self.snap_grid;

        // tool hotkeys
        if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.one)) {
            self.tool = .select;
            self.draw_start = null;
        }
        if (rl.isKeyPressed(.two)) {
            self.tool = .draw_rect;
            self.draw_start = null;
            self.selected = null;
        }
        if (rl.isKeyPressed(.three)) {
            self.tool = .draw_circle;
            self.draw_start = null;
            self.selected = null;
        }
        // copy / delete hotkeys
        if (rl.isKeyPressed(.c)) self.copyBody();
        if (rl.isKeyPressed(.delete) or rl.isKeyPressed(.backspace)) {
            if (self.selected) |idx| self.deleteBody(idx);
        }

        // --- sidebar clicks ---
        if (rl.isMouseButtonPressed(.left) and mouse.x < SIDEBAR_W) {
            self.handleSidebarClick(io, mouse.y);
            return;
        }

        // --- canvas interaction ---
        switch (self.tool) {
            .select => self.updateSelect(canvas, in_canvas),
            .draw_rect => self.updateDraw(.rect, canvas, in_canvas),
            .draw_circle => self.updateDraw(.circle, canvas, in_canvas),
        }
    }

    fn handleSidebarClick(self: *EditorState, io: std.Io, my: f32) void {
        const btn_y = btnY;
        const tools = [_]Tool{ .select, .draw_rect, .draw_circle };
        for (tools, 0..) |t, i| {
            const y = btn_y(@intCast(i));
            if (my >= y and my < y + BTN_H) {
                self.tool = t;
                self.draw_start = null;
                self.selected = null;
                return;
            }
        }
        // delete button
        {
            const y = btn_y(3);
            if (my >= y and my < y + BTN_H) {
                if (self.selected) |idx| {
                    self.deleteBody(idx);
                }
                return;
            }
        }
        // copy button
        {
            const y = btn_y(4);
            if (my >= y and my < y + BTN_H) {
                self.copyBody();
                return;
            }
        }
        // save button
        {
            const y = btn_y(5);
            if (my >= y and my < y + BTN_H) {
                self.save(io) catch {};
                return;
            }
        }
        // save-new button
        {
            const y = btn_y(6);
            if (my >= y and my < y + BTN_H) {
                self.saveNew(io) catch {};
                return;
            }
        }
        // role swatches — stacked below save-new
        const roles = [_]Role{ .static, .red, .red_hard, .support, .green };
        for (roles, 0..) |r, i| {
            const y = btn_y(7) + @as(f32, @floatFromInt(i)) * (BTN_H * 0.6 + BTN_PAD);
            if (my >= y and my < y + BTN_H * 0.6) {
                self.active_role = r;
                return;
            }
        }
    }

    fn updateSelect(self: *EditorState, canvas: rl.Vector2, in_canvas: bool) void {
        if (!in_canvas) {
            if (rl.isMouseButtonReleased(.left)) self.rotating = false;
            return;
        }

        const mouse = rl.getMousePosition();
        const sc = canvasScale();
        const o = canvasOrigin();

        if (rl.isMouseButtonReleased(.left)) {
            self.rotating = false;
        }

        if (rl.isMouseButtonPressed(.left)) {
            // check rotation handle first (only when something is selected)
            if (self.selected) |idx| {
                const hp = rotHandlePos(self.defs[idx], sc, o);
                if (dist(mouse, hp) < 12) {
                    self.rotating = true;
                    const cx = o.x + self.defs[idx].fx * REF_W * sc;
                    const cy = o.y + self.defs[idx].fy * REF_H * sc;
                    const ma = std.math.atan2(mouse.x - cx, -(mouse.y - cy));
                    self.drag_offset.x = self.defs[idx].angle - ma;
                    return;
                }
            }
            // regular select / start-move
            if (self.hitTest(canvas)) |idx| {
                self.selected = idx;
                const c = defCentre(self.defs[idx]);
                self.drag_offset = .{ .x = canvas.x - c.x, .y = canvas.y - c.y };
            } else {
                self.selected = null;
            }
        }

        if (rl.isMouseButtonDown(.left)) {
            if (self.rotating) {
                if (self.selected) |idx| {
                    const cx = o.x + self.defs[idx].fx * REF_W * sc;
                    const cy = o.y + self.defs[idx].fy * REF_H * sc;
                    const ma = std.math.atan2(mouse.x - cx, -(mouse.y - cy));
                    var angle = ma + self.drag_offset.x;
                    if (self.snap_grid) angle = snapAngle(angle);
                    self.defs[idx].angle = angle;
                }
            } else {
                if (self.selected) |idx| {
                    var nx = canvas.x - self.drag_offset.x;
                    var ny = canvas.y - self.drag_offset.y;
                    if (self.snap_grid) {
                        nx = snapPx(nx);
                        ny = snapPx(ny);
                    }
                    self.defs[idx].fx = nx / REF_W;
                    self.defs[idx].fy = ny / REF_H;
                }
            }
        }
    }

    fn updateDraw(self: *EditorState, shape: ShapeKind, canvas: rl.Vector2, in_canvas: bool) void {
        if (!in_canvas) return;
        const snapped = if (self.snap_grid) snapVec(canvas) else canvas;
        self.draw_cur = snapped;

        if (rl.isMouseButtonPressed(.left)) {
            self.draw_start = snapped;
        }

        if (rl.isMouseButtonReleased(.left)) {
            if (self.draw_start) |start| {
                const dx = @abs(snapped.x - start.x);
                const dy = @abs(snapped.y - start.y);
                const min_size: f32 = 4;
                if ((shape == .rect and dx > min_size and dy > min_size) or
                    (shape == .circle and dx > min_size))
                {
                    if (self.count < MAX_BODIES) {
                        const cx = (start.x + snapped.x) * 0.5;
                        const cy = (start.y + snapped.y) * 0.5;
                        self.defs[self.count] = BodyDef{
                            .fx = cx / REF_W,
                            .fy = cy / REF_H,
                            .shape = shape,
                            .role = self.active_role,
                            .hw = if (shape == .rect) dx * 0.5 else 0,
                            .hh = if (shape == .rect) dy * 0.5 else 0,
                            .radius = if (shape == .circle) dx * 0.5 else 0,
                        };
                        self.count += 1;
                    }
                }
                self.draw_start = null;
            }
        }
    }

    fn deleteBody(self: *EditorState, idx: usize) void {
        if (idx >= self.count) return;
        var i = idx;
        while (i + 1 < self.count) : (i += 1) {
            self.defs[i] = self.defs[i + 1];
        }
        self.count -= 1;
        self.selected = null;
    }

    fn copyBody(self: *EditorState) void {
        const idx = self.selected orelse return;
        if (self.count >= MAX_BODIES) return;
        var copy = self.defs[idx];
        copy.fx += 12.0 / REF_W; // nudge 12 px right so it\'s visible
        copy.fy += 12.0 / REF_H;
        self.defs[self.count] = copy;
        self.selected = self.count;
        self.count += 1;
    }

    // -----------------------------------------------------------------------
    // Save  (writes src/levels/lN.zon relative to cwd — works when run from
    // the project root, which `zig build run` always does)
    // -----------------------------------------------------------------------
    pub fn save(self: *EditorState, io: std.Io) !void {
        try self.writeZon(io, self.level_index);
    }

    pub fn saveNew(self: *EditorState, io: std.Io) !void {
        // Find the next unused lN.zon index by probing files on disk.
        // We simply use levels.len as the new index (appended after existing).
        const new_index = world.levelsSlice().len;
        try self.writeZon(io, new_index);
        self.level_index = new_index;
    }

    fn writeZon(self: *EditorState, io: std.Io, index: usize) !void {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "src/levels/l{d}.zon", .{index});

        // Build content into a fixed buffer (16 KiB is plenty for a level file)
        var content_buf: [16 * 1024]u8 = undefined;
        var pos: usize = 0;

        const w = struct {
            buf: []u8,
            pos: *usize,
            fn writeAll(ctx: @This(), s: []const u8) error{NoSpaceLeft}!void {
                if (ctx.pos.* + s.len > ctx.buf.len) return error.NoSpaceLeft;
                @memcpy(ctx.buf[ctx.pos.*..][0..s.len], s);
                ctx.pos.* += s.len;
            }
            fn print(ctx: @This(), comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}!void {
                const written = std.fmt.bufPrint(ctx.buf[ctx.pos.*..], fmt, args) catch return error.NoSpaceLeft;
                ctx.pos.* += written.len;
            }
        }{ .buf = &content_buf, .pos = &pos };

        try w.writeAll(".{\n");
        // banner: reuse the existing banner from the compiled levels table
        const ls = world.levelsSlice();
        const banner = if (index < ls.len) ls[index].banner else null;
        if (banner) |b| {
            try w.print("    .banner = \"{s}\",\n", .{b});
        } else {
            try w.writeAll("    .banner = null,\n");
        }
        try w.writeAll("    .defs = .{\n");
        for (self.defs[0..self.count]) |d| {
            try w.writeAll("        .{");
            try w.print(" .fx = {d:.4}, .fy = {d:.4}", .{ d.fx, d.fy });
            if (d.shape == .rect) {
                try w.print(", .hw = {d:.2}, .hh = {d:.2}, .shape = .rect", .{ d.hw, d.hh });
            } else {
                try w.print(", .radius = {d:.2}", .{d.radius});
            }
            try w.print(", .role = .{s}", .{@tagName(d.role)});
            if (d.vx != 0) try w.print(", .vx = {d:.2}", .{d.vx});
            if (d.vy != 0) try w.print(", .vy = {d:.2}", .{d.vy});
            if (d.angle != 0) try w.print(", .angle = {d:.4}", .{d.angle});
            try w.writeAll(" },\n");
        }
        try w.writeAll("    },\n}\n");

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content_buf[0..pos] });
        // Update the runtime level table so reloadCurrentLevel() sees changes
        // immediately without a rebuild.
        world.updateLevelDefs(index, self.defs[0..self.count]);
        self.save_flash = 2.0;
    }

    // -----------------------------------------------------------------------
    // Draw
    // -----------------------------------------------------------------------
    pub fn draw(self: *EditorState) void {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.init(20, 20, 28, 255));

        const sc = canvasScale();
        const o = canvasOrigin();

        // canvas background
        rl.drawRectangleV(o, .{ .x = REF_W * sc, .y = REF_H * sc }, rl.Color.init(30, 30, 40, 255));

        // reference grid (every 80px = 1 Box2D metre in the reference)
        {
            const step: f32 = 80.0 * sc;
            var x: f32 = o.x;
            while (x <= o.x + REF_W * sc + 1) : (x += step) {
                rl.drawLineV(.{ .x = x, .y = o.y }, .{ .x = x, .y = o.y + REF_H * sc }, rl.Color.init(50, 50, 65, 255));
            }
            var y: f32 = o.y;
            while (y <= o.y + REF_H * sc + 1) : (y += step) {
                rl.drawLineV(.{ .x = o.x, .y = y }, .{ .x = o.x + REF_W * sc, .y = y }, rl.Color.init(50, 50, 65, 255));
            }
        }

        // bodies
        for (self.defs[0..self.count], 0..) |d, i| {
            const col = roleColor(d.role);
            const cx = o.x + d.fx * REF_W * sc;
            const cy = o.y + d.fy * REF_H * sc;
            const selected = if (self.selected) |s| s == i else false;
            const outline = if (selected) rl.Color.yellow else rl.Color.ray_white.alpha(0.35);
            switch (d.shape) {
                .rect => {
                    const hw = d.hw * sc;
                    const hh = d.hh * sc;
                    const deg = d.angle * (180.0 / std.math.pi);
                    rl.drawRectanglePro(
                        .{ .x = cx, .y = cy, .width = hw * 2, .height = hh * 2 },
                        .{ .x = hw, .y = hh },
                        deg,
                        col,
                    );
                    // rotated outline via corners
                    const ca = @cos(d.angle);
                    const sa = @sin(d.angle);
                    const corners = [4]rl.Vector2{
                        .{ .x = cx - hw * ca + hh * sa, .y = cy - hw * sa - hh * ca },
                        .{ .x = cx + hw * ca + hh * sa, .y = cy + hw * sa - hh * ca },
                        .{ .x = cx + hw * ca - hh * sa, .y = cy + hw * sa + hh * ca },
                        .{ .x = cx - hw * ca - hh * sa, .y = cy - hw * sa + hh * ca },
                    };
                    rl.drawLineV(corners[0], corners[1], outline);
                    rl.drawLineV(corners[1], corners[2], outline);
                    rl.drawLineV(corners[2], corners[3], outline);
                    rl.drawLineV(corners[3], corners[0], outline);
                },
                .circle => {
                    rl.drawCircleV(.{ .x = cx, .y = cy }, d.radius * sc, col);
                    rl.drawCircleLines(@intFromFloat(cx), @intFromFloat(cy), d.radius * sc, outline);
                },
            }
        }

        // rotation handle (select tool, something selected)
        if (self.tool == .select) {
            if (self.selected) |idx| {
                const d = self.defs[idx];
                const cx = o.x + d.fx * REF_W * sc;
                const cy = o.y + d.fy * REF_H * sc;
                const hp = rotHandlePos(d, sc, o);
                const arm_col = if (self.rotating) rl.Color.yellow else rl.Color.ray_white.alpha(0.55);
                rl.drawLineV(.{ .x = cx, .y = cy }, hp, arm_col);
                const handle_col = if (self.rotating) rl.Color.yellow else rl.Color.init(180, 220, 255, 255);
                rl.drawCircleV(hp, 8, handle_col);
                rl.drawCircleLines(@intFromFloat(hp.x), @intFromFloat(hp.y), 8, rl.Color.ray_white);
            }
        }

        // draw-in-progress ghost
        if (self.draw_start) |start| {
            const sp = canvasToScreen(start);
            const ep = canvasToScreen(self.draw_cur);
            const col = roleColor(self.active_role).alpha(0.55);
            switch (self.tool) {
                .draw_rect => {
                    const x = @min(sp.x, ep.x);
                    const y = @min(sp.y, ep.y);
                    const w = @abs(ep.x - sp.x);
                    const h = @abs(ep.y - sp.y);
                    rl.drawRectangleV(.{ .x = x, .y = y }, .{ .x = w, .y = h }, col);
                    drawRectOutline(x, y, w, h, rl.Color.ray_white.alpha(0.6));
                },
                .draw_circle => {
                    const r = @abs(ep.x - sp.x) * 0.5;
                    const mx = (sp.x + ep.x) * 0.5;
                    const my = (sp.y + ep.y) * 0.5;
                    rl.drawCircleV(.{ .x = mx, .y = my }, r, col);
                    rl.drawCircleLines(@intFromFloat(mx), @intFromFloat(my), r, rl.Color.ray_white.alpha(0.6));
                },
                else => {},
            }
        }

        // sidebar
        self.drawSidebar();
    }

    fn drawSidebar(self: *EditorState) void {
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        rl.drawRectangle(0, 0, @intFromFloat(SIDEBAR_W), @intFromFloat(H), rl.Color.init(24, 24, 32, 255));
        rl.drawLineV(.{ .x = SIDEBAR_W, .y = 0 }, .{ .x = SIDEBAR_W, .y = H }, rl.Color.init(60, 60, 80, 255));

        const tools = [_]Tool{ .select, .draw_rect, .draw_circle };
        const tool_labels = [_][:0]const u8{ "\x97", "\x1a", "\x0f" }; // fallback ASCII
        const tool_glyphs = [_][:0]const u8{ "->", "[]", "()" };
        _ = tool_labels;
        for (tools, 0..) |t, i| {
            const y = btnY(@intCast(i));
            const active = self.tool == t;
            const bg = if (active) rl.Color.init(60, 100, 160, 255) else rl.Color.init(38, 38, 52, 255);
            rl.drawRectangle(@intFromFloat(BTN_PAD), @intFromFloat(y), @intFromFloat(SIDEBAR_W - BTN_PAD * 2), @intFromFloat(BTN_H - BTN_PAD), bg);
            rl.drawText(tool_glyphs[i], @intFromFloat(BTN_PAD + 6), @intFromFloat(y + (BTN_H - BTN_PAD) * 0.5 - 7), 14, rl.Color.ray_white);
        }

        // delete button
        {
            const y = btnY(3);
            const has_sel = self.selected != null;
            const bg = if (has_sel) rl.Color.init(140, 40, 40, 255) else rl.Color.init(60, 30, 30, 255);
            rl.drawRectangle(@intFromFloat(BTN_PAD), @intFromFloat(y), @intFromFloat(SIDEBAR_W - BTN_PAD * 2), @intFromFloat(BTN_H - BTN_PAD), bg);
            rl.drawText("del", @intFromFloat(BTN_PAD + 4), @intFromFloat(y + (BTN_H - BTN_PAD) * 0.5 - 7), 13, rl.Color.ray_white);
        }

        // copy button
        {
            const y = btnY(4);
            const has_sel = self.selected != null;
            const bg = if (has_sel) rl.Color.init(80, 80, 160, 255) else rl.Color.init(40, 40, 80, 255);
            rl.drawRectangle(@intFromFloat(BTN_PAD), @intFromFloat(y), @intFromFloat(SIDEBAR_W - BTN_PAD * 2), @intFromFloat(BTN_H - BTN_PAD), bg);
            rl.drawText("cpy", @intFromFloat(BTN_PAD + 4), @intFromFloat(y + (BTN_H - BTN_PAD) * 0.5 - 7), 13, rl.Color.ray_white);
        }

        // save button
        {
            const y = btnY(5);
            const bg = rl.Color.init(40, 100, 60, 255);
            rl.drawRectangle(@intFromFloat(BTN_PAD), @intFromFloat(y), @intFromFloat(SIDEBAR_W - BTN_PAD * 2), @intFromFloat(BTN_H - BTN_PAD), bg);
            rl.drawText("sav", @intFromFloat(BTN_PAD + 4), @intFromFloat(y + (BTN_H - BTN_PAD) * 0.5 - 7), 13, rl.Color.ray_white);
        }

        // save-new button
        {
            const y = btnY(6);
            const bg = rl.Color.init(30, 70, 100, 255);
            rl.drawRectangle(@intFromFloat(BTN_PAD), @intFromFloat(y), @intFromFloat(SIDEBAR_W - BTN_PAD * 2), @intFromFloat(BTN_H - BTN_PAD), bg);
            rl.drawText("+nw", @intFromFloat(BTN_PAD + 4), @intFromFloat(y + (BTN_H - BTN_PAD) * 0.5 - 7), 13, rl.Color.ray_white);
        }

        // role swatches
        const roles = [_]Role{ .static, .red, .red_hard, .support, .green };
        const sw_h: f32 = BTN_H * 0.6;
        for (roles, 0..) |r, i| {
            const y = btnY(7) + @as(f32, @floatFromInt(i)) * (sw_h + BTN_PAD);
            const col = roleColor(r);
            const active = self.active_role == r;
            rl.drawRectangle(@intFromFloat(BTN_PAD), @intFromFloat(y), @intFromFloat(SIDEBAR_W - BTN_PAD * 2), @intFromFloat(sw_h), col);
            if (active) {
                rl.drawRectangleLines(@intFromFloat(BTN_PAD), @intFromFloat(y), @intFromFloat(SIDEBAR_W - BTN_PAD * 2), @intFromFloat(sw_h), rl.Color.ray_white);
            }
        }

        // save flash
        if (self.save_flash > 0) {
            rl.drawText("Saved!", 2, @intFromFloat(H - 22), 13, rl.Color.init(80, 230, 80, 255));
        }

        // snap indicator
        const snap_col = if (self.snap_grid) rl.Color.init(100, 220, 140, 255) else rl.Color.init(100, 100, 120, 200);
        rl.drawText(if (self.snap_grid) "G:snp" else "G:---", 2, @intFromFloat(H - 54), 11, snap_col);

        // hint
        rl.drawText("F2:play", 2, @intFromFloat(H - 40), 11, rl.Color.init(120, 120, 140, 255));
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn btnY(idx: i32) f32 {
    return BTN_PAD + @as(f32, @floatFromInt(idx)) * (BTN_H + BTN_PAD);
}

fn dist(a: rl.Vector2, b: rl.Vector2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

const SNAP_PX: f32 = 10.0; // reference-space pixels

fn snapPx(v: f32) f32 {
    return @round(v / SNAP_PX) * SNAP_PX;
}

fn snapVec(v: rl.Vector2) rl.Vector2 {
    return .{ .x = snapPx(v.x), .y = snapPx(v.y) };
}

fn snapAngle(a: f32) f32 {
    const step = std.math.pi / 12.0; // 15 degrees
    return @round(a / step) * step;
}

// Returns the screen position of the rotation handle for a body.
// The handle floats 24px beyond the body's max extent, along the body's
// local "up" axis (perpendicular to the rotation angle).
fn rotHandlePos(d: BodyDef, sc: f32, o: rl.Vector2) rl.Vector2 {
    const cx = o.x + d.fx * REF_W * sc;
    const cy = o.y + d.fy * REF_H * sc;
    const extent = switch (d.shape) {
        .rect => @max(d.hw, d.hh) * sc,
        .circle => d.radius * sc,
    };
    const arm = extent + 24.0;
    return .{
        .x = cx + @sin(d.angle) * arm,
        .y = cy - @cos(d.angle) * arm,
    };
}

fn drawRectOutline(x: f32, y: f32, w: f32, h: f32, col: rl.Color) void {
    rl.drawLineV(.{ .x = x, .y = y }, .{ .x = x + w, .y = y }, col);
    rl.drawLineV(.{ .x = x + w, .y = y }, .{ .x = x + w, .y = y + h }, col);
    rl.drawLineV(.{ .x = x + w, .y = y + h }, .{ .x = x, .y = y + h }, col);
    rl.drawLineV(.{ .x = x, .y = y + h }, .{ .x = x, .y = y }, col);
}

pub fn roleColor(role: Role) rl.Color {
    return switch (role) {
        .red => rl.Color.init(230, 80, 80, 255),
        .red_hard => rl.Color.init(120, 20, 20, 255),
        .support => rl.Color.init(100, 180, 230, 255),
        .green => rl.Color.green,
        .static => rl.Color.dark_gray,
    };
}
