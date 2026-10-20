const std = @import("std");
const cli = @import("cli.zig");
const dirs = @import("dirs.zig");
const index = @import("index.zig");
const minizign = @import("minizign");

// pub key taken from ziglang.org/download
pub const zfs_pubkey: []const u8 = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

pub const InstallCtx = struct {
    /// The versions directory, such as `dirs.Paths.versions`.
    path: []const u8,
    /// Name of the installed folder under `path`, such as "0.17.0" or "master".
    version: []const u8,
    release: index.Release,
    mirror: []const u8,
    /// Key into `release.targets`, such as "aarch64-macos".
    target: []const u8 = cli.index_target_key,
    // I am not sure why you would not want to validate but we are
    // giving you the ability to shoot yourself in the foot if you'd like.
    //
    // Default to sane behavior though
    should_validate: bool = true,
};

pub const FoundRelease = struct {
    /// Folder name under the versions directory.
    name: []const u8,
    release: index.Release,
};

/// Look up `requested_version` in the index. "master" is installed under its
/// dev version, such as "0.18.0-dev.349+d924f83bf", since it moves daily.
pub fn find_release(parsed_index: index.Index, requested_version: []const u8) !FoundRelease {
    const release = parsed_index.map.get(requested_version) orelse return error.UnknownVersion;
    return .{ .name = release.version orelse requested_version, .release = release };
}

/// `zigup install <version>`: download the release from a community mirror,
/// verify it, and extract it into the versions directory.
pub fn main(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    options: cli.Install,
    mirror_urls: []const []const u8,
) !void {
    const paths = try dirs.resolveOrFatal(allocator, environ_map);
    try dirs.ensureCreated(paths, io);

    const parsed_index = try index.loadParsedOrFatal(allocator, io, paths.cache, options.url);
    defer parsed_index.deinit();
    const found_release = find_release(parsed_index.value, options.version) catch |find_error| switch (find_error) {
        error.UnknownVersion => std.process.fatal(
            "{s} is not in the index at {s}; run `zigup list` to see the available versions",
            .{ options.version, options.url },
        ),
    };
    if (!found_release.release.targets.contains(cli.index_target_key)) {
        std.process.fatal("zig {s} has no download for {s}", .{ options.version, cli.index_target_key });
    }
    // Check before downloading tens of megabytes.
    ensure_not_installed(io, paths.versions, found_release.name) catch |installed_error| switch (installed_error) {
        error.VersionAlreadyInstalled => std.process.fatal(
            "zig {s} is already installed in {s}{c}{s}",
            .{ found_release.name, paths.versions, std.fs.path.sep, found_release.name },
        ),
        else => return installed_error,
    };

    // Try mirrors in random order to spread the load, as ziglang.org asks.
    const shuffled_mirror_urls = try allocator.dupe([]const u8, mirror_urls);
    defer allocator.free(shuffled_mirror_urls);
    var random_seed: u64 = undefined;
    io.random(std.mem.asBytes(&random_seed));
    var prng: std.Random.DefaultPrng = .init(random_seed);
    prng.random().shuffle([]const u8, shuffled_mirror_urls);

    const ctx: InstallCtx = .{
        .path = paths.versions,
        .version = found_release.name,
        .release = found_release.release,
        .mirror = "",
    };
    // A failed download or signature check only rules out that mirror.
    const fetched_release = fetch_from_mirrors(allocator, io, ctx, shuffled_mirror_urls, null) catch |fetch_error| switch (fetch_error) {
        error.OutOfMemory => return fetch_error,
        else => std.process.fatal("could not download zig {s} from any of the {d} mirrors", .{ found_release.name, mirror_urls.len }),
    };
    defer allocator.free(fetched_release.tarball);
    try install_release(allocator, io, ctx, fetched_release.tarball, null);
    try link_version(allocator, io, paths.bin, paths.versions, found_release.name);
    std.log.info("installed zig {s} to {s}{c}{s} and linked it into {s}", .{
        found_release.name, paths.versions, std.fs.path.sep, found_release.name, paths.bin,
    });
}

/// Mirrors serve every file at `<mirror>/<basename of the ziglang.org URL>`,
/// and ask tools to identify themselves with a `source` query parameter.
/// See https://ziglang.org/download/community-mirrors/.
pub fn create_release_url(ctx: InstallCtx, buffer: []u8) ![]u8 {
    return create_mirror_url(ctx, "", buffer);
}

/// Like `create_release_url`, for the tarball's minisign signature.
pub fn create_minisig_url(ctx: InstallCtx, buffer: []u8) ![]u8 {
    return create_mirror_url(ctx, ".minisig", buffer);
}

fn create_mirror_url(ctx: InstallCtx, suffix: []const u8, buffer: []u8) ![]u8 {
    const mirror = std.mem.trimEnd(u8, ctx.mirror, "/");
    return std.fmt.bufPrint(buffer, "{s}/{s}{s}?source=zigup", .{ mirror, try release_tarball_name(ctx), suffix });
}

/// The file name ziglang.org gives the tarball, such as
/// "zig-aarch64-macos-0.17.0.tar.xz". Older releases order the parts differently.
fn release_tarball_name(ctx: InstallCtx) ![]const u8 {
    const artifact = ctx.release.targets.get(ctx.target) orelse return error.UnsupportedTarget;
    return std.fs.path.basenamePosix(artifact.tarball);
}

/// Download the release tarball from `ctx.mirror`. Unless `ctx.should_validate`
/// is false, also download its `.minisig` and verify the tarball against the
/// ZSF key before returning it. The caller owns the returned bytes.
/// How far an install has got, for showing progress from another thread.
pub const Progress = struct {
    stage: std.atomic.Value(Stage) = .init(.downloading),
    received_bytes: std.atomic.Value(u64) = .init(0),
    total_bytes: std.atomic.Value(u64) = .init(0),
    /// Index into the mirror slice passed to `fetch_from_mirrors`.
    mirror_index: std.atomic.Value(usize) = .init(0),

    pub const Stage = enum(u8) { downloading, verifying, extracting };
};

pub const FetchedRelease = struct {
    tarball: []u8,
    mirror_url: []const u8,
};

/// Try `mirror_urls` in the given order (callers shuffle them); a failed
/// download or signature check moves on to the next. With several mirrors,
/// returns `error.AllMirrorsFailed` when none works; with exactly one, returns
/// that mirror's own error. `ctx.mirror` is ignored.
pub fn fetch_from_mirrors(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: InstallCtx,
    mirror_urls: []const []const u8,
    progress: ?*Progress,
) !FetchedRelease {
    var last_error: anyerror = error.AllMirrorsFailed;
    for (mirror_urls, 0..) |mirror_url, mirror_index| {
        if (progress) |install_progress| install_progress.mirror_index.store(mirror_index, .monotonic);
        var mirror_ctx = ctx;
        mirror_ctx.mirror = mirror_url;
        // No logging here: the TUI owns the terminal while this runs.
        const tarball = fetch_release(allocator, io, mirror_ctx, progress) catch |fetch_error| switch (fetch_error) {
            error.OutOfMemory => return fetch_error,
            else => {
                last_error = fetch_error;
                continue;
            },
        };
        return .{ .tarball = tarball, .mirror_url = mirror_url };
    }
    if (mirror_urls.len == 1) return last_error;
    return error.AllMirrorsFailed;
}

pub fn fetch_release(allocator: std.mem.Allocator, io: std.Io, ctx: InstallCtx, progress: ?*Progress) ![]u8 {
    if (progress) |install_progress| {
        const artifact = ctx.release.targets.get(ctx.target) orelse return error.UnsupportedTarget;
        install_progress.stage.store(.downloading, .monotonic);
        install_progress.received_bytes.store(0, .monotonic);
        install_progress.total_bytes.store(std.fmt.parseInt(u64, artifact.size, 10) catch 0, .monotonic);
    }

    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    var url_buffer: [1024]u8 = undefined;
    const tarball = try fetch_url(allocator, &http_client, try create_release_url(ctx, &url_buffer), progress);
    errdefer allocator.free(tarball);

    if (ctx.should_validate) {
        if (progress) |install_progress| install_progress.stage.store(.verifying, .monotonic);
        const minisig = try fetch_url(allocator, &http_client, try create_minisig_url(ctx, &url_buffer), null);
        defer allocator.free(minisig);
        try validate_release(allocator, zfs_pubkey, tarball, minisig, try release_tarball_name(ctx));
    }
    return tarball;
}

/// A response body in memory that adds each byte it receives to
/// `Progress.received_bytes`.
/// Follows `std.Io.Writer.Hashed`: a buffered writer whose `drain` forwards to
/// the wrapped writer and counts what it forwarded.
const ProgressWriter = struct {
    response_body: std.Io.Writer.Allocating,
    progress: ?*Progress,
    interface: std.Io.Writer,
    buffer: [4096]u8 = undefined,

    fn init(allocator: std.mem.Allocator, progress: ?*Progress) ProgressWriter {
        return .{
            .response_body = .init(allocator),
            .progress = progress,
            // `writer` points this at `buffer` once the struct has its final address.
            .interface = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    fn deinit(progress_writer: *ProgressWriter) void {
        progress_writer.response_body.deinit();
    }

    fn writer(progress_writer: *ProgressWriter) *std.Io.Writer {
        if (progress_writer.interface.buffer.len == 0) progress_writer.interface.buffer = &progress_writer.buffer;
        return &progress_writer.interface;
    }

    /// Everything received so far; call after flushing `writer()`.
    fn written(progress_writer: *ProgressWriter) []u8 {
        return progress_writer.response_body.written();
    }

    fn toOwnedSlice(progress_writer: *ProgressWriter) ![]u8 {
        try progress_writer.writer().flush();
        return progress_writer.response_body.toOwnedSlice();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const progress_writer: *ProgressWriter = @alignCast(@fieldParentPtr("interface", w));
        const buffered = w.buffered();
        const forwarded = try progress_writer.response_body.writer.writeSplatHeader(buffered, data, splat);
        if (progress_writer.progress) |install_progress| _ = install_progress.received_bytes.fetchAdd(forwarded, .monotonic);
        if (forwarded < w.end) {
            const remaining = w.buffer[forwarded..w.end];
            @memmove(w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
            return 0;
        }
        const consumed_from_data = forwarded - w.end;
        w.end = 0;
        return consumed_from_data;
    }
};

fn fetch_url(allocator: std.mem.Allocator, http_client: *std.http.Client, url: []const u8, progress: ?*Progress) ![]u8 {
    var response_body: ProgressWriter = .init(allocator, progress);
    defer response_body.deinit();

    const fetch_result = try http_client.fetch(.{
        .location = .{ .url = url },
        .response_writer = response_body.writer(),
    });
    if (fetch_result.status != .ok) return error.BadStatus;
    return response_body.toOwnedSlice();
}

/// Verify `tarball` against its `.minisig` and `public_key` (base64, such as
/// `zfs_pubkey`). The signed trusted comment must also name `tarball_name`, so
/// a mirror cannot substitute a different, genuinely signed release.
pub fn validate_release(
    allocator: std.mem.Allocator,
    public_key: []const u8,
    tarball: []const u8,
    minisig: []const u8,
    tarball_name: []const u8,
) !void {
    const minisign_public_key: minizign.PublicKey = try .decodeFromBase64(public_key);
    var signature: minizign.Signature = try .decode(allocator, minisig);
    defer signature.deinit();

    var verifier = try minisign_public_key.verifier(&signature);
    verifier.update(tarball);
    try verifier.verify(allocator);

    // The trusted comment is tab separated, such as
    // "timestamp:1790965659\tfile:zig-aarch64-macos-0.17.0.tar.xz\thashed".
    var trusted_comment_fields = std.mem.splitScalar(u8, signature.trusted_comment, '\t');
    while (trusted_comment_fields.next()) |trusted_comment_field| {
        if (std.mem.startsWith(u8, trusted_comment_field, "file:")) {
            if (std.mem.eql(u8, trusted_comment_field["file:".len..], tarball_name)) return;
            return error.TarballNameMismatch;
        }
    }
    return error.TarballNameMismatch;
}

/// Make `<bin_path>/zig` point at `<versions_path>/<version_name>/zig`, replacing
/// any existing link, so that version becomes the active one.
pub fn link_version(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin_path: []const u8,
    versions_path: []const u8,
    version_name: []const u8,
) !void {
    const zig_exe_name = if (@import("builtin").os.tag == .windows) "zig.exe" else "zig";
    const target_path = try std.fs.path.join(allocator, &.{ versions_path, version_name, zig_exe_name });
    defer allocator.free(target_path);
    // A link to a missing binary would leave `zig` broken on the PATH.
    std.Io.Dir.cwd().access(io, target_path, .{}) catch |access_error| switch (access_error) {
        error.FileNotFound => return error.VersionNotInstalled,
        else => return access_error,
    };

    const link_path = try std.fs.path.join(allocator, &.{ bin_path, zig_exe_name });
    defer allocator.free(link_path);
    // The zig binary finds its lib directory relative to its resolved path, so
    // a symbolic link works where a copy or hard link would not.
    try std.Io.Dir.cwd().symLinkAtomic(io, target_path, link_path, .{});
}

/// Fail with `error.VersionAlreadyInstalled` if `<versions_path>/<version_name>` exists.
pub fn ensure_not_installed(io: std.Io, versions_path: []const u8, version_name: []const u8) !void {
    var versions_dir = std.Io.Dir.cwd().openDir(io, versions_path, .{}) catch |open_error| switch (open_error) {
        error.FileNotFound => return,
        else => return open_error,
    };
    defer versions_dir.close(io);
    if (versions_dir.access(io, version_name, .{})) |_| {
        return error.VersionAlreadyInstalled;
    } else |access_error| switch (access_error) {
        error.FileNotFound => {},
        else => return access_error,
    }
}

/// Extract a verified `tarball` (from `fetch_release`) into
/// `<ctx.path>/<ctx.version>`, without the archive's top-level folder.
pub fn install_release(allocator: std.mem.Allocator, io: std.Io, ctx: InstallCtx, tarball: []const u8, progress: ?*Progress) !void {
    const archive_name = try release_tarball_name(ctx);
    const ArchiveFormat = enum { tar_xz, zip };
    const archive_format: ArchiveFormat = if (std.mem.endsWith(u8, archive_name, ".tar.xz"))
        .tar_xz
    else if (std.mem.endsWith(u8, archive_name, ".zip"))
        .zip
    else
        return error.UnsupportedArchive;
    if (progress) |install_progress| install_progress.stage.store(.extracting, .monotonic);

    try ensure_not_installed(io, ctx.path, ctx.version);
    var versions_dir = try std.Io.Dir.cwd().createDirPathOpen(io, ctx.path, .{});
    defer versions_dir.close(io);

    // Extract beside the destination and rename into place, so a failed
    // install never leaves a half-written version behind.
    const staging_name = try std.fmt.allocPrint(allocator, ".{s}.partial", .{ctx.version});
    defer allocator.free(staging_name);
    try versions_dir.deleteTree(io, staging_name);
    defer versions_dir.deleteTree(io, staging_name) catch {};
    var staging_dir = try versions_dir.createDirPathOpen(io, staging_name, .{ .open_options = .{ .iterate = true } });
    defer staging_dir.close(io);

    switch (archive_format) {
        .tar_xz => {
            var compressed_reader: std.Io.Reader = .fixed(tarball);
            var xz_decompress: std.compress.xz.Decompress = try .init(&compressed_reader, allocator, &.{});
            defer xz_decompress.deinit();
            try std.tar.extract(io, staging_dir, &xz_decompress.reader, .{});
        },
        .zip => {
            // std.zip reads the central directory at the end, so it needs a seekable file.
            const zip_name = try std.fmt.allocPrint(allocator, ".{s}.zip", .{ctx.version});
            defer allocator.free(zip_name);
            try versions_dir.writeFile(io, .{ .sub_path = zip_name, .data = tarball });
            defer versions_dir.deleteFile(io, zip_name) catch {};

            var zip_file = try versions_dir.openFile(io, zip_name, .{});
            defer zip_file.close(io);
            var zip_read_buffer: [4096]u8 = undefined;
            var zip_reader = zip_file.reader(io, &zip_read_buffer);
            try std.zip.extract(staging_dir, &zip_reader, .{ .allow_backslashes = true });
        },
    }

    // Zig archives hold a single folder named after the archive, such as
    // "zig-aarch64-macos-0.17.0"; it becomes `<ctx.path>/<ctx.version>`.
    var staging_iterator = staging_dir.iterate();
    const archive_root = try staging_iterator.next(io) orelse return error.UnexpectedArchiveLayout;
    if (archive_root.kind != .directory) return error.UnexpectedArchiveLayout;
    const archive_root_name = try allocator.dupe(u8, archive_root.name);
    defer allocator.free(archive_root_name);
    if (try staging_iterator.next(io) != null) return error.UnexpectedArchiveLayout;

    try std.Io.Dir.rename(staging_dir, archive_root_name, versions_dir, ctx.version, io);
}

fn testRelease(allocator: std.mem.Allocator) !index.Release {
    var release: index.Release = .{};
    try release.targets.put(allocator, "aarch64-macos", .{
        .tarball = "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz",
        .shasum = "0b2e6a5c4f3d1e8b7a9c0d2f4e6b8a1c3d5f7e9b0a2c4e6f8b1d3a5c7e9f0b2d",
        .size = "53985220",
    });
    try release.targets.put(allocator, "x86_64-macos", .{
        // Releases before 0.14.1 put the OS before the architecture.
        .tarball = "https://ziglang.org/download/0.13.0/zig-macos-x86_64-0.13.0.tar.xz",
        .shasum = "8b06ed1091b2269b700b3b07f8e3be3b833000841bae5aa6a09b1a8b4773effd",
        .size = "48857012",
    });
    return release;
}

test "create_release_url requests the tarball from the mirror" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var url_buffer: [256]u8 = undefined;

    const url = try create_release_url(.{
        .path = "",
        .version = "0.17.0",
        .release = try testRelease(arena_state.allocator()),
        .mirror = "https://pkg.earth/zig",
        .target = "aarch64-macos",
    }, &url_buffer);

    try std.testing.expectEqualStrings("https://pkg.earth/zig/zig-aarch64-macos-0.17.0.tar.xz?source=zigup", url);
}

test "create_release_url keeps the tarball name from the index" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var url_buffer: [256]u8 = undefined;

    const url = try create_release_url(.{
        .path = "",
        .version = "0.17.0",
        .release = try testRelease(arena_state.allocator()),
        .mirror = "https://pkg.earth/zig",
        .target = "x86_64-macos",
    }, &url_buffer);

    try std.testing.expectEqualStrings("https://pkg.earth/zig/zig-macos-x86_64-0.13.0.tar.xz?source=zigup", url);
}

test "create_release_url ignores a trailing slash on the mirror" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var url_buffer: [256]u8 = undefined;

    const url = try create_release_url(.{
        .path = "",
        .version = "0.17.0",
        .release = try testRelease(arena_state.allocator()),
        .mirror = "https://zigmirror.com/",
        .target = "aarch64-macos",
    }, &url_buffer);

    try std.testing.expectEqualStrings("https://zigmirror.com/zig-aarch64-macos-0.17.0.tar.xz?source=zigup", url);
}

test "create_release_url fails for a target the release does not ship" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var url_buffer: [256]u8 = undefined;

    try std.testing.expectError(error.UnsupportedTarget, create_release_url(.{
        .path = "",
        .version = "0.17.0",
        .release = try testRelease(arena_state.allocator()),
        .mirror = "https://pkg.earth/zig",
        .target = "riscv64-freebsd",
    }, &url_buffer));
}

test "create_minisig_url requests the signature next to the tarball" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var url_buffer: [256]u8 = undefined;

    const url = try create_minisig_url(.{
        .path = "",
        .version = "0.17.0",
        .release = try testRelease(arena_state.allocator()),
        .mirror = "https://pkg.earth/zig/",
        .target = "aarch64-macos",
    }, &url_buffer);

    try std.testing.expectEqualStrings("https://pkg.earth/zig/zig-aarch64-macos-0.17.0.tar.xz.minisig?source=zigup", url);
}

test "create_minisig_url fails for a target the release does not ship" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var url_buffer: [256]u8 = undefined;

    try std.testing.expectError(error.UnsupportedTarget, create_minisig_url(.{
        .path = "",
        .version = "0.17.0",
        .release = try testRelease(arena_state.allocator()),
        .mirror = "https://pkg.earth/zig",
        .target = "riscv64-freebsd",
    }, &url_buffer));
}

test "create_release_url fails when the buffer is too small" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var url_buffer: [16]u8 = undefined;

    try std.testing.expectError(error.NoSpaceLeft, create_release_url(.{
        .path = "",
        .version = "0.17.0",
        .release = try testRelease(arena_state.allocator()),
        .mirror = "https://pkg.earth/zig",
        .target = "aarch64-macos",
    }, &url_buffer));
}

/// A minisign key pair and a `.minisig` writer, so the tests do not depend on
/// a real Zig tarball.
const TestSigner = struct {
    key_pair: std.crypto.sign.Ed25519.KeyPair,
    key_id: [8]u8,

    fn init(seed_byte: u8, key_id_byte: u8) !TestSigner {
        return .{
            .key_pair = try .generateDeterministic(@splat(seed_byte)),
            .key_id = @splat(key_id_byte),
        };
    }

    fn publicKey(signer: TestSigner, buffer: *[56]u8) []const u8 {
        const public_key_bytes = "Ed".* ++ signer.key_id ++ signer.key_pair.public_key.toBytes();
        return std.base64.standard.Encoder.encode(buffer, &public_key_bytes);
    }

    fn minisig(signer: TestSigner, allocator: std.mem.Allocator, tarball: []const u8, trusted_comment: []const u8) ![]const u8 {
        var tarball_hash: [64]u8 = undefined;
        std.crypto.hash.blake2.Blake2b512.hash(tarball, &tarball_hash, .{});
        const signature = (try signer.key_pair.sign(&tarball_hash, null)).toBytes();
        const global_signature = (try signer.key_pair.sign(
            try std.mem.concat(allocator, u8, &.{ &signature, trusted_comment }),
            null,
        )).toBytes();

        const signature_line_bytes = "ED".* ++ signer.key_id ++ signature;
        var signature_line: [100]u8 = undefined;
        var global_signature_line: [88]u8 = undefined;
        return std.fmt.allocPrint(allocator, "untrusted comment: test\n{s}\ntrusted comment: {s}\n{s}\n", .{
            std.base64.standard.Encoder.encode(&signature_line, &signature_line_bytes),
            trusted_comment,
            std.base64.standard.Encoder.encode(&global_signature_line, &global_signature),
        });
    }
};

const test_tarball = "pretend this is zig-aarch64-macos-0.17.0.tar.xz";
const test_trusted_comment = "timestamp:1790965659\tfile:zig-aarch64-macos-0.17.0.tar.xz\thashed";

test "validate_release accepts a correctly signed tarball" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const signer: TestSigner = try .init(1, 2);
    var public_key_buffer: [56]u8 = undefined;

    try validate_release(
        arena,
        signer.publicKey(&public_key_buffer),
        test_tarball,
        try signer.minisig(arena, test_tarball, test_trusted_comment),
        "zig-aarch64-macos-0.17.0.tar.xz",
    );
}

test "validate_release rejects a modified tarball" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const signer: TestSigner = try .init(1, 2);
    var public_key_buffer: [56]u8 = undefined;

    try std.testing.expectError(error.SignatureVerificationFailed, validate_release(
        arena,
        signer.publicKey(&public_key_buffer),
        "a modified tarball",
        try signer.minisig(arena, test_tarball, test_trusted_comment),
        "zig-aarch64-macos-0.17.0.tar.xz",
    ));
}

test "validate_release rejects a signature for a different tarball name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const signer: TestSigner = try .init(1, 2);
    var public_key_buffer: [56]u8 = undefined;

    // A genuine, correctly signed older release served in place of the requested one.
    try std.testing.expectError(error.TarballNameMismatch, validate_release(
        arena,
        signer.publicKey(&public_key_buffer),
        test_tarball,
        try signer.minisig(arena, test_tarball, "timestamp:1700000000\tfile:zig-aarch64-macos-0.11.0.tar.xz\thashed"),
        "zig-aarch64-macos-0.17.0.tar.xz",
    ));
}

test "validate_release rejects a trusted comment without a file field" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const signer: TestSigner = try .init(1, 2);
    var public_key_buffer: [56]u8 = undefined;

    try std.testing.expectError(error.TarballNameMismatch, validate_release(
        arena,
        signer.publicKey(&public_key_buffer),
        test_tarball,
        try signer.minisig(arena, test_tarball, "timestamp:1790965659\thashed"),
        "zig-aarch64-macos-0.17.0.tar.xz",
    ));
}

test "validate_release rejects a signature from another key" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const signer: TestSigner = try .init(1, 2);
    const other_signer: TestSigner = try .init(3, 4);
    var public_key_buffer: [56]u8 = undefined;

    try std.testing.expectError(error.KeyIdMismatch, validate_release(
        arena,
        signer.publicKey(&public_key_buffer),
        test_tarball,
        try other_signer.minisig(arena, test_tarball, test_trusted_comment),
        "zig-aarch64-macos-0.17.0.tar.xz",
    ));
}

test "validate_release checks a real Zig signature against the ZSF key" {
    // ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz.minisig
    const real_minisig = "untrusted comment: signature from minisign secret key\n" ++
        "RUSGOq2NVecA2Qso9uzqlH38Gxi7akzTeQeEKtkRJQXxgCvTzfc5XY3SRtzuWQYwnV8+VTuLDzq8AdyuP9aEp2jpdgM8OBBiCgk=\n" ++
        "trusted comment: timestamp:1790965659\tfile:zig-aarch64-macos-0.17.0.tar.xz\thashed\n" ++
        "HtSM4OeDtYztRTod8yiwAqPPIaClGsYaZYQE2ZZnNSE7CCVkFm8wEY3cY/qmsnfu+UWdYwmILx3GQO9cjoJjCQ==\n";
    // The key and signature formats are accepted; only the content check fails,
    // because these bytes are not the real tarball.
    try std.testing.expectError(error.SignatureVerificationFailed, validate_release(
        std.testing.allocator,
        zfs_pubkey,
        "not the real tarball",
        real_minisig,
        "zig-aarch64-macos-0.17.0.tar.xz",
    ));
}

fn testInstallCtx(arena: std.mem.Allocator, versions_path: []const u8, tarball_url: []const u8) !InstallCtx {
    var release: index.Release = .{};
    try release.targets.put(arena, "test-target", .{ .tarball = tarball_url, .shasum = "", .size = "" });
    return .{
        .path = versions_path,
        .version = "0.17.0",
        .release = release,
        .mirror = "https://pkg.earth/zig",
        .target = "test-target",
    };
}

fn testVersionsPath(arena: std.mem.Allocator, tmp_dir: std.testing.TmpDir) ![]const u8 {
    const io = std.testing.io;
    try tmp_dir.dir.createDirPath(io, "versions");
    return tmp_dir.dir.realPathFileAlloc(io, "versions", arena);
}

const test_tar_xz = @embedFile("testdata/zig-aarch64-macos-0.17.0.tar.xz");
const test_zip = @embedFile("testdata/zig-x86_64-windows-0.17.0.zip");

test "install_release extracts a tar.xz into the versions directory" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ctx = try testInstallCtx(arena, try testVersionsPath(arena, tmp_dir), "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz");
    try install_release(arena, io, ctx, test_tar_xz, null);

    const zig_script = try tmp_dir.dir.readFileAlloc(io, "versions/0.17.0/zig", arena, .unlimited);
    try std.testing.expectEqualStrings("#!/bin/sh\necho fake zig\n", zig_script);
    const std_source = try tmp_dir.dir.readFileAlloc(io, "versions/0.17.0/lib/std/std.zig", arena, .unlimited);
    try std.testing.expectEqualStrings("pub const fake = true;\n", std_source);
}

test "install_release keeps the zig binary executable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ctx = try testInstallCtx(arena, try testVersionsPath(arena, tmp_dir), "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz");
    try install_release(arena, io, ctx, test_tar_xz, null);

    const zig_stat = try tmp_dir.dir.statFile(io, "versions/0.17.0/zig", .{});
    try std.testing.expect(zig_stat.permissions.toMode() & 0o100 != 0);
}

test "install_release extracts a Windows zip into the versions directory" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ctx = try testInstallCtx(arena, try testVersionsPath(arena, tmp_dir), "https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip");
    try install_release(arena, io, ctx, test_zip, null);

    const zig_exe = try tmp_dir.dir.readFileAlloc(io, "versions/0.17.0/zig.exe", arena, .unlimited);
    try std.testing.expectEqualStrings("MZ fake zig.exe\n", zig_exe);
    const std_source = try tmp_dir.dir.readFileAlloc(io, "versions/0.17.0/lib/std/std.zig", arena, .unlimited);
    try std.testing.expectEqualStrings("pub const fake = true;\n", std_source);
}

test "install_release refuses to overwrite an installed version" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ctx = try testInstallCtx(arena, try testVersionsPath(arena, tmp_dir), "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz");
    try tmp_dir.dir.createDirPath(io, "versions/0.17.0");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "versions/0.17.0/zig", .data = "already here" });

    try std.testing.expectError(error.VersionAlreadyInstalled, install_release(arena, io, ctx, test_tar_xz, null));
    const zig_file = try tmp_dir.dir.readFileAlloc(io, "versions/0.17.0/zig", arena, .unlimited);
    try std.testing.expectEqualStrings("already here", zig_file);
}

test "install_release leaves nothing behind when the archive is corrupt" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ctx = try testInstallCtx(arena, try testVersionsPath(arena, tmp_dir), "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz");
    try std.testing.expectError(error.NotXzStream, install_release(arena, io, ctx, "not an xz stream", null));

    var versions_dir = try tmp_dir.dir.openDir(io, "versions", .{ .iterate = true });
    defer versions_dir.close(io);
    var versions_iterator = versions_dir.iterate();
    try std.testing.expectEqual(null, try versions_iterator.next(io));
}

test "install_release rejects an unknown archive format" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ctx = try testInstallCtx(arena, try testVersionsPath(arena, tmp_dir), "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.gz");
    try std.testing.expectError(error.UnsupportedArchive, install_release(arena, io, ctx, test_tar_xz, null));
}

test "find_release returns a tagged release under its own name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed_index = try std.json.parseFromSliceLeaky(index.Index, arena_state.allocator(),
        \\{"master": {"version": "0.18.0-dev.349+d924f83bf"}, "0.17.0": {"date": "2026-09-01"}}
    , .{});

    const found_release = try find_release(parsed_index, "0.17.0");
    try std.testing.expectEqualStrings("0.17.0", found_release.name);
    try std.testing.expectEqualStrings("2026-09-01", found_release.release.date.?);
}

test "find_release names master after its dev version" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed_index = try std.json.parseFromSliceLeaky(index.Index, arena_state.allocator(),
        \\{"master": {"version": "0.18.0-dev.349+d924f83bf"}, "0.17.0": {"date": "2026-09-01"}}
    , .{});

    const found_release = try find_release(parsed_index, "master");
    try std.testing.expectEqualStrings("0.18.0-dev.349+d924f83bf", found_release.name);
}

test "find_release rejects a version missing from the index" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed_index = try std.json.parseFromSliceLeaky(index.Index, arena_state.allocator(),
        \\{"0.17.0": {"date": "2026-09-01"}}
    , .{});

    try std.testing.expectError(error.UnknownVersion, find_release(parsed_index, "0.99.0"));
}

test "ensure_not_installed passes for a version that is not installed" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try ensure_not_installed(io, try testVersionsPath(arena_state.allocator(), tmp_dir), "0.17.0");
}

test "ensure_not_installed reports an installed version" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const versions_path = try testVersionsPath(arena_state.allocator(), tmp_dir);
    try tmp_dir.dir.createDirPath(io, "versions/0.17.0");

    try std.testing.expectError(error.VersionAlreadyInstalled, ensure_not_installed(io, versions_path, "0.17.0"));
}

test "link_version points bin/zig at the installed version" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const versions_path = try testVersionsPath(arena, tmp_dir);
    try tmp_dir.dir.createDirPath(io, "bin");
    const bin_path = try tmp_dir.dir.realPathFileAlloc(io, "bin", arena);
    try tmp_dir.dir.createDirPath(io, "versions/0.17.0");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "versions/0.17.0/zig", .data = "zig 0.17.0" });

    try link_version(arena, io, bin_path, versions_path, "0.17.0");

    var link_target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_target_len = try tmp_dir.dir.readLink(io, "bin/zig", &link_target_buffer);
    try std.testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ versions_path, "0.17.0", "zig" }),
        link_target_buffer[0..link_target_len],
    );
    try std.testing.expectEqualStrings("zig 0.17.0", try tmp_dir.dir.readFileAlloc(io, "bin/zig", arena, .unlimited));
}

test "link_version replaces the previously active version" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const versions_path = try testVersionsPath(arena, tmp_dir);
    try tmp_dir.dir.createDirPath(io, "bin");
    const bin_path = try tmp_dir.dir.realPathFileAlloc(io, "bin", arena);
    for ([_][]const u8{ "0.16.0", "0.17.0" }) |version_name| {
        try tmp_dir.dir.createDirPath(io, try std.fs.path.join(arena, &.{ "versions", version_name }));
        try tmp_dir.dir.writeFile(io, .{
            .sub_path = try std.fs.path.join(arena, &.{ "versions", version_name, "zig" }),
            .data = try std.fmt.allocPrint(arena, "zig {s}", .{version_name}),
        });
    }

    try link_version(arena, io, bin_path, versions_path, "0.16.0");
    try link_version(arena, io, bin_path, versions_path, "0.17.0");

    try std.testing.expectEqualStrings("zig 0.17.0", try tmp_dir.dir.readFileAlloc(io, "bin/zig", arena, .unlimited));
}

test "link_version refuses a version that is not installed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const versions_path = try testVersionsPath(arena, tmp_dir);
    try tmp_dir.dir.createDirPath(io, "bin");
    const bin_path = try tmp_dir.dir.realPathFileAlloc(io, "bin", arena);

    try std.testing.expectError(error.VersionNotInstalled, link_version(arena, io, bin_path, versions_path, "0.17.0"));
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.access(io, "bin/zig", .{}));
}

fn testUnreachableInstallCtx(arena: std.mem.Allocator, tmp_dir: std.testing.TmpDir) !InstallCtx {
    var ctx = try testInstallCtx(arena, try testVersionsPath(arena, tmp_dir), "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz");
    ctx.release.targets.getPtr("test-target").?.size = "53985220";
    ctx.mirror = "http://127.0.0.1:1/unreachable";
    return ctx;
}

test "fetch_from_mirrors returns the single mirror's own error" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ctx = try testUnreachableInstallCtx(arena, tmp_dir);
    var progress: Progress = .{};

    try std.testing.expectError(error.ConnectionRefused, fetch_from_mirrors(arena, std.testing.io, ctx, &.{"http://127.0.0.1:1/a"}, &progress));
}

test "fetch_from_mirrors fails when every mirror is unreachable" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ctx = try testUnreachableInstallCtx(arena, tmp_dir);
    var progress: Progress = .{};

    try std.testing.expectError(error.AllMirrorsFailed, fetch_from_mirrors(
        arena,
        std.testing.io,
        ctx,
        &.{ "http://127.0.0.1:1/a", "http://127.0.0.1:1/b" },
        &progress,
    ));
    try std.testing.expectEqual(@as(usize, 1), progress.mirror_index.load(.monotonic));
}

test "fetch_release records the tarball size from the index as the total" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ctx = try testUnreachableInstallCtx(arena, tmp_dir);
    var progress: Progress = .{};

    _ = fetch_release(arena, std.testing.io, ctx, &progress) catch {};

    try std.testing.expectEqual(@as(u64, 53985220), progress.total_bytes.load(.monotonic));
}

test "install_release reports the extracting stage" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ctx = try testInstallCtx(arena, try testVersionsPath(arena, tmp_dir), "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz");
    var progress: Progress = .{};

    try install_release(arena, std.testing.io, ctx, test_tar_xz, &progress);

    try std.testing.expectEqual(Progress.Stage.extracting, progress.stage.load(.monotonic));
}

test "a counting response writer adds every byte to received_bytes" {
    var progress: Progress = .{};
    var response_body: ProgressWriter = .init(std.testing.allocator, &progress);
    defer response_body.deinit();

    try response_body.writer().writeAll("0123456789");
    try response_body.writer().flush();

    try std.testing.expectEqual(@as(u64, 10), progress.received_bytes.load(.monotonic));
    try std.testing.expectEqualStrings("0123456789", response_body.written());
}
