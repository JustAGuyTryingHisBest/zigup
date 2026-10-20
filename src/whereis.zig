const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const dirs = @import("dirs.zig");

const zig_exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

/// `zigup whereis`: print the install path of the active Zig version.
pub fn main(allocator: std.mem.Allocator, io: Io, environ_map: *const std.process.Environ.Map) !void {
    const paths = try dirs.resolveOrFatal(allocator, environ_map);
    const active_version_path = activeVersionPath(allocator, io, paths.bin) catch |active_error| switch (active_error) {
        error.NoActiveVersion => std.process.fatal("no Zig version is active; install one with `zigup install <version>`", .{}),
        else => return active_error,
    };
    defer allocator.free(active_version_path);

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{active_version_path});
    try stdout.flush();
}

/// The folder of the version `<bin_path>/zig` links to, such as
/// "~/.zigup/versions/0.17.0". The caller owns the returned path.
pub fn activeVersionPath(allocator: std.mem.Allocator, io: Io, bin_path: []const u8) ![]u8 {
    const link_path = try std.fs.path.join(allocator, &.{ bin_path, zig_exe_name });
    defer allocator.free(link_path);

    var link_target_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const link_target_len = Io.Dir.readLinkAbsolute(io, link_path, &link_target_buffer) catch |read_link_error| switch (read_link_error) {
        error.FileNotFound => return error.NoActiveVersion,
        else => return read_link_error,
    };
    const link_target = link_target_buffer[0..link_target_len];

    // `install` writes absolute targets; resolve a hand-made relative one against bin.
    const zig_exe_path = if (std.fs.path.isAbsolute(link_target))
        try allocator.dupe(u8, link_target)
    else
        try std.fs.path.resolve(allocator, &.{ bin_path, link_target });
    defer allocator.free(zig_exe_path);

    return allocator.dupe(u8, std.fs.path.dirname(zig_exe_path) orelse return error.NoActiveVersion);
}

test "activeVersionPath returns the folder the zig link points into" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "bin");
    try tmp_dir.dir.createDirPath(io, "versions/0.17.0");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "versions/0.17.0/zig", .data = "zig 0.17.0" });
    const version_path = try tmp_dir.dir.realPathFileAlloc(io, "versions/0.17.0", arena);
    try tmp_dir.dir.symLink(io, try std.fs.path.join(arena, &.{ version_path, "zig" }), "bin/zig", .{});

    const active_version_path = try activeVersionPath(
        std.testing.allocator,
        io,
        try tmp_dir.dir.realPathFileAlloc(io, "bin", arena),
    );
    defer std.testing.allocator.free(active_version_path);

    try std.testing.expectEqualStrings(version_path, active_version_path);
}

test "activeVersionPath reports when no version is active" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "bin");

    try std.testing.expectError(error.NoActiveVersion, activeVersionPath(
        std.testing.allocator,
        io,
        try tmp_dir.dir.realPathFileAlloc(io, "bin", arena_state.allocator()),
    ));
}

test "activeVersionPath reports when zigup was never set up" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const missing_bin_path = try std.fs.path.join(arena_state.allocator(), &.{
        try tmp_dir.dir.realPathFileAlloc(io, ".", arena_state.allocator()),
        "bin",
    });

    try std.testing.expectError(error.NoActiveVersion, activeVersionPath(std.testing.allocator, io, missing_bin_path));
}
