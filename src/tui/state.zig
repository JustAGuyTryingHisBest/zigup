//! What the TUI shows and how keys change it. No terminal or I/O here, so
//! every transition is unit-tested.

const std = @import("std");

const list = @import("../list.zig");

pub const Key = enum { up, down, enter, escape, set_default, quit };

/// Which mirror to download from; `specific` indexes the mirror list.
pub const MirrorChoice = union(enum) { any, specific: usize };

pub const Action = union(enum) {
    none,
    quit,
    start_install: struct { row_index: usize, mirror: MirrorChoice, set_default: bool },
    /// Row index of an installed version to make the default.
    set_default: usize,
};

pub const Mode = enum { list, mirror_picker };

/// Text points into `State.status_buffer`, so a `State` must not be copied
/// after a status is set.
pub const Status = union(enum) { none, info: []const u8, failure: []const u8 };

pub const InstallResult = union(enum) {
    installed: struct { set_default: bool },
    all_mirrors_failed,
    mirror_failed: struct { mirror_url: []const u8, err: anyerror },
    set_default_failed: anyerror,
};

pub const State = struct {
    rows: []const list.Row,
    mirror_count: usize,
    selected_row: usize = 0,
    mode: Mode = .list,
    /// 0 is "any mirror"; n is mirror n - 1.
    picker_selected: usize = 0,
    picker_sets_default: bool = false,
    install_running: bool = false,
    status: Status = .none,
    status_buffer: [256]u8 = undefined,

    pub fn handleKey(state: *State, key: Key) Action {
        if (key == .quit) return .quit;
        return switch (state.mode) {
            .list => state.handleListKey(key),
            .mirror_picker => state.handlePickerKey(key),
        };
    }

    fn handleListKey(state: *State, key: Key) Action {
        if (state.rows.len == 0) return .none;
        const row = state.rows[state.selected_row];
        switch (key) {
            .up => state.selected_row -|= 1,
            .down => state.selected_row = @min(state.selected_row + 1, state.rows.len - 1),
            // One install at a time, so the default never changes underneath it.
            .enter, .set_default => {
                if (state.install_running) return .none;
                const sets_default = key == .set_default;
                if (row.installed) {
                    return if (sets_default) .{ .set_default = state.selected_row } else .none;
                }
                state.mode = .mirror_picker;
                state.picker_selected = 0;
                state.picker_sets_default = sets_default;
            },
            .escape, .quit => {},
        }
        return .none;
    }

    fn handlePickerKey(state: *State, key: Key) Action {
        switch (key) {
            .up => state.picker_selected -|= 1,
            .down => state.picker_selected = @min(state.picker_selected + 1, state.mirror_count),
            .escape => state.mode = .list,
            .enter => {
                state.mode = .list;
                state.install_running = true;
                return .{ .start_install = .{
                    .row_index = state.selected_row,
                    .mirror = if (state.picker_selected == 0) .any else .{ .specific = state.picker_selected - 1 },
                    .set_default = state.picker_sets_default,
                } };
            },
            .set_default, .quit => {},
        }
        return .none;
    }

    pub fn finishInstall(state: *State, version_name: []const u8, result: InstallResult) void {
        state.install_running = false;
        switch (result) {
            .installed => |installed| if (installed.set_default)
                state.setStatus(.info, "installed {s} and set as default", .{version_name})
            else
                state.setStatus(.info, "installed {s}", .{version_name}),
            .all_mirrors_failed => state.setStatus(.failure, "no mirror could provide {s}", .{version_name}),
            .mirror_failed => |mirror_failed| if (mirror_failed.err == error.SignatureVerificationFailed)
                state.setStatus(.failure, "signature check failed for {s}", .{mirrorDisplayName(mirror_failed.mirror_url)})
            else
                state.setStatus(.failure, "{s} failed: {t}", .{ mirrorDisplayName(mirror_failed.mirror_url), mirror_failed.err }),
            .set_default_failed => |set_default_error| state.setStatus(.failure, "could not set {s} as default: {t}", .{ version_name, set_default_error }),
        }
    }

    /// Show a fresh list, such as after an install, keeping the highlight on a row.
    pub fn setRows(state: *State, rows: []const list.Row) void {
        state.rows = rows;
        state.selected_row = @min(state.selected_row, rows.len -| 1);
    }

    /// Format into `status_buffer`; text that does not fit is cut off.
    pub fn setStatus(state: *State, kind: std.meta.Tag(Status), comptime format: []const u8, arguments: anytype) void {
        const text = std.fmt.bufPrint(&state.status_buffer, format, arguments) catch &state.status_buffer;
        state.status = switch (kind) {
            .none => .none,
            .info => .{ .info = text },
            .failure => .{ .failure = text },
        };
    }
};

/// A mirror URL without its scheme, such as "pkg.earth/zig".
pub fn mirrorDisplayName(url: []const u8) []const u8 {
    const scheme_end = std.mem.find(u8, url, "://") orelse return url;
    return url[scheme_end + "://".len ..];
}

const test_rows = [_]list.Row{
    .{ .label = "master", .version_name = "0.18.0-dev.349+d924f83bf", .date = "2026-10-17", .installed = false, .active = false },
    .{ .label = "0.17.0", .version_name = "0.17.0", .date = "2026-10-01", .installed = true, .active = true, .notes = "https://ziglang.org/download/0.17.0/release-notes.html" },
    .{ .label = "0.16.0", .version_name = "0.16.0", .date = "2026-04-13", .installed = true, .active = false, .notes = "https://ziglang.org/download/0.16.0/release-notes.html" },
    .{ .label = "0.15.2", .version_name = "0.15.2", .date = "2025-10-11", .installed = false, .active = false, .notes = "https://ziglang.org/download/0.15.2/release-notes.html" },
};

fn testState() State {
    return .{ .rows = &test_rows, .mirror_count = 3 };
}

fn pressKeys(state: *State, keys: []const Key) Action {
    var action: Action = .none;
    for (keys) |key| action = state.handleKey(key);
    return action;
}

fn expectNone(action: Action) !void {
    try std.testing.expectEqual(Action.none, std.meta.activeTag(action));
}

test "down and up move the highlight and stop at the ends" {
    var state = testState();
    for ([_]usize{ 1, 2, 3, 3 }) |expected_row| {
        try expectNone(state.handleKey(.down));
        try std.testing.expectEqual(expected_row, state.selected_row);
    }
    for ([_]usize{ 2, 1, 0, 0 }) |expected_row| {
        try expectNone(state.handleKey(.up));
        try std.testing.expectEqual(expected_row, state.selected_row);
    }
}

test "enter on a version that is not installed opens the mirror picker" {
    var state = testState();
    try expectNone(state.handleKey(.enter));
    try std.testing.expectEqual(Mode.mirror_picker, state.mode);
    try std.testing.expectEqual(@as(usize, 0), state.picker_selected);
    try std.testing.expect(!state.picker_sets_default);
}

test "enter on an installed version does nothing" {
    var state = testState();
    try expectNone(pressKeys(&state, &.{ .down, .enter }));
    try std.testing.expectEqual(Mode.list, state.mode);
}

test "s on a version that is not installed opens the picker to set default" {
    var state = testState();
    try expectNone(pressKeys(&state, &.{ .down, .down, .down, .set_default }));
    try std.testing.expectEqual(Mode.mirror_picker, state.mode);
    try std.testing.expect(state.picker_sets_default);
}

test "s on an installed version sets it as default" {
    var state = testState();
    const action = pressKeys(&state, &.{ .down, .down, .set_default });
    try std.testing.expectEqual(@as(usize, 2), action.set_default);
    try std.testing.expectEqual(Mode.list, state.mode);
}

test "s on installed master sets default" {
    var rows = test_rows;
    rows[0].installed = true;
    var state: State = .{ .rows = &rows, .mirror_count = 3 };
    const action = state.handleKey(.set_default);
    try std.testing.expectEqual(@as(usize, 0), action.set_default);
}

test "enter in the picker starts the install with the chosen mirror" {
    var state = testState();
    const action = pressKeys(&state, &.{ .down, .down, .down, .enter, .down, .down, .enter });
    try std.testing.expectEqual(@as(usize, 3), action.start_install.row_index);
    try std.testing.expectEqual(@as(usize, 1), action.start_install.mirror.specific);
    try std.testing.expect(!action.start_install.set_default);
    try std.testing.expectEqual(Mode.list, state.mode);
    try std.testing.expect(state.install_running);
}

test "enter on any mirror starts the install with fallback" {
    var state = testState();
    const action = pressKeys(&state, &.{ .set_default, .enter });
    try std.testing.expectEqual(@as(usize, 0), action.start_install.row_index);
    try std.testing.expectEqual(MirrorChoice.any, std.meta.activeTag(action.start_install.mirror));
    try std.testing.expect(action.start_install.set_default);
}

test "picker selection stops at the first and last mirror" {
    var state = testState();
    _ = pressKeys(&state, &.{ .enter, .up });
    try std.testing.expectEqual(@as(usize, 0), state.picker_selected);
    _ = pressKeys(&state, &.{ .down, .down, .down, .down, .down });
    try std.testing.expectEqual(@as(usize, 3), state.picker_selected);
}

test "escape closes the picker without installing" {
    var state = testState();
    try expectNone(pressKeys(&state, &.{ .enter, .down, .escape }));
    try std.testing.expectEqual(Mode.list, state.mode);
    try std.testing.expect(!state.install_running);
}

test "enter and s are ignored while an install is running" {
    var state = testState();
    state.install_running = true;
    for (0..test_rows.len) |row_index| {
        state.selected_row = row_index;
        try expectNone(state.handleKey(.enter));
        try expectNone(state.handleKey(.set_default));
        try std.testing.expectEqual(Mode.list, state.mode);
    }
}

test "q quits from the list and the picker" {
    var state = testState();
    try std.testing.expectEqual(Action.quit, std.meta.activeTag(state.handleKey(.quit)));
    _ = state.handleKey(.enter);
    try std.testing.expectEqual(Action.quit, std.meta.activeTag(state.handleKey(.quit)));
}

test "keys do nothing when there are no rows" {
    var state: State = .{ .rows = &.{}, .mirror_count = 3 };
    for ([_]Key{ .up, .down, .enter, .escape, .set_default }) |key| {
        try expectNone(state.handleKey(key));
        try std.testing.expectEqual(Mode.list, state.mode);
    }
    try std.testing.expectEqual(Action.quit, std.meta.activeTag(state.handleKey(.quit)));
}

test "finishInstall reports each outcome" {
    const Case = struct { result: InstallResult, is_failure: bool, text: []const u8 };
    const cases = [_]Case{
        .{ .result = .{ .installed = .{ .set_default = false } }, .is_failure = false, .text = "installed 0.15.2" },
        .{ .result = .{ .installed = .{ .set_default = true } }, .is_failure = false, .text = "installed 0.15.2 and set as default" },
        .{ .result = .all_mirrors_failed, .is_failure = true, .text = "no mirror could provide 0.15.2" },
        .{ .result = .{ .mirror_failed = .{ .mirror_url = "https://pkg.earth/zig", .err = error.SignatureVerificationFailed } }, .is_failure = true, .text = "signature check failed for pkg.earth/zig" },
        .{ .result = .{ .mirror_failed = .{ .mirror_url = "https://pkg.earth/zig", .err = error.ConnectionRefused } }, .is_failure = true, .text = "pkg.earth/zig failed: ConnectionRefused" },
        .{ .result = .{ .set_default_failed = error.AccessDenied }, .is_failure = true, .text = "could not set 0.15.2 as default: AccessDenied" },
    };
    for (cases) |case| {
        var state = testState();
        state.install_running = true;
        state.finishInstall("0.15.2", case.result);
        try std.testing.expect(!state.install_running);
        const status_text = if (case.is_failure) state.status.failure else state.status.info;
        try std.testing.expectEqualStrings(case.text, status_text);
    }
}

test "setRows keeps the highlight on an existing row" {
    var state = testState();
    state.selected_row = 3;
    state.setRows(test_rows[0..2]);
    try std.testing.expectEqual(@as(usize, 2), state.rows.len);
    try std.testing.expectEqual(@as(usize, 1), state.selected_row);

    state.setRows(&.{});
    try std.testing.expectEqual(@as(usize, 0), state.selected_row);
}

test "setStatus shows an info message" {
    var state = testState();
    state.setStatus(.info, "{s} is now the default", .{"0.16.0"});
    try std.testing.expectEqualStrings("0.16.0 is now the default", state.status.info);
}

test "mirrorDisplayName drops the scheme" {
    try std.testing.expectEqualStrings("pkg.earth/zig", mirrorDisplayName("https://pkg.earth/zig"));
    try std.testing.expectEqualStrings("127.0.0.1:1/a", mirrorDisplayName("http://127.0.0.1:1/a"));
}

test "a status longer than the buffer is truncated" {
    var state = testState();
    const long_name: [300]u8 = @splat('v');
    state.finishInstall(&long_name, .all_mirrors_failed);
    try std.testing.expectEqual(@as(usize, 256), state.status.failure.len);
}
