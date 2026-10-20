const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

/// Where zigup keeps its files, by role. Callers ask for a role and never
/// handle the OS-specific layout themselves.
pub const Paths = struct {
    base: []const u8,
    bin: []const u8,
    versions: []const u8,
    cache: []const u8,
    config: []const u8,
};

pub fn resolve(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !Paths {
    return resolveForOs(allocator, environ_map, builtin.os.tag);
}

/// `resolve` for commands: a missing home directory ends the program with a
/// message instead of an error.
pub fn resolveOrFatal(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !Paths {
    return resolve(allocator, environ_map) catch |resolve_error| switch (resolve_error) {
        error.HomeNotFound => std.process.fatal("cannot find your home directory: HOME is not set", .{}),
        else => return resolve_error,
    };
}

/// Like `resolve`, but for a given OS, so every layout can be tested from any host.
pub fn resolveForOs(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    os_tag: std.Target.Os.Tag,
) !Paths {
    // Windows follows ghcup's `C:\ghcup`: a folder at the root of the system
    // drive. Everywhere else it is a dotfolder in the home directory.
    const separator: u8 = if (os_tag == .windows) std.fs.path.sep_windows else std.fs.path.sep_posix;
    const base = if (os_tag == .windows) base: {
        const system_drive = environ_map.get("SystemDrive") orelse "C:";
        break :base try joinPath(allocator, separator, system_drive, "zigup");
    } else base: {
        const home = environ_map.get("HOME") orelse return error.HomeNotFound;
        break :base try joinPath(allocator, separator, home, ".zigup");
    };

    return .{
        .base = base,
        .bin = try joinPath(allocator, separator, base, "bin"),
        .versions = try joinPath(allocator, separator, base, "versions"),
        .cache = try joinPath(allocator, separator, base, "cache"),
        .config = try joinPath(allocator, separator, base, "config"),
    };
}

/// Create every role directory that does not exist yet.
pub fn ensureCreated(paths: Paths, io: Io) !void {
    const cwd = Io.Dir.cwd();
    for ([_][]const u8{ paths.bin, paths.versions, paths.cache, paths.config }) |role_path| {
        try cwd.createDirPath(io, role_path);
    }
}

/// `std.fs.path.join` always uses the host's separator; this takes it explicitly.
fn joinPath(allocator: std.mem.Allocator, separator: u8, parent: []const u8, child: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ parent, separator, child });
}

test "resolve on macOS places everything under ~/.zigup" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", "/Users/test");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const paths = try resolveForOs(arena_state.allocator(), &environ_map, .macos);

    try std.testing.expectEqualStrings("/Users/test/.zigup", paths.base);
    try std.testing.expectEqualStrings("/Users/test/.zigup/bin", paths.bin);
    try std.testing.expectEqualStrings("/Users/test/.zigup/versions", paths.versions);
    try std.testing.expectEqualStrings("/Users/test/.zigup/cache", paths.cache);
    try std.testing.expectEqualStrings("/Users/test/.zigup/config", paths.config);
}

test "resolve on Linux places everything under ~/.zigup" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", "/home/test");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const paths = try resolveForOs(arena_state.allocator(), &environ_map, .linux);

    try std.testing.expectEqualStrings("/home/test/.zigup", paths.base);
    try std.testing.expectEqualStrings("/home/test/.zigup/bin", paths.bin);
}

test "resolve without HOME on a Unix system fails" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.HomeNotFound,
        resolveForOs(arena_state.allocator(), &environ_map, .linux),
    );
}

test "resolve on Windows uses zigup at the root of the system drive" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("SystemDrive", "D:");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const paths = try resolveForOs(arena_state.allocator(), &environ_map, .windows);

    try std.testing.expectEqualStrings("D:\\zigup", paths.base);
    try std.testing.expectEqualStrings("D:\\zigup\\bin", paths.bin);
    try std.testing.expectEqualStrings("D:\\zigup\\versions", paths.versions);
    try std.testing.expectEqualStrings("D:\\zigup\\cache", paths.cache);
    try std.testing.expectEqualStrings("D:\\zigup\\config", paths.config);
}

test "resolve on Windows without SystemDrive falls back to C:\\zigup" {
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const paths = try resolveForOs(arena_state.allocator(), &environ_map, .windows);

    try std.testing.expectEqualStrings("C:\\zigup", paths.base);
    try std.testing.expectEqualStrings("C:\\zigup\\cache", paths.cache);
}

test "ensureCreated creates every role directory" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const home_path = try tmp_dir.dir.realPathFileAlloc(io, ".", arena);
    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", home_path);
    try environ_map.put("SystemDrive", home_path);

    const paths = try resolve(arena, &environ_map);
    try ensureCreated(paths, io);
    // Running it again on an existing tree must succeed.
    try ensureCreated(paths, io);

    for ([_][]const u8{ paths.base, paths.bin, paths.versions, paths.cache, paths.config }) |role_path| {
        try Io.Dir.accessAbsolute(io, role_path, .{});
    }
}
