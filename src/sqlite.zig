//! sqlite.zig — Minimal SQLite wrapper for libtowncrier.
//! Wraps the sqlite3 C API with just the operations needed by store.zig.
//! All SQL errors are returned as Zig error unions.

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    SqliteError,
    NoRow,
    Done,
    OutOfMemory,
};

pub const OpenFlags = struct {
    write: bool = false,
    create: bool = false,
};

pub const ThreadingMode = enum {
    SingleThread,
    MultiThread,
    Serialized,
};

pub const DbMode = union(enum) {
    Memory: void,
    File: []const u8,
};

pub const InitOptions = struct {
    mode: DbMode,
    open_flags: OpenFlags = .{},
    threading_mode: ThreadingMode = .Serialized,
};

/// A SQLite database connection.
pub const Db = struct {
    db: *c.sqlite3,

    pub fn init(opts: InitOptions) Error!Db {
        var flags: c_int = c.SQLITE_OPEN_READONLY;
        if (opts.open_flags.write) {
            flags = c.SQLITE_OPEN_READWRITE;
        }
        if (opts.open_flags.create) {
            flags |= c.SQLITE_OPEN_CREATE;
        }
        if (opts.threading_mode == .MultiThread) {
            flags |= c.SQLITE_OPEN_NOMUTEX;
        }

        var db_ptr: ?*c.sqlite3 = null;

        switch (opts.mode) {
            .Memory => {
                const rc = c.sqlite3_open_v2(":memory:", &db_ptr, flags, null);
                if (rc != c.SQLITE_OK or db_ptr == null) return Error.SqliteError;
                return Db{ .db = db_ptr.? };
            },
            .File => |p| {
                const buf = std.heap.c_allocator.dupeZ(u8, p) catch return Error.OutOfMemory;
                defer std.heap.c_allocator.free(buf);
                const rc = c.sqlite3_open_v2(buf.ptr, &db_ptr, flags, null);
                if (rc != c.SQLITE_OK or db_ptr == null) return Error.SqliteError;
                return Db{ .db = db_ptr.? };
            },
        }
    }

    pub fn deinit(self: *Db) void {
        _ = c.sqlite3_close(self.db);
    }

    /// Execute a SQL statement with no result rows.
    pub fn exec(self: *Db, comptime sql: []const u8, _: anytype, args: anytype) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return Error.SqliteError;
        defer _ = c.sqlite3_finalize(stmt);

        try bindArgs(stmt.?, args);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
            return Error.SqliteError;
        }
    }

    /// Execute a multi-statement SQL string (e.g. schema migration DDL).
    /// Each statement is executed in sequence; no row results are returned.
    pub fn execMulti(self: *Db, sql: []const u8) !void {
        var tail: ?[*:0]const u8 = @ptrCast(sql.ptr);
        while (tail != null and tail.?[0] != 0) {
            var stmt: ?*c.sqlite3_stmt = null;
            var next_tail: ?[*]const u8 = null;
            const rc = c.sqlite3_prepare_v2(
                self.db,
                @ptrCast(tail.?),
                -1,
                &stmt,
                @ptrCast(&next_tail),
            );
            if (rc != c.SQLITE_OK) return Error.SqliteError;
            if (stmt == null) break; // empty statement (whitespace/comments)

            const step_rc = c.sqlite3_step(stmt.?);
            _ = c.sqlite3_finalize(stmt);
            if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
                return Error.SqliteError;
            }

            tail = @ptrCast(next_tail);
        }
    }

    /// Query a single optional row, returning a struct of the given type.
    pub fn oneAlloc(
        self: *Db,
        comptime T: type,
        allocator: std.mem.Allocator,
        comptime sql: []const u8,
        _: anytype,
        args: anytype,
    ) !?T {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return Error.SqliteError;
        defer _ = c.sqlite3_finalize(stmt);

        try bindArgs(stmt.?, args);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc == c.SQLITE_DONE) return null;
        if (step_rc != c.SQLITE_ROW) return Error.SqliteError;

        return try readRow(T, stmt.?, allocator);
    }

    /// Query multiple rows, returning a heap-allocated slice.
    pub fn allAlloc(
        self: *Db,
        comptime T: type,
        allocator: std.mem.Allocator,
        comptime sql: []const u8,
        _: anytype,
        args: anytype,
    ) ![]T {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return Error.SqliteError;
        defer _ = c.sqlite3_finalize(stmt);

        try bindArgs(stmt.?, args);

        // Zig 0.16: std.ArrayList is unmanaged — pass allocator to all operations.
        var results: std.ArrayList(T) = .empty;
        errdefer results.deinit(allocator);

        while (true) {
            const step_rc = c.sqlite3_step(stmt.?);
            if (step_rc == c.SQLITE_DONE) break;
            if (step_rc != c.SQLITE_ROW) return Error.SqliteError;
            const row = try readRow(T, stmt.?, allocator);
            try results.append(allocator, row);
        }

        return results.toOwnedSlice(allocator);
    }
};

/// A prepared statement.
pub const Statement = struct {
    stmt: *c.sqlite3_stmt,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn bind(self: *Statement, args: anytype) !void {
        try bindArgs(self.stmt, args);
    }

    pub fn step(self: *Statement) !bool {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_DONE) return false;
        if (rc == c.SQLITE_ROW) return true;
        return Error.SqliteError;
    }

    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.stmt);
    }
};

// ── Binding helpers ────────────────────────────────────────────────────────

fn bindArgs(stmt: *c.sqlite3_stmt, args: anytype) !void {
    const T = @TypeOf(args);
    const info = @typeInfo(T);
    if (info != .@"struct") return;

    const fields = info.@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const idx: c_int = @intCast(i + 1);
        const val = @field(args, field.name);
        try bindValue(stmt, idx, val);
    }
}

fn bindValue(stmt: *c.sqlite3_stmt, idx: c_int, val: anytype) !void {
    const T = @TypeOf(val);
    const rc: c_int = switch (@typeInfo(T)) {
        .int, .comptime_int => c.sqlite3_bind_int64(stmt, idx, @intCast(val)),
        .float, .comptime_float => c.sqlite3_bind_double(stmt, idx, @floatCast(val)),
        .bool => c.sqlite3_bind_int(stmt, idx, if (val) 1 else 0),
        .optional => {
            if (val) |v| {
                try bindValue(stmt, idx, v);
                return;
            } else {
                const r = c.sqlite3_bind_null(stmt, idx);
                if (r != c.SQLITE_OK) return Error.SqliteError;
                return;
            }
        },
        .pointer => |ptr| blk: {
            if (ptr.child == u8) {
                const slice: []const u8 = val;
                break :blk c.sqlite3_bind_text(stmt, idx, slice.ptr, @intCast(slice.len), c.SQLITE_TRANSIENT);
            } else {
                @compileError("unsupported pointer type for SQLite bind: " ++ @typeName(T));
            }
        },
        .@"enum" => c.sqlite3_bind_int64(stmt, idx, @intCast(@intFromEnum(val))),
        else => @compileError("unsupported type for SQLite bind: " ++ @typeName(T)),
    };
    if (rc != c.SQLITE_OK) return Error.SqliteError;
}

// ── Row reading helpers ────────────────────────────────────────────────────

fn readRow(comptime T: type, stmt: *c.sqlite3_stmt, allocator: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("readRow requires a struct type");

    var result: T = undefined;
    const fields = info.@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const col: c_int = @intCast(i);
        @field(result, field.name) = try readCol(field.type, stmt, col, allocator);
    }
    return result;
}

fn readCol(comptime T: type, stmt: *c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .int => @intCast(c.sqlite3_column_int64(stmt, col)),
        .bool => c.sqlite3_column_int(stmt, col) != 0,
        .optional => |opt| blk: {
            if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) break :blk null;
            break :blk try readCol(opt.child, stmt, col, allocator);
        },
        .pointer => |ptr| blk: {
            if (ptr.child == u8 and ptr.size == .slice) {
                const raw = c.sqlite3_column_text(stmt, col);
                if (raw == null) break :blk @as(T, "");
                const len = c.sqlite3_column_bytes(stmt, col);
                const bytes = raw[0..@intCast(len)];
                break :blk try allocator.dupe(u8, bytes);
            } else {
                @compileError("unsupported pointer type for SQLite read: " ++ @typeName(T));
            }
        },
        else => @compileError("unsupported type for SQLite read: " ++ @typeName(T)),
    };
}
