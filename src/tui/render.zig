//! Draws a `state.State` onto a zigtui `Buffer`. Drawing only; no input.

const std = @import("std");
const zigtui = @import("zigtui");

const install = @import("../install.zig");
const list = @import("../list.zig");
const state = @import("state.zig");

pub const View = struct {
    state: *const state.State,
    /// `cli.index_target_key`, shown in the title.
    target: []const u8,
    /// `root.mirrors`, in picker order.
    mirror_urls: []const []const u8,
    /// Non-null while an install runs.
    progress: ?*const install.Progress,
    installing_version: []const u8 = "",
    /// The mirror order the running install tries; `Progress.mirror_index` indexes it.
    installing_mirror_urls: []const []const u8 = &.{},
};

const footer = "enter install · s install + set default · q quit";
const progress_bar_width = 12;

pub fn draw(buffer: *zigtui.Buffer, view: View) void {
    // Row labels and status text are formatted per frame; drawing cannot
    // report errors, so running out of memory leaves the frame partly drawn.
    var arena_state: std.heap.ArenaAllocator = .init(buffer.allocator);
    defer arena_state.deinit();
    drawFrame(arena_state.allocator(), buffer, view) catch {};
}

fn drawFrame(arena: std.mem.Allocator, buffer: *zigtui.Buffer, view: View) !void {
    const area = buffer.getArea();
    const outer_block: zigtui.Block = .{
        .title = try std.fmt.allocPrint(arena, " zigup · {s} ", .{view.target}),
        .borders = zigtui.Borders.ALL,
        .border_symbols = zigtui.BorderSymbols.rounded(),
    };
    // zigtui's Block assumes room for its border and title.
    if (area.width < 4 or area.height < 3) return;
    outer_block.render(area, buffer);
    if (area.width > 4) {
        buffer.setStringTruncated(area.x + 2, area.y + area.height - 1, " " ++ footer ++ " ", area.width - 4, .{});
    }

    const inner = outer_block.inner(area);
    if (inner.height == 0 or inner.width == 0) return;
    const status_y = inner.y + inner.height - 1;
    try drawStatus(arena, buffer, .{ .x = inner.x, .y = status_y, .width = inner.width, .height = 1 }, view);
    if (inner.height < 2) return;
    const table_area: zigtui.Rect = .{ .x = inner.x, .y = inner.y, .width = inner.width, .height = inner.height - 1 };
    try drawVersions(arena, buffer, table_area, view);

    if (view.state.mode == .mirror_picker) try drawMirrorPicker(arena, buffer, area, view);
}

fn drawVersions(arena: std.mem.Allocator, buffer: *zigtui.Buffer, area: zigtui.Rect, view: View) !void {
    const rows = view.state.rows;
    if (rows.len == 0) {
        const message = try std.fmt.allocPrint(arena, "no Zig versions available for {s}", .{view.target});
        buffer.setStringTruncated(area.x, area.y, message, area.width, .{});
        return;
    }

    const table_rows = try arena.alloc(zigtui.widgets.Row, rows.len);
    for (rows, table_rows) |row, *table_row| {
        const marker = if (row.active) "* " else "  ";
        const label = if (std.mem.eql(u8, row.label, row.version_name))
            try std.fmt.allocPrint(arena, "{s}{s}", .{ marker, row.label })
        else
            try std.fmt.allocPrint(arena, "{s}{s} ({s})", .{ marker, row.label, row.version_name });
        // The notes URL goes last: it is the widest cell, so on a narrow
        // terminal it is the one that gets cut off.
        const cells = try arena.dupe([]const u8, &.{
            label,
            row.date orelse "",
            if (row.active) "active" else if (row.installed) "✓" else "",
            row.notes orelse "—",
        });
        table_row.* = .{ .cells = cells };
    }

    // Keep the selection on screen: scroll just far enough to show it.
    const visible_rows: usize = area.height -| 1;
    const offset = if (visible_rows == 0) view.state.selected_row else (view.state.selected_row + 1) -| visible_rows;
    const table: zigtui.Table = .{
        .columns = &.{
            .{ .header = "  VERSION" },
            .{ .header = "DATE", .width = 10 },
            .{ .header = "", .width = 6 },
            .{ .header = "NOTES" },
        },
        .rows = table_rows,
        .header_style = .{ .modifier = .{ .dim = true } },
        .selected_style = .{ .modifier = .{ .reversed = true } },
        .selected = view.state.selected_row,
        .offset = offset,
        .column_spacing = 2,
    };
    table.render(area, buffer);
}

fn drawMirrorPicker(arena: std.mem.Allocator, buffer: *zigtui.Buffer, area: zigtui.Rect, view: View) !void {
    const label = if (view.state.rows.len == 0) "" else view.state.rows[view.state.selected_row].label;
    const picker_area = zigtui.widgets.centeredRectFixed(area, 44, @intCast(@min(view.mirror_urls.len + 3, area.height)));
    const popup: zigtui.Popup = .{
        .title = try std.fmt.allocPrint(arena, " install {s} from ", .{label}),
        .show_backdrop = false,
    };
    if (picker_area.width < 4 or picker_area.height < 3) return;
    popup.render(picker_area, buffer);

    const items = try arena.alloc(zigtui.ListItem, view.mirror_urls.len + 1);
    items[0] = .{ .content = "any mirror (random, with fallback)" };
    for (view.mirror_urls, items[1..]) |mirror_url, *item| item.* = .{ .content = state.mirrorDisplayName(mirror_url) };

    const list_area = zigtui.Popup.innerArea(picker_area);
    const visible_items: usize = list_area.height;
    const mirror_list: zigtui.List = .{
        .items = items,
        .highlight_style = .{ .modifier = .{ .reversed = true } },
        .highlight_symbol = "",
        .selected = view.state.picker_selected,
        .offset = if (visible_items == 0) 0 else (view.state.picker_selected + 1) -| visible_items,
    };
    mirror_list.render(list_area, buffer);
}

fn drawStatus(arena: std.mem.Allocator, buffer: *zigtui.Buffer, area: zigtui.Rect, view: View) !void {
    if (view.progress) |progress| {
        const text = switch (progress.stage.load(.monotonic)) {
            .downloading => try downloadingText(arena, progress, view),
            .verifying => try std.fmt.allocPrint(arena, "verifying {s}", .{view.installing_version}),
            .extracting => try std.fmt.allocPrint(arena, "extracting {s}", .{view.installing_version}),
        };
        buffer.setStringTruncated(area.x, area.y, text, area.width, .{});
        return;
    }
    switch (view.state.status) {
        .none => {},
        .info => |text| buffer.setStringTruncated(area.x, area.y, text, area.width, .{}),
        .failure => |text| buffer.setStringTruncated(area.x, area.y, text, area.width, .{ .fg = .red }),
    }
}

fn downloadingText(arena: std.mem.Allocator, progress: *const install.Progress, view: View) ![]const u8 {
    const mirror_index = progress.mirror_index.load(.monotonic);
    const mirror_urls = view.installing_mirror_urls;
    const mirror_name = if (mirror_index < mirror_urls.len) state.mirrorDisplayName(mirror_urls[mirror_index]) else "";
    const received_bytes = progress.received_bytes.load(.monotonic);
    const total_bytes = progress.total_bytes.load(.monotonic);
    const percent: u64 = if (total_bytes == 0) 0 else @min(100, received_bytes * 100 / total_bytes);
    const filled_cells: usize = @intCast(percent * progress_bar_width / 100);

    var progress_bar: std.ArrayList(u8) = .empty;
    for (0..progress_bar_width) |cell_index| try progress_bar.appendSlice(arena, if (cell_index < filled_cells) "▓" else "░");
    return std.fmt.allocPrint(arena, "downloading {s} from {s}  {s}  {d}%", .{ view.installing_version, mirror_name, progress_bar.items, percent });
}

const test_rows = [_]list.Row{
    .{ .label = "master", .version_name = "0.18.0-dev.349+d924f83bf", .date = "2026-10-17", .installed = false, .active = false },
    .{ .label = "0.17.0", .version_name = "0.17.0", .date = "2026-10-01", .installed = true, .active = true, .notes = "https://ziglang.org/download/0.17.0/release-notes.html" },
    .{ .label = "0.16.0", .version_name = "0.16.0", .date = "2026-04-13", .installed = true, .active = false, .notes = "https://ziglang.org/download/0.16.0/release-notes.html" },
    .{ .label = "0.15.2", .version_name = "0.15.2", .date = "2025-10-11", .installed = false, .active = false, .notes = "https://ziglang.org/download/0.15.2/release-notes.html" },
};
const test_mirror_urls = [_][]const u8{ "https://pkg.earth/zig", "https://zigmirror.com", "https://zig.linus.dev/zig" };

/// The text of row `y`, with each cell's character encoded as UTF-8.
fn rowText(arena: std.mem.Allocator, buffer: *zigtui.Buffer, y: u16) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var x: u16 = 0;
    while (x < buffer.width) : (x += 1) {
        const cell = buffer.get(x, y).?;
        if (cell.isContinuation()) continue;
        var encoded: [4]u8 = undefined;
        const encoded_len = try std.unicode.utf8Encode(cell.char, &encoded);
        try text.appendSlice(arena, encoded[0..encoded_len]);
    }
    return text.items;
}

/// The row whose text contains every one of `needles`, or a test failure.
fn expectRowContaining(arena: std.mem.Allocator, buffer: *zigtui.Buffer, needles: []const []const u8) !void {
    var y: u16 = 0;
    next_row: while (y < buffer.height) : (y += 1) {
        const text = try rowText(arena, buffer, y);
        for (needles) |needle| {
            if (std.mem.find(u8, text, needle) == null) continue :next_row;
        }
        return;
    }
    std.debug.print("no row contains all of {any}; screen:\n", .{needles});
    y = 0;
    while (y < buffer.height) : (y += 1) std.debug.print("|{s}|\n", .{try rowText(arena, buffer, y)});
    return error.TestExpectedRow;
}

test "render shows the title, versions, dates and markers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Wide enough for a whole release-notes URL.
    var buffer: zigtui.Buffer = try .init(std.testing.allocator, 120, 12);
    defer buffer.deinit();
    const view_state: state.State = .{ .rows = &test_rows, .mirror_count = test_mirror_urls.len };

    draw(&buffer, .{ .state = &view_state, .target = "aarch64-macos", .mirror_urls = &test_mirror_urls, .progress = null });

    try expectRowContaining(arena, &buffer, &.{"zigup · aarch64-macos"});
    try expectRowContaining(arena, &buffer, &.{ "0.17.0", "2026-10-01", "active" });
    try expectRowContaining(arena, &buffer, &.{ "master (0.18.0-dev.349+d924f83bf)", "—" });
    try expectRowContaining(arena, &buffer, &.{ "0.15.2", "https://ziglang.org/download/0.15.2/release-notes.html" });
    try expectRowContaining(arena, &buffer, &.{"enter install · s install + set default · q quit"});
    var y: u16 = 0;
    while (y < buffer.height) : (y += 1) {
        try std.testing.expect(std.mem.find(u8, try rowText(arena, &buffer, y), "o notes") == null);
    }
}

test "render cuts off the notes url, not the markers, on a narrow terminal" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: zigtui.Buffer = try .init(std.testing.allocator, 80, 12);
    defer buffer.deinit();
    const view_state: state.State = .{ .rows = &test_rows, .mirror_count = test_mirror_urls.len };

    draw(&buffer, .{ .state = &view_state, .target = "aarch64-macos", .mirror_urls = &test_mirror_urls, .progress = null });

    try expectRowContaining(arena, &buffer, &.{ "0.17.0", "active", "https://ziglang.org" });
    try expectRowContaining(arena, &buffer, &.{ "0.16.0", "✓" });
}

test "render shows the mirror picker over the list" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: zigtui.Buffer = try .init(std.testing.allocator, 100, 12);
    defer buffer.deinit();
    const view_state: state.State = .{ .rows = &test_rows, .mirror_count = test_mirror_urls.len, .mode = .mirror_picker };

    draw(&buffer, .{ .state = &view_state, .target = "aarch64-macos", .mirror_urls = &test_mirror_urls, .progress = null });

    try expectRowContaining(arena, &buffer, &.{"any mirror (random, with fallback)"});
    try expectRowContaining(arena, &buffer, &.{"pkg.earth/zig"});
}

test "render shows download progress in the status line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: zigtui.Buffer = try .init(std.testing.allocator, 100, 12);
    defer buffer.deinit();
    const view_state: state.State = .{ .rows = &test_rows, .mirror_count = 1, .install_running = true };
    var progress: install.Progress = .{};
    progress.received_bytes.store(50, .monotonic);
    progress.total_bytes.store(100, .monotonic);
    progress.mirror_index.store(1, .monotonic);

    draw(&buffer, .{
        .state = &view_state,
        .target = "aarch64-macos",
        .mirror_urls = &test_mirror_urls,
        .progress = &progress,
        .installing_version = "0.15.2",
        // A shuffled order, unlike the picker's.
        .installing_mirror_urls = &.{ "https://zigmirror.com", "https://pkg.earth/zig" },
    });

    try expectRowContaining(arena, &buffer, &.{ "downloading 0.15.2 from pkg.earth/zig", "50%" });
}

test "render shows the status message" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: zigtui.Buffer = try .init(std.testing.allocator, 100, 12);
    defer buffer.deinit();
    var view_state: state.State = .{ .rows = &test_rows, .mirror_count = 1 };
    view_state.finishInstall("0.15.2", .all_mirrors_failed);

    draw(&buffer, .{ .state = &view_state, .target = "aarch64-macos", .mirror_urls = &test_mirror_urls, .progress = null });

    try expectRowContaining(arena, &buffer, &.{"no mirror could provide 0.15.2"});
}

test "render keeps the selected row visible" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Room for the header and two rows only.
    var buffer: zigtui.Buffer = try .init(std.testing.allocator, 100, 6);
    defer buffer.deinit();
    const view_state: state.State = .{ .rows = &test_rows, .mirror_count = 1, .selected_row = 3 };

    draw(&buffer, .{ .state = &view_state, .target = "aarch64-macos", .mirror_urls = &test_mirror_urls, .progress = null });

    try expectRowContaining(arena, &buffer, &.{ "0.15.2", "2025-10-11" });
}

test "render survives a tiny terminal" {
    var progress: install.Progress = .{};
    for ([_][2]u16{ .{ 20, 5 }, .{ 1, 1 }, .{ 3, 2 } }) |size| {
        var buffer: zigtui.Buffer = try .init(std.testing.allocator, size[0], size[1]);
        defer buffer.deinit();
        for ([_]state.Mode{ .list, .mirror_picker }) |mode| {
            for ([_]?*const install.Progress{ null, &progress }) |maybe_progress| {
                const view_state: state.State = .{ .rows = &test_rows, .mirror_count = test_mirror_urls.len, .mode = mode, .selected_row = 3 };
                draw(&buffer, .{ .state = &view_state, .target = "aarch64-macos", .mirror_urls = &test_mirror_urls, .progress = maybe_progress, .installing_version = "0.15.2" });
            }
        }
    }
}

test "render says when no versions are available" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: zigtui.Buffer = try .init(std.testing.allocator, 100, 12);
    defer buffer.deinit();
    const view_state: state.State = .{ .rows = &.{}, .mirror_count = 3 };

    draw(&buffer, .{ .state = &view_state, .target = "aarch64-macos", .mirror_urls = &test_mirror_urls, .progress = null });

    try expectRowContaining(arena, &buffer, &.{"no Zig versions available for aarch64-macos"});
}
