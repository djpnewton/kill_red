/// box2d.zig — thin @cImport wrapper around Box2D 3.x C API.
pub const c = @cImport({
    @cInclude("box2d/box2d.h");
});
