const std = @import("std");
const Io = std.Io;

pub const cli = @import("cli.zig");
pub const index = @import("index.zig");
pub const install = @import("install.zig");
pub const list = @import("list.zig");
pub const tui = @import("tui.zig");
pub const dirs = @import("dirs.zig");
pub const gc = @import("gc.zig");
pub const version = @import("version.zig");
pub const whereis = @import("whereis.zig");

pub const mirrors = [_][]const u8{
    "https://pkg.hexops.org/zig",
    "https://zigmirror.hryx.net/zig",
    "https://zig.linus.dev/zig",
    "https://zig.squirl.dev",
    "https://zig.mirror.mschae23.de/zig",
    "https://ziglang.freetls.fastly.net",
    "https://zig.tilok.dev",
    "https://zig-mirror.tsimnet.eu/zig",
    "https://zig.karearl.com/zig",
    "https://pkg.earth/zig",
    "https://fs.liujiacai.net/zigbuilds",
    "https://zigmirror.com",
    "https://zig.chainsafe.dev",
    "https://zig.savalione.com",
    "https://zig.bcr.ist",
    "https://zig.vortan.dev/zig",
    "https://pkg.alexrp.com/zig",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var parse_diagnostics: cli.Diagnostics = .{};
    const command = cli.parseArgs(args, &parse_diagnostics) catch |parse_error| switch (parse_error) {
        error.UnknownCommand => std.process.fatal(
            "unknown command '{s}'; run `zigup help` to see the commands",
            .{parse_diagnostics.argument},
        ),
        error.UnknownFlag => std.process.fatal(
            "unknown flag '{s}' for `zigup {s}`",
            .{ parse_diagnostics.argument, parse_diagnostics.command },
        ),
        error.MissingFlagValue => std.process.fatal(
            "'{s}' needs a URL after it",
            .{parse_diagnostics.argument},
        ),
        error.UnexpectedArgument => std.process.fatal(
            "unexpected argument '{s}' for `zigup {s}`",
            .{ parse_diagnostics.argument, parse_diagnostics.command },
        ),
        error.MissingVersion => std.process.fatal(
            "`zigup {s}` needs a version, such as `zigup {s} 0.17.0`",
            .{ parse_diagnostics.command, parse_diagnostics.command },
        ),
    };
    switch (command) {
        .list => |list_options| try list.main(arena, io, init.environ_map, list_options),
        .install => |install_options| try install.main(arena, io, init.environ_map, install_options, &mirrors),
        .gc => try gc.main(arena, io, init.environ_map),
        .tui => try tui.main(arena, io, init.environ_map, &mirrors),
        .version => try version.main(io),
        .whereis => try whereis.main(arena, io, init.environ_map),
        .help => try cli.help(io),
    }
}

test {
    _ = cli;
    _ = install;
    _ = list;
    _ = dirs;
    _ = gc;
    _ = index;
    _ = whereis;
    _ = @import("tui/state.zig");
    _ = @import("tui/worker.zig");
    _ = @import("tui/render.zig");
    _ = tui;
}
