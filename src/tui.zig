//! `zigup tui`: browse Zig versions and install one from a chosen mirror.

const std = @import("std");
const zigtui = @import("zigtui");

const cli = @import("cli.zig");
const dirs = @import("dirs.zig");
const index = @import("index.zig");
const install = @import("install.zig");
const list = @import("list.zig");
const whereis = @import("whereis.zig");
const render = @import("tui/render.zig");
const state = @import("tui/state.zig");
const worker = @import("tui/worker.zig");

/// How often the screen redraws while waiting for a key, so progress moves.
const redraw_interval_ms = 100;

pub fn main(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    mirror_urls: []const []const u8,
) !void {
    // Everything that can end the program with a message happens before the
    // terminal switches to raw mode, so the message lands on a normal screen.
    const paths = try dirs.resolveOrFatal(allocator, environ_map);
    try dirs.ensureCreated(paths, io);
    const parsed_index = try index.loadParsedOrFatal(allocator, io, paths.cache, index.defaultUrl);
    defer parsed_index.deinit();

    var rows_arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer rows_arena_state.deinit();
    var tui_state: state.State = .{
        .rows = try loadRows(rows_arena_state.allocator(), io, paths, parsed_index.value),
        .mirror_count = mirror_urls.len,
    };

    var backend = try zigtui.backend.init(allocator, io);
    defer backend.deinit();
    var terminal: zigtui.Terminal = try .init(allocator, backend.interface());
    defer terminal.deinit();
    try terminal.hideCursor();

    var running_install: ?RunningInstall = null;
    // Quitting mid-install cancels it, so `q` never waits for a download.
    defer if (running_install) |*install_in_progress| install_in_progress.future.cancel(io);

    while (true) {
        if (running_install) |*install_in_progress| {
            if (install_in_progress.job.finished.load(.acquire)) {
                install_in_progress.future.await(io);
                tui_state.finishInstall(install_in_progress.version_name, install_in_progress.job.result);
                install_in_progress.deinit();
                running_install = null;
                _ = rows_arena_state.reset(.retain_capacity);
                tui_state.setRows(try loadRows(rows_arena_state.allocator(), io, paths, parsed_index.value));
            }
        }

        try terminal.draw(render.View{
            .state = &tui_state,
            .target = cli.index_target_key,
            .mirror_urls = mirror_urls,
            .progress = if (running_install) |*install_in_progress| &install_in_progress.job.progress else null,
            .installing_version = if (running_install) |install_in_progress| install_in_progress.version_name else "",
            .installing_mirror_urls = if (running_install) |install_in_progress| install_in_progress.job.mirror_urls else &.{},
        }, drawView);

        const event = try terminal.backend_impl.pollEvent(redraw_interval_ms);
        if (event == .resize) try terminal.resize(.{ .width = event.resize.width, .height = event.resize.height });
        const key = keyFromEvent(event) orelse continue;

        switch (tui_state.handleKey(key)) {
            .none => {},
            .quit => return,
            .set_default => |row_index| {
                const version_name = tui_state.rows[row_index].version_name;
                if (install.link_version(allocator, io, paths.bin, paths.versions, version_name)) {
                    tui_state.setStatus(.info, "{s} is now the default", .{version_name});
                } else |link_error| {
                    tui_state.finishInstall(version_name, .{ .set_default_failed = link_error });
                }
                // The status text above may point into the old rows, so it is
                // written before the rows are replaced and copied by setStatus.
                _ = rows_arena_state.reset(.retain_capacity);
                tui_state.setRows(try loadRows(rows_arena_state.allocator(), io, paths, parsed_index.value));
            },
            .start_install => |start| {
                running_install = try RunningInstall.start(io, paths, parsed_index.value, tui_state.rows[start.row_index], mirror_urls, start.mirror, start.set_default);
            },
        }
    }
}

/// A started install and the memory it owns. Allocated from
/// `std.heap.smp_allocator` because the install runs concurrently.
const RunningInstall = struct {
    job: *worker.Job,
    future: std.Io.Future(void),
    version_name: []const u8,

    fn start(
        io: std.Io,
        paths: dirs.Paths,
        parsed_index: index.Index,
        row: list.Row,
        mirror_urls: []const []const u8,
        mirror_choice: state.MirrorChoice,
        set_default: bool,
    ) !RunningInstall {
        const thread_allocator = std.heap.smp_allocator;
        const found_release = try install.find_release(parsed_index, row.label);
        // Copied because the rows are replaced while the install runs.
        const version_name = try thread_allocator.dupe(u8, found_release.name);
        errdefer thread_allocator.free(version_name);

        const job_mirror_urls = switch (mirror_choice) {
            .any => any_mirror: {
                // Random order spreads the load, as ziglang.org asks.
                const shuffled_mirror_urls = try thread_allocator.dupe([]const u8, mirror_urls);
                var random_seed: u64 = undefined;
                io.random(std.mem.asBytes(&random_seed));
                var prng: std.Random.DefaultPrng = .init(random_seed);
                prng.random().shuffle([]const u8, shuffled_mirror_urls);
                break :any_mirror shuffled_mirror_urls;
            },
            .specific => |mirror_index| try thread_allocator.dupe([]const u8, mirror_urls[mirror_index..][0..1]),
        };
        errdefer thread_allocator.free(job_mirror_urls);

        const job = try thread_allocator.create(worker.Job);
        errdefer thread_allocator.destroy(job);
        job.* = .{
            .allocator = thread_allocator,
            .io = io,
            .ctx = .{
                .path = paths.versions,
                .version = version_name,
                .release = found_release.release,
                .mirror = "",
            },
            .mirror_urls = job_mirror_urls,
            .bin_path = paths.bin,
            .set_default = set_default,
        };
        return .{ .job = job, .future = try worker.start(job), .version_name = version_name };
    }

    /// Only after `future` is awaited: the install no longer touches it.
    fn deinit(running_install: *RunningInstall) void {
        const thread_allocator = std.heap.smp_allocator;
        thread_allocator.free(running_install.job.mirror_urls);
        thread_allocator.destroy(running_install.job);
        thread_allocator.free(running_install.version_name);
    }
};

fn drawView(view: render.View, buffer: *zigtui.Buffer) anyerror!void {
    render.draw(buffer, view);
}

/// The rows `zigup list` would show, allocated in `arena`.
fn loadRows(arena: std.mem.Allocator, io: std.Io, paths: dirs.Paths, parsed_index: index.Index) ![]const list.Row {
    const installed_names = try list.installedVersionNames(arena, io, paths.versions);
    const active_version_path: ?[]u8 = whereis.activeVersionPath(arena, io, paths.bin) catch |active_error| switch (active_error) {
        error.NoActiveVersion => null,
        else => return active_error,
    };
    const active_name = if (active_version_path) |path| std.fs.path.basename(path) else null;
    return list.buildRows(arena, parsed_index, cli.index_target_key, installed_names, active_name);
}

/// The TUI key for a terminal event, or null for events the TUI ignores.
pub fn keyFromEvent(event: zigtui.Event) ?state.Key {
    const key_event = switch (event) {
        .key => |key_event| key_event,
        else => return null,
    };
    if (key_event.kind == .release) return null;
    return switch (key_event.code) {
        .up => .up,
        .down => .down,
        .enter => .enter,
        .esc => .escape,
        .char => |character| switch (character) {
            's' => .set_default,
            'q' => .quit,
            'c' => if (key_event.isCtrl()) .quit else null,
            else => null,
        },
        else => null,
    };
}

fn keyPress(code: zigtui.KeyCode) zigtui.Event {
    return .{ .key = .{ .code = code } };
}

test "keyFromEvent maps the keys the TUI uses" {
    try std.testing.expectEqual(state.Key.up, keyFromEvent(keyPress(.up)).?);
    try std.testing.expectEqual(state.Key.down, keyFromEvent(keyPress(.down)).?);
    try std.testing.expectEqual(state.Key.enter, keyFromEvent(keyPress(.enter)).?);
    try std.testing.expectEqual(state.Key.escape, keyFromEvent(keyPress(.esc)).?);
    try std.testing.expectEqual(state.Key.set_default, keyFromEvent(keyPress(.{ .char = 's' })).?);
    try std.testing.expectEqual(state.Key.quit, keyFromEvent(keyPress(.{ .char = 'q' })).?);
}

test "keyFromEvent treats Ctrl-C as quit" {
    const ctrl_c: zigtui.Event = .{ .key = .{ .code = .{ .char = 'c' }, .modifiers = .{ .ctrl = true } } };
    try std.testing.expectEqual(state.Key.quit, keyFromEvent(ctrl_c).?);
}

test "keyFromEvent ignores other keys, releases and non-key events" {
    try std.testing.expectEqual(null, keyFromEvent(keyPress(.{ .char = 'x' })));
    try std.testing.expectEqual(null, keyFromEvent(keyPress(.{ .char = 'o' })));
    try std.testing.expectEqual(null, keyFromEvent(keyPress(.{ .char = 'c' })));
    const released: zigtui.Event = .{ .key = .{ .code = .enter, .kind = .release } };
    try std.testing.expectEqual(null, keyFromEvent(released));
    try std.testing.expectEqual(null, keyFromEvent(.none));
}
