//! root.zig — Library root. Re-exports the C ABI surface.
//! All exported symbols are declared in c_api.zig.
//!
//! comptime reference forces Zig to analyze c_api.zig and emit all export fn symbols
//! into the static library. Without this, Zig's lazy compilation would skip the module.

pub const c_api = @import("c_api.zig");
pub const store = @import("store.zig");
pub const http = @import("http.zig");
pub const github = @import("github.zig");
pub const poller = @import("poller.zig");

comptime {
    _ = c_api;
}

// Pull all tests from sub-modules into the root test namespace.
test {
    _ = @import("types.zig");
    _ = @import("store.zig");
    _ = @import("http.zig");
    _ = @import("github.zig");
}
