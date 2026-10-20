const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const dirs = @import("dirs.zig");
const whereis = @import("whereis.zig");

/// `zigup gc`: remove every installed version except the active one, plus
/// anything a failed install left behind.
pub fn main(allocator: std.mem.Allocator, io: Io, environ_map: *const std.process.Environ.Map) !void {
    const paths = try dirs.resolveOrFatal(allocator, environ_map);
    const removed_names = collectGarbage(allocator, io, paths) catch |gc_error| switch (gc_error) {
        error.NoActiveVersion => std.process.fatal(
            "no Zig version is active, so every version would count as unused; nothing was removed",
            .{},
        ),
        error.ActiveVersionOutsideVersionsDirectory => std.process.fatal(
            "{s}{c}zig does not point into {s}, so every version would count as unused; nothing was removed",
            .{ paths.bin, std.fs.path.sep, paths.versions },
        ),
        else => return gc_error,
    };
    defer {
        for (removed_names) |removed_name| allocator.free(removed_name);
        allocator.free(removed_names);
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    if (removed_names.len == 0) try stdout.writeAll("nothing to remove\n");
    for (removed_names) |removed_name| try stdout.print("removed {s}\n", .{removed_name});
    try stdout.flush();
}

/// Delete everything in `paths.versions` except the version `paths.bin` links
/// to. Returns the names it removed, allocated with `allocator`.
pub fn collectGarbage(allocator: std.mem.Allocator, io: Io, paths: dirs.Paths) ![]const []const u8 {
    const active_version_path = try whereis.activeVersionPath(allocator, io, paths.bin);
    defer allocator.free(active_version_path);
    // If `bin/zig` points at a zig zigup did not install, every version would
    // look unreferenced; refuse rather than delete them all.
    const active_version_parent = std.fs.path.dirname(active_version_path) orelse "";
    if (!std.mem.eql(u8, active_version_parent, std.mem.trimEnd(u8, paths.versions, std.fs.path.sep_str))) {
        return error.ActiveVersionOutsideVersionsDirectory;
    }
    const active_version_name = std.fs.path.basename(active_version_path);

    var versions_dir = try Io.Dir.cwd().openDir(io, paths.versions, .{ .iterate = true });
    defer versions_dir.close(io);

    // Collect first, then delete, so the directory is not changed mid-iteration.
    var unreferenced_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unreferenced_names.items) |unreferenced_name| allocator.free(unreferenced_name);
        unreferenced_names.deinit(allocator);
    }
    var versions_iterator = versions_dir.iterate();
    while (try versions_iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, active_version_name)) continue;
        const unreferenced_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(unreferenced_name);
        try unreferenced_names.append(allocator, unreferenced_name);
    }

    for (unreferenced_names.items) |unreferenced_name| {
        try versions_dir.deleteTree(io, unreferenced_name);
    }
    return unreferenced_names.toOwnedSlice(allocator);
}

fn testPaths(arena: std.mem.Allocator, tmp_dir: std.testing.TmpDir) !dirs.Paths {
    const io = std.testing.io;
    try tmp_dir.dir.createDirPath(io, "bin");
    try tmp_dir.dir.createDirPath(io, "versions");
    return .{
        .base = try tmp_dir.dir.realPathFileAlloc(io, ".", arena),
        .bin = try tmp_dir.dir.realPathFileAlloc(io, "bin", arena),
        .versions = try tmp_dir.dir.realPathFileAlloc(io, "versions", arena),
        .cache = "",
        .config = "",
    };
}

fn installTestVersion(arena: std.mem.Allocator, tmp_dir: std.testing.TmpDir, version_name: []const u8) !void {
    const io = std.testing.io;
    try tmp_dir.dir.createDirPath(io, try std.fs.path.join(arena, &.{ "versions", version_name, "lib" }));
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ "versions", version_name, "zig" }),
        .data = version_name,
    });
}

fn activateTestVersion(arena: std.mem.Allocator, tmp_dir: std.testing.TmpDir, paths: dirs.Paths, version_name: []const u8) !void {
    try tmp_dir.dir.symLink(std.testing.io, try std.fs.path.join(arena, &.{ paths.versions, version_name, "zig" }), "bin/zig", .{});
}

fn expectVersionsDirContains(arena: std.mem.Allocator, tmp_dir: std.testing.TmpDir, expected_names: []const []const u8) !void {
    const io = std.testing.io;
    var versions_dir = try tmp_dir.dir.openDir(io, "versions", .{ .iterate = true });
    defer versions_dir.close(io);
    var remaining_names: std.ArrayList([]const u8) = .empty;
    var versions_iterator = versions_dir.iterate();
    while (try versions_iterator.next(io)) |entry| try remaining_names.append(arena, try arena.dupe(u8, entry.name));
    std.mem.sort([]const u8, remaining_names.items, {}, lessThanString);
    try std.testing.expectEqual(expected_names.len, remaining_names.items.len);
    for (expected_names, remaining_names.items) |expected_name, remaining_name| {
        try std.testing.expectEqualStrings(expected_name, remaining_name);
    }
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "collectGarbage removes every version except the active one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const paths = try testPaths(arena, tmp_dir);
    for ([_][]const u8{ "0.15.2", "0.16.0", "0.17.0" }) |version_name| try installTestVersion(arena, tmp_dir, version_name);
    try activateTestVersion(arena, tmp_dir, paths, "0.16.0");

    const removed_names = try collectGarbage(arena, std.testing.io, paths);

    try std.testing.expectEqual(@as(usize, 2), removed_names.len);
    try expectVersionsDirContains(arena, tmp_dir, &.{"0.16.0"});
    try std.testing.expectEqualStrings("0.16.0", try tmp_dir.dir.readFileAlloc(std.testing.io, "bin/zig", arena, .unlimited));
}

test "collectGarbage removes what failed installs left behind" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const paths = try testPaths(arena, tmp_dir);
    try installTestVersion(arena, tmp_dir, "0.17.0");
    try activateTestVersion(arena, tmp_dir, paths, "0.17.0");
    try tmp_dir.dir.createDirPath(io, "versions/.0.16.0.partial/zig-aarch64-macos-0.16.0");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "versions/.0.16.0.zip", .data = "partial zip" });

    const removed_names = try collectGarbage(arena, io, paths);

    try std.testing.expectEqual(@as(usize, 2), removed_names.len);
    try expectVersionsDirContains(arena, tmp_dir, &.{"0.17.0"});
}

test "collectGarbage removes nothing when only the active version is installed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const paths = try testPaths(arena, tmp_dir);
    try installTestVersion(arena, tmp_dir, "0.17.0");
    try activateTestVersion(arena, tmp_dir, paths, "0.17.0");

    const removed_names = try collectGarbage(arena, std.testing.io, paths);

    try std.testing.expectEqual(@as(usize, 0), removed_names.len);
    try expectVersionsDirContains(arena, tmp_dir, &.{"0.17.0"});
}

test "collectGarbage refuses to run without an active version" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const paths = try testPaths(arena, tmp_dir);
    for ([_][]const u8{ "0.16.0", "0.17.0" }) |version_name| try installTestVersion(arena, tmp_dir, version_name);

    try std.testing.expectError(error.NoActiveVersion, collectGarbage(arena, std.testing.io, paths));
    try expectVersionsDirContains(arena, tmp_dir, &.{ "0.16.0", "0.17.0" });
}

test "collectGarbage refuses a link that points outside the versions directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const paths = try testPaths(arena, tmp_dir);
    try installTestVersion(arena, tmp_dir, "0.17.0");
    // A zig the user linked by hand, not one zigup installed.
    try tmp_dir.dir.createDirPath(io, "elsewhere/zig-dev");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "elsewhere/zig-dev/zig", .data = "dev" });
    try tmp_dir.dir.symLink(io, try std.fs.path.join(arena, &.{ paths.base, "elsewhere", "zig-dev", "zig" }), "bin/zig", .{});

    try std.testing.expectError(error.ActiveVersionOutsideVersionsDirectory, collectGarbage(arena, io, paths));
    try expectVersionsDirContains(arena, tmp_dir, &.{"0.17.0"});
}
