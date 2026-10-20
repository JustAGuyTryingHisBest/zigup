//! Runs one install on a background thread so the TUI can keep redrawing.
//! The UI thread reads `progress` while it runs and `result` once `finished`.

const std = @import("std");

const install = @import("../install.zig");
const state = @import("state.zig");

pub const Job = struct {
    /// Must be thread-safe; the TUI passes `std.heap.smp_allocator`.
    allocator: std.mem.Allocator,
    io: std.Io,
    /// `.path` is the versions directory; `.mirror` is unused.
    ctx: install.InstallCtx,
    /// Already ordered: shuffled for "any mirror", one element for a chosen mirror.
    mirror_urls: []const []const u8,
    bin_path: []const u8,
    set_default: bool,
    progress: install.Progress = .{},
    finished: std.atomic.Value(bool) = .init(false),
    /// Valid once `finished.load(.acquire)` is true.
    result: state.InstallResult = undefined,

    /// The whole install. Never returns an error: every outcome is a `result`.
    pub fn run(job: *Job) void {
        job.result = job.installRelease();
        job.finished.store(true, .release);
    }

    fn installRelease(job: *Job) state.InstallResult {
        const fetched_release = install.fetch_from_mirrors(job.allocator, job.io, job.ctx, job.mirror_urls, &job.progress) catch |fetch_error| switch (fetch_error) {
            error.AllMirrorsFailed => return .all_mirrors_failed,
            // With one mirror, fetch_from_mirrors returns that mirror's own error.
            else => return .{ .mirror_failed = .{ .mirror_url = job.mirror_urls[0], .err = fetch_error } },
        };
        defer job.allocator.free(fetched_release.tarball);

        var mirror_ctx = job.ctx;
        mirror_ctx.mirror = fetched_release.mirror_url;
        install.install_release(job.allocator, job.io, mirror_ctx, fetched_release.tarball, &job.progress) catch |install_error| {
            return .{ .mirror_failed = .{ .mirror_url = fetched_release.mirror_url, .err = install_error } };
        };
        if (job.set_default) {
            install.link_version(job.allocator, job.io, job.bin_path, job.ctx.path, job.ctx.version) catch |link_error| {
                return .{ .set_default_failed = link_error };
            };
        }
        return .{ .installed = .{ .set_default = job.set_default } };
    }
};

/// Run `job` concurrently through `job.io`. A bare `std.Thread` made the
/// download crawl (about 25 KB/s against 11 MB/s), so the work goes through
/// `std.Io` like everything else that does I/O.
pub fn start(job: *Job) !std.Io.Future(void) {
    return job.io.concurrent(Job.run, .{job});
}

fn testJob(arena: std.mem.Allocator, tmp_dir: std.testing.TmpDir, mirror_urls: []const []const u8) !Job {
    const io = std.testing.io;
    try tmp_dir.dir.createDirPath(io, "versions");
    try tmp_dir.dir.createDirPath(io, "bin");
    var release: @import("../index.zig").Release = .{};
    try release.targets.put(arena, "test-target", .{
        .tarball = "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz",
        .shasum = "",
        .size = "53985220",
    });
    return .{
        .allocator = std.testing.allocator,
        .io = io,
        .ctx = .{
            .path = try tmp_dir.dir.realPathFileAlloc(io, "versions", arena),
            .version = "0.17.0",
            .release = release,
            .mirror = "",
            .target = "test-target",
        },
        .mirror_urls = mirror_urls,
        .bin_path = try tmp_dir.dir.realPathFileAlloc(io, "bin", arena),
        .set_default = true,
    };
}

test "run reports all_mirrors_failed for unreachable mirrors with fallback" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var job = try testJob(arena_state.allocator(), tmp_dir, &.{ "http://127.0.0.1:1/a", "http://127.0.0.1:1/b" });

    job.run();

    try std.testing.expect(job.finished.load(.acquire));
    try std.testing.expectEqual(state.InstallResult.all_mirrors_failed, std.meta.activeTag(job.result));
}

test "run reports the failing mirror when only one was chosen" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var job = try testJob(arena_state.allocator(), tmp_dir, &.{"http://127.0.0.1:1/a"});

    job.run();

    try std.testing.expect(job.finished.load(.acquire));
    try std.testing.expectEqualStrings("http://127.0.0.1:1/a", job.result.mirror_failed.mirror_url);
    try std.testing.expectEqual(error.ConnectionRefused, job.result.mirror_failed.err);
}

test "start runs the job concurrently" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var job = try testJob(arena_state.allocator(), tmp_dir, &.{"http://127.0.0.1:1/a"});

    var future = try start(&job);
    future.await(std.testing.io);

    try std.testing.expect(job.finished.load(.acquire));
    try std.testing.expectEqual(state.InstallResult.mirror_failed, std.meta.activeTag(job.result));
}
