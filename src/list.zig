const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const dirs = @import("dirs.zig");
const index = @import("index.zig");
const install = @import("install.zig");
const whereis = @import("whereis.zig");

pub const Row = struct {
    /// Key in the index ("master", "0.17.0"), or the folder name of an
    /// installed version the index no longer lists.
    label: []const u8,
    /// Folder name under the versions directory; master's dev version.
    version_name: []const u8,
    date: ?[]const u8,
    installed: bool,
    active: bool,
    /// Release-notes URL; null for master and versions the index no longer lists.
    notes: ?[]const u8 = null,
};

/// `zigup list`: show the versions available for this machine, which are
/// installed, and which is active.
pub fn main(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    options: cli.List,
) !void {
    const paths = try dirs.resolveOrFatal(allocator, environ_map);
    const parsed_index = try index.loadParsedOrFatal(allocator, io, paths.cache, options.url);
    defer parsed_index.deinit();

    const installed_names = try installedVersionNames(allocator, io, paths.versions);
    defer {
        for (installed_names) |installed_name| allocator.free(installed_name);
        allocator.free(installed_names);
    }

    const active_version_path: ?[]u8 = whereis.activeVersionPath(allocator, io, paths.bin) catch |active_error| switch (active_error) {
        error.NoActiveVersion => null,
        else => return active_error,
    };
    defer if (active_version_path) |path| allocator.free(path);
    const active_name = if (active_version_path) |path| std.fs.path.basename(path) else null;

    const rows = try buildRows(allocator, parsed_index.value, cli.index_target_key, installed_names, active_name);
    defer allocator.free(rows);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try writeTable(&stdout_writer.interface, rows);
    try stdout_writer.interface.flush();
}

/// Folder names in the versions directory, without the hidden leftovers of
/// failed installs. Empty if nothing was ever installed.
pub fn installedVersionNames(allocator: std.mem.Allocator, io: Io, versions_path: []const u8) ![]const []const u8 {
    var installed_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (installed_names.items) |installed_name| allocator.free(installed_name);
        installed_names.deinit(allocator);
    }
    var versions_dir = Io.Dir.cwd().openDir(io, versions_path, .{ .iterate = true }) catch |open_error| switch (open_error) {
        error.FileNotFound => return installed_names.toOwnedSlice(allocator),
        else => return open_error,
    };
    defer versions_dir.close(io);
    var versions_iterator = versions_dir.iterate();
    while (try versions_iterator.next(io)) |entry| {
        if (entry.kind != .directory or std.mem.startsWith(u8, entry.name, ".")) continue;
        const installed_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(installed_name);
        try installed_names.append(allocator, installed_name);
    }
    return installed_names.toOwnedSlice(allocator);
}

/// One row per release that ships `target`, in index order, followed by
/// installed versions the index does not list.
pub fn buildRows(
    allocator: std.mem.Allocator,
    parsed_index: index.Index,
    target: []const u8,
    installed_names: []const []const u8,
    active_name: ?[]const u8,
) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);

    for (parsed_index.map.keys(), parsed_index.map.values()) |release_key, release| {
        if (!release.targets.contains(target)) continue;
        const found_release = try install.find_release(parsed_index, release_key);
        try rows.append(allocator, .{
            .label = release_key,
            .version_name = found_release.name,
            .date = release.date,
            .installed = containsName(installed_names, found_release.name),
            .active = isActive(active_name, found_release.name),
            .notes = release.notes,
        });
    }

    for (installed_names) |installed_name| {
        const listed = for (rows.items) |row| {
            if (std.mem.eql(u8, row.version_name, installed_name)) break true;
        } else false;
        if (listed) continue;
        try rows.append(allocator, .{
            .label = installed_name,
            .version_name = installed_name,
            .date = null,
            .installed = true,
            .active = isActive(active_name, installed_name),
        });
    }
    return rows.toOwnedSlice(allocator);
}

pub fn containsName(names: []const []const u8, wanted_name: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted_name)) return true;
    }
    return false;
}

pub fn isActive(active_name: ?[]const u8, version_name: []const u8) bool {
    const name = active_name orelse return false;
    return std.mem.eql(u8, name, version_name);
}

pub fn writeTable(writer: *Io.Writer, rows: []const Row) !void {
    var label_width: usize = 0;
    for (rows) |row| label_width = @max(label_width, labelLength(row));

    for (rows) |row| {
        // Build each line first so trailing padding can be trimmed.
        var line_buffer: [512]u8 = undefined;
        var line_writer: Io.Writer = .fixed(&line_buffer);
        try line_writer.writeAll(if (row.active) "* " else "  ");
        try line_writer.writeAll(row.label);
        if (!std.mem.eql(u8, row.label, row.version_name)) try line_writer.print(" ({s})", .{row.version_name});
        try line_writer.splatByteAll(' ', label_width - labelLength(row));
        try line_writer.print("  {s:<10}  {s}", .{
            row.date orelse "",
            if (row.active) "active" else if (row.installed) "installed" else "",
        });
        try writer.writeAll(std.mem.trimEnd(u8, line_writer.buffered(), " "));
        try writer.writeByte('\n');
    }
}

pub fn labelLength(row: Row) usize {
    if (std.mem.eql(u8, row.label, row.version_name)) return row.label.len;
    return row.label.len + " ()".len + row.version_name.len;
}

pub const test_index_json =
    \\{
    \\  "master": {"version": "0.18.0-dev.349+d924f83bf", "date": "2026-10-17",
    \\             "aarch64-macos": {"tarball": "t", "shasum": "s", "size": "1"}},
    \\  "0.17.0": {"date": "2026-09-01", "notes": "https://ziglang.org/download/0.17.0/release-notes.html",
    \\             "aarch64-macos": {"tarball": "t", "shasum": "s", "size": "1"}},
    \\  "0.16.0": {"date": "2026-04-13", "aarch64-macos": {"tarball": "t", "shasum": "s", "size": "1"}},
    \\  "0.2.0": {"date": "2018-03-15", "x86_64-linux": {"tarball": "t", "shasum": "s", "size": "1"}}
    \\}
;

pub fn expectRow(expected: Row, actual: Row) !void {
    try std.testing.expectEqualStrings(expected.label, actual.label);
    try std.testing.expectEqualStrings(expected.version_name, actual.version_name);
    if (expected.date) |expected_date| {
        try std.testing.expectEqualStrings(expected_date, actual.date.?);
    } else {
        try std.testing.expectEqual(null, actual.date);
    }
    try std.testing.expectEqual(expected.installed, actual.installed);
    try std.testing.expectEqual(expected.active, actual.active);
}

test "buildRows carries each release's notes url" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed_index = try std.json.parseFromSliceLeaky(index.Index, arena, test_index_json, .{});

    const rows = try buildRows(arena, parsed_index, "aarch64-macos", &.{}, null);

    try std.testing.expectEqual(null, rows[0].notes);
    try std.testing.expectEqualStrings("https://ziglang.org/download/0.17.0/release-notes.html", rows[1].notes.?);
}

test "buildRows lists the releases for the target in index order" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed_index = try std.json.parseFromSliceLeaky(index.Index, arena, test_index_json, .{});

    const rows = try buildRows(arena, parsed_index, "aarch64-macos", &.{}, null);

    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try expectRow(.{ .label = "master", .version_name = "0.18.0-dev.349+d924f83bf", .date = "2026-10-17", .installed = false, .active = false }, rows[0]);
    try expectRow(.{ .label = "0.17.0", .version_name = "0.17.0", .date = "2026-09-01", .installed = false, .active = false }, rows[1]);
    try expectRow(.{ .label = "0.16.0", .version_name = "0.16.0", .date = "2026-04-13", .installed = false, .active = false }, rows[2]);
}

test "buildRows marks installed and active versions" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed_index = try std.json.parseFromSliceLeaky(index.Index, arena, test_index_json, .{});

    const rows = try buildRows(arena, parsed_index, "aarch64-macos", &.{ "0.16.0", "0.18.0-dev.349+d924f83bf" }, "0.16.0");

    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expect(rows[0].installed and !rows[0].active);
    try std.testing.expect(!rows[1].installed and !rows[1].active);
    try std.testing.expect(rows[2].installed and rows[2].active);
}

test "buildRows appends installed versions the index no longer lists" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed_index = try std.json.parseFromSliceLeaky(index.Index, arena, test_index_json, .{});

    const rows = try buildRows(arena, parsed_index, "aarch64-macos", &.{ "0.17.0", "0.18.0-dev.100+0123456789" }, "0.18.0-dev.100+0123456789");

    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try expectRow(.{ .label = "0.18.0-dev.100+0123456789", .version_name = "0.18.0-dev.100+0123456789", .date = null, .installed = true, .active = true }, rows[3]);
}

test "writeTable aligns the columns and marks the active version" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeTable(&output.writer, &.{
        .{ .label = "master", .version_name = "0.18.0-dev.349+d924f83bf", .date = "2026-10-17", .installed = false, .active = false },
        .{ .label = "0.17.0", .version_name = "0.17.0", .date = "2026-09-01", .installed = true, .active = true },
        .{ .label = "0.16.0", .version_name = "0.16.0", .date = "2026-04-13", .installed = true, .active = false },
        .{ .label = "0.18.0-dev.100+0123456789", .version_name = "0.18.0-dev.100+0123456789", .date = null, .installed = true, .active = false },
    });

    try std.testing.expectEqualStrings(
        \\  master (0.18.0-dev.349+d924f83bf)  2026-10-17
        \\* 0.17.0                             2026-09-01  active
        \\  0.16.0                             2026-04-13  installed
        \\  0.18.0-dev.100+0123456789                      installed
        \\
    , output.written());
}
