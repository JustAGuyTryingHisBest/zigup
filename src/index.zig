const std = @import("std");

pub const defaultUrl: []const u8 = "https://ziglang.org/download/index.json";

pub const Index = std.json.ArrayHashMap(Release);

pub const Artifact = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: []const u8,
};

pub const Release = struct {
    /// Only present on "master", whose key is not a version.
    version: ?[]const u8 = null,
    date: ?[]const u8 = null,
    docs: ?[]const u8 = null,
    stdDocs: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    src: ?Artifact = null,
    bootstrap: ?Artifact = null,
    /// Every other key is a target such as "aarch64-macos".
    targets: std.array_hash_map.String(Artifact) = .empty,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Release {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Release {
        if (source != .object) return error.UnexpectedToken;
        var release: Release = .{};
        var field_iterator = source.object.iterator();
        next_field: while (field_iterator.next()) |field| {
            const field_name = field.key_ptr.*;
            inline for (.{ "version", "date", "docs", "stdDocs", "notes", "src", "bootstrap" }) |known_field_name| {
                if (std.mem.eql(u8, field_name, known_field_name)) {
                    @field(release, known_field_name) = try std.json.innerParseFromValue(
                        @FieldType(Release, known_field_name),
                        allocator,
                        field.value_ptr.*,
                        options,
                    );
                    continue :next_field;
                }
            }
            const artifact = try std.json.innerParseFromValue(Artifact, allocator, field.value_ptr.*, options);
            try release.targets.put(allocator, field_name, artifact);
        }
        return release;
    }
};

/// How long a cached index is used before it is downloaded again; the same
/// default as ghcup's `meta-cache`.
pub const default_max_age: std.Io.Duration = .fromSeconds(5 * std.time.s_per_min);

/// The index JSON from `url`, using the copy in `cache_path` while it is
/// younger than `max_age`. A stale copy is still used when downloading fails,
/// so zigup keeps working offline. The caller owns the returned bytes.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    url: []const u8,
    max_age: std.Io.Duration,
) ![]u8 {
    var cache_dir = try std.Io.Dir.cwd().createDirPathOpen(io, cache_path, .{});
    defer cache_dir.close(io);
    var cache_file_name_buffer: [cache_file_name_len]u8 = undefined;
    const cache_file_name = cacheFileName(&cache_file_name_buffer, url);

    const cached_stat: ?std.Io.File.Stat = cache_dir.statFile(io, cache_file_name, .{}) catch |stat_error| switch (stat_error) {
        error.FileNotFound => null,
        else => return stat_error,
    };
    if (cached_stat) |stat| {
        const cache_age = stat.mtime.durationTo(std.Io.Timestamp.now(io, .real));
        if (cache_age.nanoseconds < max_age.nanoseconds) {
            return cache_dir.readFileAlloc(io, cache_file_name, allocator, .unlimited);
        }
    }

    const index_json = download(allocator, io, url) catch |download_error| {
        if (cached_stat == null) return download_error;
        std.log.warn("could not download {s} ({t}); using the cached copy", .{ url, download_error });
        return cache_dir.readFileAlloc(io, cache_file_name, allocator, .unlimited);
    };
    errdefer allocator.free(index_json);

    // Replace the cache atomically so a crash never leaves half an index behind.
    var cache_file = try cache_dir.createFileAtomic(io, cache_file_name, .{ .replace = true });
    defer cache_file.deinit(io);
    try cache_file.file.writeStreamingAll(io, index_json);
    try cache_file.replace(io);
    return index_json;
}

/// `load` and parse the index for commands: a missing or invalid index ends the
/// program with a message instead of an error.
pub fn loadParsedOrFatal(allocator: std.mem.Allocator, io: std.Io, cache_path: []const u8, url: []const u8) !std.json.Parsed(Index) {
    const index_json = load(allocator, io, cache_path, url, default_max_age) catch |load_error| switch (load_error) {
        error.OutOfMemory => return load_error,
        else => std.process.fatal("could not download the Zig index from {s}: {t}", .{ url, load_error }),
    };
    defer allocator.free(index_json);
    // `alloc_always` copies every string, so the JSON can be freed here.
    return std.json.parseFromSlice(Index, allocator, index_json, .{ .allocate = .alloc_always }) catch |parse_error| switch (parse_error) {
        error.OutOfMemory => return parse_error,
        else => std.process.fatal("{s} is not a Zig download index: {t}", .{ url, parse_error }),
    };
}

/// Each index URL gets its own cache file, so `--url` never mixes indexes.
pub fn cacheFileName(buffer: *[cache_file_name_len]u8, url: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "index-{x:0>16}.json", .{std.hash.Wyhash.hash(0, url)}) catch unreachable;
}

pub const cache_file_name_len = "index-".len + 16 + ".json".len;

/// Download the index JSON. The caller owns the returned bytes.
pub fn download(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const fetch_result = try http_client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_body.writer,
    });

    if (fetch_result.status != .ok) return error.BadStatus;
    return response_body.toOwnedSlice();
}

const sample_index_json =
    \\{
    \\  "master": {
    \\    "version": "0.18.0-dev.349+d924f83bf",
    \\    "date": "2026-10-17",
    \\    "docs": "https://ziglang.org/documentation/master/",
    \\    "stdDocs": "https://ziglang.org/documentation/master/std/",
    \\    "src": {
    \\      "tarball": "https://ziglang.org/builds/zig-0.18.0-dev.349+d924f83bf.tar.xz",
    \\      "shasum": "c06b28dbfcff6ae2700c241166e23629561aad19aca25837089a95f46feb975d",
    \\      "size": "23162924"
    \\    },
    \\    "aarch64-macos": {
    \\      "tarball": "https://ziglang.org/builds/zig-aarch64-macos-0.18.0-dev.349+d924f83bf.tar.xz",
    \\      "shasum": "c8ffda458a77086cf3b9a6ac7c0909b64233df1d4af731ab32a7f1019df7aea4",
    \\      "size": "55325636"
    \\    }
    \\  },
    \\  "0.17.0": {
    \\    "date": "2026-09-01",
    \\    "docs": "https://ziglang.org/documentation/0.17.0/",
    \\    "notes": "https://ziglang.org/download/0.17.0/release-notes.html",
    \\    "bootstrap": {
    \\      "tarball": "https://ziglang.org/download/0.17.0/zig-bootstrap-0.17.0.tar.xz",
    \\      "shasum": "11f71a6d8714bf24a645010e87868830710f4c72ddff7352ed98181b2df81263",
    \\      "size": "63248080"
    \\    },
    \\    "aarch64-macos": {
    \\      "tarball": "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz",
    \\      "shasum": "0b2e6a5c4f3d1e8b7a9c0d2f4e6b8a1c3d5f7e9b0a2c4e6f8b1d3a5c7e9f0b2d",
    \\      "size": "53985220"
    \\    },
    \\    "x86_64-linux": {
    \\      "tarball": "https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz",
    \\      "shasum": "4f6e8d0c2b4a6f8e0d2c4b6a8f0e2d4c6b8a0f2e4d6c8b0a2f4e6d8c0b2a4f6e",
    \\      "size": "57000000"
    \\    }
    \\  }
    \\}
;

test "parse keeps releases in index order" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const index = try std.json.parseFromSliceLeaky(Index, arena_state.allocator(), sample_index_json, .{});

    try std.testing.expectEqual(@as(usize, 2), index.map.count());
    try std.testing.expectEqualStrings("master", index.map.keys()[0]);
    try std.testing.expectEqualStrings("0.17.0", index.map.keys()[1]);
}

test "parse reads the known release fields" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const index = try std.json.parseFromSliceLeaky(Index, arena_state.allocator(), sample_index_json, .{});

    const master = index.map.get("master").?;
    try std.testing.expectEqualStrings("0.18.0-dev.349+d924f83bf", master.version.?);
    try std.testing.expectEqualStrings("2026-10-17", master.date.?);
    try std.testing.expectEqualStrings("https://ziglang.org/documentation/master/std/", master.stdDocs.?);
    try std.testing.expectEqualStrings("23162924", master.src.?.size);
    try std.testing.expectEqual(@as(?[]const u8, null), master.notes);
    try std.testing.expectEqual(@as(?Artifact, null), master.bootstrap);

    const release = index.map.get("0.17.0").?;
    try std.testing.expectEqual(@as(?[]const u8, null), release.version);
    try std.testing.expectEqualStrings("https://ziglang.org/download/0.17.0/release-notes.html", release.notes.?);
    try std.testing.expectEqualStrings("63248080", release.bootstrap.?.size);
    try std.testing.expectEqual(@as(?Artifact, null), release.src);
}

test "parse collects every other release key as a target" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const index = try std.json.parseFromSliceLeaky(Index, arena_state.allocator(), sample_index_json, .{});

    const release = index.map.get("0.17.0").?;
    try std.testing.expectEqual(@as(usize, 2), release.targets.count());
    try std.testing.expectEqualStrings("aarch64-macos", release.targets.keys()[0]);
    try std.testing.expectEqualStrings("x86_64-linux", release.targets.keys()[1]);

    const artifact = release.targets.get("aarch64-macos").?;
    try std.testing.expectEqualStrings("https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz", artifact.tarball);
    try std.testing.expectEqualStrings("0b2e6a5c4f3d1e8b7a9c0d2f4e6b8a1c3d5f7e9b0a2c4e6f8b1d3a5c7e9f0b2d", artifact.shasum);
    try std.testing.expectEqualStrings("53985220", artifact.size);

    // Known fields such as "src", "bootstrap" and "notes" must not leak into targets.
    for ([_][]const u8{ "version", "date", "docs", "stdDocs", "notes", "src", "bootstrap" }) |known_field_name| {
        try std.testing.expect(!release.targets.contains(known_field_name));
        try std.testing.expect(!index.map.get("master").?.targets.contains(known_field_name));
    }
}

test "parse rejects a release that is not an object" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSliceLeaky(Index, arena_state.allocator(), "{\"0.17.0\": \"not a release\"}", .{}),
    );
}

test "parse rejects a target without a shasum" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.MissingField,
        std.json.parseFromSliceLeaky(
            Index,
            arena_state.allocator(),
            "{\"0.17.0\": {\"aarch64-macos\": {\"tarball\": \"https://example.invalid/zig.tar.xz\", \"size\": \"1\"}}}",
            .{},
        ),
    );
}

test "parse works with the non-leaky API" {
    const parsed = try std.json.parseFromSlice(Index, std.testing.allocator, sample_index_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("55325636", parsed.value.map.get("master").?.targets.get("aarch64-macos").?.size);
}

/// Nothing listens on port 1, so connecting fails immediately, like being offline.
const unreachable_url = "http://127.0.0.1:1/index.json";

fn writeTestCache(tmp_dir: std.testing.TmpDir, url: []const u8, contents: []const u8) !void {
    var cache_file_name_buffer: [cache_file_name_len]u8 = undefined;
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = cacheFileName(&cache_file_name_buffer, url),
        .data = contents,
    });
}

test "load uses a fresh cached index without downloading" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const cache_path = try tmp_dir.dir.realPathFileAlloc(io, ".", arena_state.allocator());
    try writeTestCache(tmp_dir, unreachable_url, "{\"cached\": {}}");

    const index_json = try load(std.testing.allocator, io, cache_path, unreachable_url, .fromSeconds(std.time.s_per_hour));
    defer std.testing.allocator.free(index_json);

    try std.testing.expectEqualStrings("{\"cached\": {}}", index_json);
}

test "load falls back to a stale cached index when downloading fails" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const cache_path = try tmp_dir.dir.realPathFileAlloc(io, ".", arena_state.allocator());
    try writeTestCache(tmp_dir, unreachable_url, "{\"stale\": {}}");

    const index_json = try load(std.testing.allocator, io, cache_path, unreachable_url, .fromSeconds(0));
    defer std.testing.allocator.free(index_json);

    try std.testing.expectEqualStrings("{\"stale\": {}}", index_json);
}

test "load fails when there is no cache and downloading fails" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const cache_path = try tmp_dir.dir.realPathFileAlloc(io, ".", arena_state.allocator());

    try std.testing.expectError(error.ConnectionRefused, load(std.testing.allocator, io, cache_path, unreachable_url, default_max_age));
}

test "load ignores the cache of a different index url" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const cache_path = try tmp_dir.dir.realPathFileAlloc(io, ".", arena_state.allocator());
    try writeTestCache(tmp_dir, defaultUrl, "{\"default index\": {}}");

    try std.testing.expectError(error.ConnectionRefused, load(std.testing.allocator, io, cache_path, unreachable_url, default_max_age));
}

test "cacheFileName is stable per url and differs between urls" {
    var first_buffer: [cache_file_name_len]u8 = undefined;
    var second_buffer: [cache_file_name_len]u8 = undefined;
    var other_buffer: [cache_file_name_len]u8 = undefined;
    const first_name = cacheFileName(&first_buffer, defaultUrl);

    try std.testing.expect(std.mem.startsWith(u8, first_name, "index-"));
    try std.testing.expect(std.mem.endsWith(u8, first_name, ".json"));
    try std.testing.expectEqualStrings(first_name, cacheFileName(&second_buffer, defaultUrl));
    try std.testing.expect(!std.mem.eql(u8, first_name, cacheFileName(&other_buffer, unreachable_url)));
}
