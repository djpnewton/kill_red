const std = @import("std");
const rlz = @import("raylib_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("kill_red", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kill_red", .module = mod },
        },
    });

    // raylib
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library
    // box2d
    const box2d_dep = b.dependency("box2d", .{
        .target = target,
        .optimize = optimize,
    });
    const box2d_src = box2d_dep.path("src");
    const box2d_inc = box2d_dep.path("include");
    const box2d_lib = b.addLibrary(.{
        .name = "box2d",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    box2d_lib.root_module.addIncludePath(box2d_inc);
    box2d_lib.root_module.addIncludePath(box2d_dep.path("src"));
    box2d_lib.root_module.link_libc = true;
    const box2d_flags: []const []const u8 = if (target.query.os_tag == .emscripten)
        &.{ "-std=c17", "-fno-sanitize=undefined", "-DBOX2D_DISABLE_SIMD", "-D_POSIX_C_SOURCE=199309L" }
    else
        &.{ "-std=c17", "-fno-sanitize=undefined", "-D_POSIX_C_SOURCE=199309L" };
    box2d_lib.root_module.addCSourceFiles(.{
        .root = box2d_src,
        .files = &.{
            "aabb.c",             "arena_allocator.c", "array.c",
            "bitset.c",           "body.c",            "broad_phase.c",
            "constraint_graph.c", "contact.c",         "contact_solver.c",
            "core.c",             "distance.c",        "distance_joint.c",
            "dynamic_tree.c",     "geometry.c",        "hull.c",
            "id_pool.c",          "island.c",          "joint.c",
            "manifold.c",         "math_functions.c",  "motor_joint.c",
            "mouse_joint.c",      "mover.c",           "prismatic_joint.c",
            "revolute_joint.c",   "sensor.c",          "shape.c",
            "solver.c",           "solver_set.c",      "table.c",
            "timer.c",            "types.c",           "weld_joint.c",
            "wheel_joint.c",      "world.c",
        },
        .flags = box2d_flags,
    });

    const run_step = b.step("run", "Run the app");

    // emscripten
    if (target.query.os_tag == .emscripten) {
        const emsdk = rlz.emsdk;

        // box2d needs cache/sysroot/include (populated by first emcc run).
        // Without explicit ordering, zig may start box2d compilation in parallel
        // with emsdk activation, before the sysroot exists on a cold runner.
        // Fix: activate emsdk + run a trivial emcc compile BEFORE box2d compiles.
        const emsdk_dep = b.dependency("emsdk", .{});
        const emsdk_root = emsdk_dep.path("").getPath(b);
        const emsdk_script = std.fs.path.join(b.allocator, &.{ emsdk_root, "emsdk" }) catch unreachable;
        const emcc_exe = std.fs.path.join(b.allocator, &.{ emsdk_root, "upstream", "emscripten", "emcc" }) catch unreachable;

        const chmod_emsdk = b.addSystemCommand(&.{ "chmod", "+x", emsdk_script });
        const emsdk_install = b.addSystemCommand(&.{ emsdk_script, "install", "4.0.3" });
        emsdk_install.step.dependOn(&chmod_emsdk.step);
        const emsdk_activate = b.addSystemCommand(&.{ emsdk_script, "activate", "4.0.3" });
        emsdk_activate.step.dependOn(&emsdk_install.step);
        const chmod_emcc = b.addSystemCommand(&.{ "chmod", "+x", emcc_exe });
        chmod_emcc.step.dependOn(&emsdk_activate.step);

        // Compile a trivial C file to trigger emscripten's sysroot cache generation.
        const warmup_src = b.addWriteFiles();
        const warmup_c = warmup_src.add("warmup.c", "void x(){}");
        const warmup_cmd = b.addSystemCommand(&.{ emcc_exe, "-c" });
        warmup_cmd.addFileArg(warmup_c);
        warmup_cmd.addArg("-o");
        _ = warmup_cmd.addOutputFileArg("warmup.o");
        warmup_cmd.step.dependOn(&chmod_emcc.step);

        box2d_lib.step.dependOn(&warmup_cmd.step);
        box2d_lib.root_module.addIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));

        const wasm = b.addLibrary(.{
            .name = "kill_red",
            .root_module = exe_mod,
        });

        // raylib
        wasm.root_module.addImport("raylib", raylib);
        wasm.root_module.addImport("raygui", raygui);
        // box2d
        wasm.root_module.linkLibrary(box2d_lib);
        wasm.root_module.addIncludePath(box2d_inc);

        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{ .optimize = optimize });
        var emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize });
        emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch unreachable;
        emcc_settings.put("INITIAL_MEMORY", "67108864") catch unreachable;
        emcc_settings.put("STACK_SIZE", "1048576") catch unreachable;
        const emcc_step = emsdk.emccStep(b, raylib_artifact, wasm, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .shell_file_path = b.path("src/shell.html"),
            .install_dir = install_dir,
            .embed_paths = &.{
                // Embed the entire resources/ directory into the wasm virtual filesystem
                // so raylib can load PNG files via the normal file path.
                .{ .src_path = b.pathFromRoot("resources"), .virtual_path = "resources" },
            },
        });
        b.getInstallStep().dependOn(emcc_step);

        const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{wasm.name});
        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, html_filename),
            &.{},
        );
        emrun_step.dependOn(emcc_step);
        run_step.dependOn(emrun_step);
    } else {
        const exe = b.addExecutable(.{
            .name = "kill_red",
            .root_module = exe_mod,
        });

        // raylib
        exe.root_module.linkLibrary(raylib_artifact);
        exe.root_module.addImport("raylib", raylib);
        exe.root_module.addImport("raygui", raygui);
        // box2d
        exe.root_module.linkLibrary(box2d_lib);
        exe.root_module.addIncludePath(box2d_inc);
        exe.root_module.link_libc = true;

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }
}
