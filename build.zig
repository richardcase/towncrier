const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── SQLite amalgamation (compiled as a C object) ───────────────────────────
    // sqlite3.c is compiled once and linked into the library.
    // vendor/sqlite/ contains the sqlite3 amalgamation source.
    const sqlite_mod = b.createModule(.{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_mod.link_libc = true;
    sqlite_mod.addIncludePath(b.path("vendor/sqlite"));
    sqlite_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-std=c99", "-DSQLITE_THREADSAFE=2" },
    });

    // ── Static library ─────────────────────────────────────────────────────────
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "towncrier",
        .root_module = lib_mod,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .linkage = .static,
    });

    lib_mod.link_libc = true; // required for std.heap.c_allocator

    // ── sqlite module wired to lib_mod ─────────────────────────────────────────
    lib_mod.addImport("sqlite", sqlite_mod);

    b.installArtifact(lib);
    lib.installHeader(b.path("include/towncrier.h"), "towncrier.h");

    // ── Linux platform guard ───────────────────────────────────────────────────
    if (target.result.os.tag == .linux) {
        // Phase 3: link libstray, gtk-4, libsecret here
    }

    // ── C ABI integration test (test-c step) ───────────────────────────────────
    const c_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_test_mod.addCSourceFile(.{ .file = b.path("tests/c_abi_test.c"), .flags = &.{"-std=c11"} });
    c_test_mod.addIncludePath(b.path("include"));
    c_test_mod.linkLibrary(lib);

    const c_test = b.addExecutable(.{
        .name = "c_abi_test",
        .root_module = c_test_mod,
    });

    const run_c_test = b.addRunArtifact(c_test);
    const test_c_step = b.step("test-c", "Run C ABI integration test");
    test_c_step.dependOn(&run_c_test.step);
}
