//! root.zig — Library root. Re-exports the C ABI surface.
//! All exported symbols are declared in c_api.zig.
//!
//! comptime reference forces Zig to analyze c_api.zig and emit all export fn symbols
//! into the static library. Without this, Zig's lazy compilation would skip the module.

pub const c_api = @import("c_api.zig");

comptime {
    _ = c_api;
}
