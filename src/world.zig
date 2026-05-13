/// world.zig — game world: level definitions, Box2D 3.x physics, and rendering.
///
/// Roles:
///   .red      — light red:  click/tap to destroy
///   .red_hard — dark red:   cannot be clicked; must be knocked or dropped off-screen
///   .support  — light blue: neutral clickable platform; removing it drops whatever rests on top
///   .green    — must survive; losing all green objects ends the level
///   .static   — immovable terrain (platforms, ground)
///
/// Physics: Box2D 3.x (C library). PPM = 80 pixels per metre.
const std = @import("std");
const rl = @import("raylib");
const input = @import("input.zig");
const b2 = @import("box2d.zig").c;

const DEBUG = true;

// ---------------------------------------------------------------------------
// Coordinate helpers  (screen pixels <-> Box2D metres, Y-down in both)
// ---------------------------------------------------------------------------

const PPM: f32 = 80.0; // pixels per metre

fn toMetres(px: f32) f32 {
    return px / PPM;
}
fn toPixels(m: f32) f32 {
    return m * PPM;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const Role = enum { red, red_hard, support, green, static };
pub const ShapeKind = enum { circle, rect };

pub const Body = struct {
    pos: rl.Vector2, // pixels, synced from Box2D each frame
    hw: f32, // half-width  pixels (rect)
    hh: f32, // half-height pixels (rect)
    radius: f32, // pixels (circle)
    shape: ShapeKind,
    role: Role,
    alive: bool,
    angle: f32, // radians, from Box2D
    body_id: b2.b2BodyId,

    pub fn toRec(self: Body) rl.Rectangle {
        return .{ .x = self.pos.x - self.hw, .y = self.pos.y - self.hh, .width = self.hw * 2, .height = self.hh * 2 };
    }
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MAX_BODIES: usize = 64;
const B2_GRAVITY: f32 = 10.0; // m/s^2 downward
const B2_RESTITUTION: f32 = 0.3;
const B2_FRICTION: f32 = 0.5;
const B2_SUBSTEPS: c_int = 4;

// ---------------------------------------------------------------------------
// Map
// ---------------------------------------------------------------------------

pub const Map = struct {
    bodies: [MAX_BODIES]Body,
    count: usize,
    level: usize,
    drag_idx: ?usize,
    world_id: b2.b2WorldId,
    show_banner: bool,
    has_green: bool,
    show_failed: bool,
    show_complete: bool,

    pub fn update(self: *Map) void {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());

        // --- space bar: reset current level ---
        if (rl.isKeyPressed(.space)) {
            self.destroyWorld();
            self.* = loadLevel(self.level);
            return;
        }

        // --- number keys: teleport to level (DEBUG only) ---
        if (DEBUG) {
            const keys = [_]rl.KeyboardKey{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine };
            for (keys, 0..) |key, i| {
                if (i < levels.len and rl.isKeyPressed(key)) {
                    self.destroyWorld();
                    self.* = loadLevel(i);
                    return;
                }
            }
        }

        // --- complete overlay: restart from level 0 on click ---
        if (self.show_complete) {
            if (rl.isMouseButtonPressed(.left) or rl.isGestureDetected(.{ .tap = true })) {
                self.destroyWorld();
                self.* = loadLevel(0);
            }
            return;
        }

        // --- failed overlay: restart on click ---
        if (self.show_failed) {
            if (rl.isMouseButtonPressed(.left) or rl.isGestureDetected(.{ .tap = true })) {
                self.destroyWorld();
                self.* = loadLevel(self.level);
            }
            return;
        }

        // --- banner overlay: pause until dismissed ---
        if (self.show_banner) {
            if (rl.isMouseButtonPressed(.left) or rl.isGestureDetected(.{ .tap = true })) {
                self.show_banner = false;
            }
            return;
        }

        // --- right-click drag ---
        if (DEBUG) {
            const drag_mouse = rl.getMousePosition();
            if (rl.isMouseButtonPressed(.right)) {
                self.drag_idx = null;
                var k: usize = self.count;
                while (k > 0) {
                    k -= 1;
                    const b = &self.bodies[k];
                    if (!b.alive or b.role == .static) continue;
                    const hit = switch (b.shape) {
                        .circle => rl.checkCollisionPointCircle(drag_mouse, b.pos, b.radius),
                        .rect => rl.checkCollisionPointRec(drag_mouse, b.toRec()),
                    };
                    if (hit) {
                        self.drag_idx = k;
                        break;
                    }
                }
            }
            if (rl.isMouseButtonDown(.right)) {
                if (self.drag_idx) |k| {
                    const b = &self.bodies[k];
                    if (b.alive) {
                        b2.b2Body_SetTransform(b.body_id, .{ .x = toMetres(drag_mouse.x), .y = toMetres(drag_mouse.y) }, b2.b2MakeRot(b.angle));
                        b2.b2Body_SetLinearVelocity(b.body_id, .{ .x = 0, .y = 0 });
                        b2.b2Body_SetAngularVelocity(b.body_id, 0);
                    }
                }
            } else {
                if (self.drag_idx) |k| {
                    const b = &self.bodies[k];
                    if (b.alive) b2.b2Body_SetAwake(b.body_id, true);
                }
                self.drag_idx = null;
            }
        }

        // --- restart button (bottom-left) ---
        {
            const H_f: f32 = @floatFromInt(rl.getScreenHeight());
            const btn_w: f32 = 90;
            const btn_h: f32 = 32;
            const btn_rec = rl.Rectangle{ .x = 12, .y = H_f - btn_h - 12, .width = btn_w, .height = btn_h };
            if (rl.isMouseButtonPressed(.left)) {
                if (rl.checkCollisionPointRec(rl.getMousePosition(), btn_rec)) {
                    self.destroyWorld();
                    self.* = loadLevel(self.level);
                    return;
                }
            }
        }

        // --- input: click to remove light-red or support ---
        if (input.poll()) |tap| {
            for (self.bodies[0..self.count]) |*b| {
                if (!b.alive) continue;
                if (b.role != .red and b.role != .support) continue;
                const hit = switch (b.shape) {
                    .circle => rl.checkCollisionPointCircle(tap, b.pos, b.radius),
                    .rect => rl.checkCollisionPointRec(tap, b.toRec()),
                };
                if (hit) {
                    b.alive = false;
                    b2.b2DestroyBody(b.body_id);
                    break;
                }
            }
        }

        // --- step Box2D ---
        const dt = rl.getFrameTime();
        if (dt > 0) {
            b2.b2World_Step(self.world_id, dt, B2_SUBSTEPS);
        }

        // --- sync positions/angles; kill off-screen bodies ---
        for (self.bodies[0..self.count]) |*b| {
            if (!b.alive or b.role == .static) continue;

            const p = b2.b2Body_GetPosition(b.body_id);
            const r = b2.b2Body_GetRotation(b.body_id);
            b.pos.x = toPixels(p.x);
            b.pos.y = toPixels(p.y);
            b.angle = b2.b2Rot_GetAngle(r);

            const ext_x = if (b.shape == .rect) b.hw else b.radius;
            const ext_y = if (b.shape == .rect) b.hh else b.radius;

            if (b.pos.y - ext_y > H or
                b.pos.x + ext_x < 0 or
                b.pos.x - ext_x > W or
                b.pos.y + ext_y < 0)
            {
                if (b.role == .green) self.show_failed = true;
                b.alive = false;
                b2.b2DestroyBody(b.body_id);
            }
        }

        // If a green body just fell off, show the failed screen and stop.
        if (self.show_failed) return;

        // --- advance level ---
        var red_count: usize = 0;
        var green_alive: usize = 0;
        var green_settled: bool = true;
        for (self.bodies[0..self.count]) |*b| {
            if (!b.alive) continue;
            if (b.role == .red or b.role == .red_hard) red_count += 1;
            if (b.role == .green) {
                green_alive += 1;
                if (b2.b2Body_IsAwake(b.body_id)) green_settled = false;
            }
        }
        if (red_count == 0 and green_settled and (!self.has_green or green_alive > 0)) {
            if (self.level + 1 >= levels.len) {
                self.show_complete = true;
            } else {
                self.destroyWorld();
                self.* = loadLevel(self.level + 1);
            }
        }
    }

    fn destroyWorld(self: *Map) void {
        b2.b2DestroyWorld(self.world_id);
    }
};

// ---------------------------------------------------------------------------
// Level definitions
// ---------------------------------------------------------------------------

const BodyDef = struct {
    fx: f32,
    fy: f32,
    radius: f32 = 0,
    hw: f32 = 0,
    hh: f32 = 0,
    shape: ShapeKind = .circle,
    role: Role,
    vx: f32 = 0,
    vy: f32 = 0,
    angle: f32 = 0, // radians; applied to body rotation at spawn
};

const LevelDef = struct {
    defs_arr: [MAX_BODIES]BodyDef,
    count: usize,
    banner: ?[:0]const u8 = null,
};

/// Convert a ZON tuple of anonymous body-def structs to a typed BodyDef array.
/// ZON structs omit default-valued fields, so we map each field explicitly.
fn parseZonDefs(comptime tup: anytype) [std.meta.fields(@TypeOf(tup)).len]BodyDef {
    const N = std.meta.fields(@TypeOf(tup)).len;
    var arr: [N]BodyDef = undefined;
    inline for (std.meta.fields(@TypeOf(tup)), 0..) |f, i| {
        const elem = @field(tup, f.name);
        const T = @TypeOf(elem);
        arr[i] = BodyDef{
            .fx = elem.fx,
            .fy = elem.fy,
            .radius = if (@hasField(T, "radius")) elem.radius else 0,
            .hw = if (@hasField(T, "hw")) elem.hw else 0,
            .hh = if (@hasField(T, "hh")) elem.hh else 0,
            .shape = if (@hasField(T, "shape")) elem.shape else .circle,
            .role = elem.role,
            .vx = if (@hasField(T, "vx")) elem.vx else 0,
            .vy = if (@hasField(T, "vy")) elem.vy else 0,
            .angle = if (@hasField(T, "angle")) elem.angle else 0,
        };
    }
    return arr;
}

fn zonToLevel(comptime zon: anytype) LevelDef {
    const parsed = parseZonDefs(zon.defs);
    var def: LevelDef = .{ .defs_arr = undefined, .count = parsed.len, .banner = zon.banner };
    inline for (0..parsed.len) |i| def.defs_arr[i] = parsed[i];
    return def;
}

const levels = [_]LevelDef{
    zonToLevel(@import("levels/l0.zon")),
    zonToLevel(@import("levels/l1.zon")),
    zonToLevel(@import("levels/l2.zon")),
    zonToLevel(@import("levels/l3.zon")),
};

// ---------------------------------------------------------------------------
// Level loading
// ---------------------------------------------------------------------------

fn loadLevel(index: usize) Map {
    const W: f32 = @floatFromInt(rl.getScreenWidth());
    const H: f32 = @floatFromInt(rl.getScreenHeight());
    const def = &levels[index];

    var world_def = b2.b2DefaultWorldDef();
    world_def.gravity = .{ .x = 0, .y = B2_GRAVITY };
    const world_id = b2.b2CreateWorld(&world_def);

    var shape_def = b2.b2DefaultShapeDef();
    shape_def.material.restitution = B2_RESTITUTION;
    shape_def.material.friction = B2_FRICTION;

    var m = Map{
        .bodies = undefined,
        .count = def.count,
        .level = index,
        .drag_idx = null,
        .world_id = world_id,
        .show_banner = def.banner != null,
        .has_green = false,
        .show_failed = false,
        .show_complete = false,
    };

    for (def.defs_arr[0..def.count], 0..) |d, i| {
        // Uniform scale from fixed 800x600 reference so physics distances
        // are identical on every screen size. World is centered (letterboxed).
        const scale: f32 = @min(W / 800.0, H / 600.0);
        const ox: f32 = (W - 800.0 * scale) * 0.5;
        const oy: f32 = (H - 600.0 * scale) * 0.5;
        const px: f32 = ox + d.fx * 800.0 * scale;
        const py: f32 = oy + d.fy * 600.0 * scale;
        const hw: f32 = d.hw * scale;
        const hh: f32 = d.hh * scale;
        const r: f32 = d.radius * scale;

        var body_def = b2.b2DefaultBodyDef();
        body_def.position = .{ .x = toMetres(px), .y = toMetres(py) };
        body_def.rotation = b2.b2MakeRot(d.angle);
        body_def.type = if (d.role == .static) b2.b2_staticBody else b2.b2_dynamicBody;
        if (d.role != .static) {
            body_def.linearVelocity = .{ .x = toMetres(d.vx), .y = toMetres(d.vy) };
        }
        const body_id = b2.b2CreateBody(world_id, &body_def);

        switch (d.shape) {
            .rect => {
                const box = b2.b2MakeBox(toMetres(hw), toMetres(hh));
                _ = b2.b2CreatePolygonShape(body_id, &shape_def, &box);
            },
            .circle => {
                var circle_shape = b2.b2Circle{
                    .center = .{ .x = 0, .y = 0 },
                    .radius = toMetres(r),
                };
                _ = b2.b2CreateCircleShape(body_id, &shape_def, &circle_shape);
            },
        }

        m.bodies[i] = Body{
            .pos = .{ .x = px, .y = py },
            .hw = hw,
            .hh = hh,
            .radius = r,
            .shape = d.shape,
            .role = d.role,
            .alive = true,
            .angle = d.angle,
            .body_id = body_id,
        };
        if (d.role == .green) m.has_green = true;
    }

    return m;
}

// ---------------------------------------------------------------------------
// Active map state
// ---------------------------------------------------------------------------

var active_map: Map = undefined;
var initialized: bool = false;

pub fn activeMap() *Map {
    if (!initialized) {
        active_map = loadLevel(0);
        initialized = true;
    }
    return &active_map;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

pub fn draw() void {
    rl.beginDrawing();
    defer rl.endDrawing();

    rl.clearBackground(rl.Color.init(30, 30, 30, 255));

    const map = activeMap();

    // --- debug grid (1 cell = 1 Box2D metre = PPM pixels) ---
    if (DEBUG) {
        const W: i32 = rl.getScreenWidth();
        const H: i32 = rl.getScreenHeight();
        const step: i32 = @intFromFloat(PPM);
        const grid_color = rl.Color.init(55, 55, 55, 255);
        var x: i32 = 0;
        while (x <= W) : (x += step) rl.drawLine(x, 0, x, H, grid_color);
        var y: i32 = 0;
        while (y <= H) : (y += step) rl.drawLine(0, y, W, y, grid_color);
    }

    for (map.bodies[0..map.count], 0..) |*b, bi| {
        if (!b.alive) continue;

        const color: rl.Color = switch (b.role) {
            .red => rl.Color.init(230, 80, 80, 255),
            .red_hard => rl.Color.init(120, 20, 20, 255),
            .support => rl.Color.init(100, 180, 230, 255),
            .green => rl.Color.green,
            .static => rl.Color.dark_gray,
        };
        const is_dragged = if (map.drag_idx) |di| (bi == di) else false;
        const outline = if (is_dragged) rl.Color.yellow else rl.Color.ray_white.alpha(0.30);

        switch (b.shape) {
            .circle => {
                const ix: i32 = @intFromFloat(b.pos.x);
                const iy: i32 = @intFromFloat(b.pos.y);
                rl.drawCircle(ix, iy, b.radius, color);
                rl.drawCircleLines(ix, iy, b.radius, outline);
            },
            .rect => {
                const draw_rec = rl.Rectangle{
                    .x = b.pos.x,
                    .y = b.pos.y,
                    .width = b.hw * 2,
                    .height = b.hh * 2,
                };
                const origin = rl.Vector2{ .x = b.hw, .y = b.hh };
                const deg = b.angle * (180.0 / std.math.pi);
                rl.drawRectanglePro(draw_rec, origin, deg, color);
                const ca = @cos(b.angle);
                const sa = @sin(b.angle);
                const corners = [4]rl.Vector2{
                    .{ .x = b.pos.x - b.hw * ca + b.hh * sa, .y = b.pos.y - b.hw * sa - b.hh * ca },
                    .{ .x = b.pos.x + b.hw * ca + b.hh * sa, .y = b.pos.y + b.hw * sa - b.hh * ca },
                    .{ .x = b.pos.x + b.hw * ca - b.hh * sa, .y = b.pos.y + b.hw * sa + b.hh * ca },
                    .{ .x = b.pos.x - b.hw * ca - b.hh * sa, .y = b.pos.y - b.hw * sa + b.hh * ca },
                };
                rl.drawLineV(corners[0], corners[1], outline);
                rl.drawLineV(corners[1], corners[2], outline);
                rl.drawLineV(corners[2], corners[3], outline);
                rl.drawLineV(corners[3], corners[0], outline);
            },
        }
    }

    if (DEBUG) {
        const line1 = "*DEBUG* Space: reset  |  Right-click: drag";
        const line2 = "1-9: jump to level";
        const font_size = 14;
        const full = "*DEBUG* Space: reset  |  Right-click: drag  |  1-9: jump to level";
        if (rl.getScreenWidth() >= rl.measureText(full, font_size) + 20) {
            rl.drawText(full, 10, 10, font_size, rl.Color.init(160, 160, 160, 200));
        } else {
            rl.drawText(line1, 10, 10, font_size, rl.Color.init(160, 160, 160, 200));
            rl.drawText(line2, 10, 10 + font_size + 2, font_size, rl.Color.init(160, 160, 160, 200));
        }
    }

    // --- failed overlay ---
    if (map.show_failed) {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        const iW: i32 = @intFromFloat(W);
        const iH: i32 = @intFromFloat(H);
        rl.drawRectangle(0, 0, iW, iH, rl.Color.init(0, 0, 0, 160));
        const pw: f32 = @min(420.0, W - 80.0);
        const ph: f32 = 130.0;
        const bx: i32 = @intFromFloat((W - pw) * 0.5);
        const by: i32 = @intFromFloat((H - ph) * 0.5);
        const ipw: i32 = @intFromFloat(pw);
        const iph: i32 = @intFromFloat(ph);
        rl.drawRectangle(bx, by, ipw, iph, rl.Color.init(30, 10, 10, 245));
        rl.drawRectangleLines(bx, by, ipw, iph, rl.Color.init(200, 60, 60, 255));
        rl.drawText("Failed!", bx + 20, by + 18, 26, rl.Color.init(230, 80, 80, 255));
        rl.drawText("A green shape was lost.", bx + 20, by + 56, 18, rl.Color.init(220, 220, 180, 255));
        rl.drawText("Click to try again", bx + 20, by + 92, 14, rl.Color.init(150, 150, 150, 255));
    }

    // --- complete overlay ---
    if (map.show_complete) {
        const W: f32 = @floatFromInt(rl.getScreenWidth());
        const H: f32 = @floatFromInt(rl.getScreenHeight());
        const iW: i32 = @intFromFloat(W);
        const iH: i32 = @intFromFloat(H);
        rl.drawRectangle(0, 0, iW, iH, rl.Color.init(0, 0, 0, 160));
        const pw: f32 = @min(420.0, W - 80.0);
        const ph: f32 = 150.0;
        const bx: i32 = @intFromFloat((W - pw) * 0.5);
        const by: i32 = @intFromFloat((H - ph) * 0.5);
        const ipw: i32 = @intFromFloat(pw);
        const iph: i32 = @intFromFloat(ph);
        rl.drawRectangle(bx, by, ipw, iph, rl.Color.init(10, 30, 10, 245));
        rl.drawRectangleLines(bx, by, ipw, iph, rl.Color.init(60, 200, 60, 255));
        rl.drawText("Map Complete!", bx + 20, by + 18, 26, rl.Color.init(80, 230, 80, 255));
        rl.drawText("All levels cleared!", bx + 20, by + 62, 18, rl.Color.init(220, 220, 180, 255));
        rl.drawText("Click to play again", bx + 20, by + 110, 14, rl.Color.init(150, 150, 150, 255));
    }

    // --- restart button (bottom-left) ---
    if (!map.show_complete and !map.show_failed and !map.show_banner) {
        const H_f: f32 = @floatFromInt(rl.getScreenHeight());
        const btn_w: i32 = 90;
        const btn_h: i32 = 32;
        const btn_x: i32 = 12;
        const btn_y: i32 = @intFromFloat(H_f - @as(f32, @floatFromInt(btn_h)) - 12);
        rl.drawRectangle(btn_x, btn_y, btn_w, btn_h, rl.Color.init(40, 40, 50, 220));
        rl.drawRectangleLines(btn_x, btn_y, btn_w, btn_h, rl.Color.init(160, 160, 160, 200));
        rl.drawText("Restart", btn_x + 14, btn_y + 9, 14, rl.Color.init(200, 200, 200, 255));
    }

    // --- banner overlay ---
    if (map.show_banner) {
        if (levels[map.level].banner) |banner_text| {
            const W: f32 = @floatFromInt(rl.getScreenWidth());
            const H: f32 = @floatFromInt(rl.getScreenHeight());
            const iW: i32 = @intFromFloat(W);
            const iH: i32 = @intFromFloat(H);
            rl.drawRectangle(0, 0, iW, iH, rl.Color.init(0, 0, 0, 160));
            const pw: f32 = @min(580.0, W - 80.0);
            // Panel always reserves two body lines
            const body_font: i32 = 14;
            const line_gap: i32 = 4;
            const ph: f32 = 54.0 + @as(f32, @floatFromInt(body_font * 2 + line_gap)) + 40.0;
            const bx: i32 = @intFromFloat((W - pw) * 0.5);
            const by: i32 = @intFromFloat((H - ph) * 0.5);
            const ipw: i32 = @intFromFloat(pw);
            const iph: i32 = @intFromFloat(ph);
            rl.drawRectangle(bx, by, ipw, iph, rl.Color.init(20, 20, 30, 245));
            rl.drawRectangleLines(bx, by, ipw, iph, rl.Color.ray_white);
            const level_labels = [_][:0]const u8{ "Level 1", "Level 2", "Level 3", "Level 4" };
            const label = if (map.level < level_labels.len) level_labels[map.level] else "Level ?";
            rl.drawText(label, bx + 20, by + 18, 22, rl.Color.ray_white);
            // Split on \n if present, otherwise draw as single line
            const break_idx = std.mem.indexOfScalar(u8, banner_text, '\n');
            if (break_idx) |bi| {
                var line1_buf: [256:0]u8 = std.mem.zeroes([256:0]u8);
                const len = @min(bi, 255);
                @memcpy(line1_buf[0..len], banner_text[0..len]);
                rl.drawText(&line1_buf, bx + 20, by + 54, body_font, rl.Color.init(220, 220, 180, 255));
                rl.drawText(banner_text[bi + 1 ..], bx + 20, by + 54 + body_font + line_gap, body_font, rl.Color.init(220, 220, 180, 255));
            } else {
                rl.drawText(banner_text, bx + 20, by + 54, body_font, rl.Color.init(220, 220, 180, 255));
            }
            rl.drawText("Click to continue", bx + 20, by + iph - 26, 14, rl.Color.init(150, 150, 150, 255));
        }
    }
}
