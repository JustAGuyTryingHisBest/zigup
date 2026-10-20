const builtin = @import("builtin");
const std = @import("std");

const index = @import("index.zig");

pub const body = "\n\nUsage: zigup <command>\n\nCommands:\n";
pub const description = "Manage Zig installations for " ++ index_target_key;
pub const index_target_key =
    @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
pub const usage = usage: {
    var usage_text: []const u8 = description ++ body;
    for (@typeInfo(Command).@"union".field_names) |command_name| {
        const synopsis = if (@hasField(@TypeOf(Command.arguments), command_name))
            command_name ++ " " ++ @field(Command.arguments, command_name)
        else
            command_name;
        usage_text = usage_text ++ std.fmt.comptimePrint("  {s:<36}{s}\n", .{
            synopsis,
            @field(Command.descriptions, command_name),
        });
    }
    break :usage usage_text;
};

pub const Command = union(enum) {
    tui,
    list: List,
    install: Install,
    whereis,
    gc,
    version,
    help,

    pub const descriptions = .{
        .tui = "Launch the interactive terminal UI",
        .list = "List available Zig versions",
        .install = "Install a Zig version",
        .whereis = "Print the install path of the active Zig version",
        .gc = "Remove installed Zig versions that are no longer referenced",
        .version = "Print the version for the zigup cli",
        .help = "Print this help message",
    };

    /// Arguments shown after the command name in the help message.
    pub const arguments = .{
        .list = "[-u|--url <url>]",
        .install = "<version> [-u|--url <url>]",
    };
};

pub const List = struct {
    /// Index to read; `-u`/`--url` overrides the ziglang.org one.
    url: []const u8 = index.defaultUrl,
};

pub const Install = struct {
    version: []const u8,
    /// Index to read; `-u`/`--url` overrides the ziglang.org one.
    url: []const u8 = index.defaultUrl,
};

/// Which argument a `parseArgs` error is about, for error messages.
pub const Diagnostics = struct {
    command: []const u8 = "",
    argument: []const u8 = "",
};

pub fn parseArgs(args: []const []const u8, diagnostics: ?*Diagnostics) !Command {
    var ignored_diagnostics: Diagnostics = .{};
    const parse_diagnostics = diagnostics orelse &ignored_diagnostics;
    if (args.len < 2) return .help;
    const command_name = args[1];
    parse_diagnostics.command = command_name;
    if (std.mem.eql(u8, command_name, "tui")) return .tui;
    if (std.mem.eql(u8, command_name, "list")) return .{ .list = try parseList(args[2..], parse_diagnostics) };
    if (std.mem.eql(u8, command_name, "install")) return .{ .install = try parseInstall(args[2..], parse_diagnostics) };
    if (std.mem.eql(u8, command_name, "whereis")) return .whereis;
    if (std.mem.eql(u8, command_name, "gc")) return .gc;
    if (std.mem.eql(u8, command_name, "version")) return .version;
    if (std.mem.eql(u8, command_name, "--version")) return .version;
    if (std.mem.eql(u8, command_name, "-v")) return .version;
    if (std.mem.eql(u8, command_name, "help")) return .help;
    if (std.mem.eql(u8, command_name, "--help")) return .help;
    if (std.mem.eql(u8, command_name, "-h")) return .help;
    parse_diagnostics.argument = command_name;
    return error.UnknownCommand;
}

fn parseList(command_args: []const []const u8, diagnostics: *Diagnostics) !List {
    var list: List = .{};
    var arg_index: usize = 0;
    while (arg_index < command_args.len) : (arg_index += 1) {
        const arg = command_args[arg_index];
        diagnostics.argument = arg;
        if (isUrlFlag(arg)) {
            arg_index += 1;
            if (arg_index == command_args.len) return error.MissingFlagValue;
            list.url = command_args[arg_index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return list;
}

fn parseInstall(command_args: []const []const u8, diagnostics: *Diagnostics) !Install {
    var version: ?[]const u8 = null;
    var url: []const u8 = index.defaultUrl;
    var arg_index: usize = 0;
    while (arg_index < command_args.len) : (arg_index += 1) {
        const arg = command_args[arg_index];
        diagnostics.argument = arg;
        if (isUrlFlag(arg)) {
            arg_index += 1;
            if (arg_index == command_args.len) return error.MissingFlagValue;
            url = command_args[arg_index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (version == null) {
            version = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return .{ .version = version orelse return error.MissingVersion, .url = url };
}

fn isUrlFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--url");
}

pub fn help(io: std.Io) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(usage);
    try stdout.flush();
}

test "list without flags uses the default index" {
    const command = try parseArgs(&.{ "zigup", "list" }, null);
    try std.testing.expectEqualStrings(index.defaultUrl, command.list.url);
}

test "list takes the index url from -u" {
    const command = try parseArgs(&.{ "zigup", "list", "-u", "https://example.invalid/index.json" }, null);
    try std.testing.expectEqualStrings("https://example.invalid/index.json", command.list.url);
}

test "list takes the index url from --url" {
    const command = try parseArgs(&.{ "zigup", "list", "--url", "https://example.invalid/index.json" }, null);
    try std.testing.expectEqualStrings("https://example.invalid/index.json", command.list.url);
}

test "list rejects --url without a value" {
    try std.testing.expectError(error.MissingFlagValue, parseArgs(&.{ "zigup", "list", "--url" }, null));
}

test "list rejects positional arguments" {
    try std.testing.expectError(error.UnexpectedArgument, parseArgs(&.{ "zigup", "list", "0.17.0" }, null));
}

test "list rejects unknown flags" {
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "zigup", "list", "--mirror" }, null));
}

test "install takes the version as its positional argument" {
    const command = try parseArgs(&.{ "zigup", "install", "0.17.0" }, null);
    try std.testing.expectEqualStrings("0.17.0", command.install.version);
    try std.testing.expectEqualStrings(index.defaultUrl, command.install.url);
}

test "install accepts the url flag before or after the version" {
    const url = "https://example.invalid/index.json";
    for ([_][]const []const u8{
        &.{ "zigup", "install", "0.17.0", "-u", url },
        &.{ "zigup", "install", "--url", url, "0.17.0" },
    }) |args| {
        const command = try parseArgs(args, null);
        try std.testing.expectEqualStrings("0.17.0", command.install.version);
        try std.testing.expectEqualStrings(url, command.install.url);
    }
}

test "install requires a version" {
    try std.testing.expectError(error.MissingVersion, parseArgs(&.{ "zigup", "install" }, null));
    try std.testing.expectError(error.MissingVersion, parseArgs(&.{ "zigup", "install", "-u", "https://example.invalid/index.json" }, null));
}

test "install rejects a second version" {
    try std.testing.expectError(error.UnexpectedArgument, parseArgs(&.{ "zigup", "install", "0.17.0", "0.16.0" }, null));
}

test "parseArgs reports the unknown command" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{ "zigup", "instal" }, &diagnostics));
    try std.testing.expectEqualStrings("instal", diagnostics.argument);
}

test "parseArgs reports the unknown flag and its command" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "zigup", "install", "0.17.0", "--mirror" }, &diagnostics));
    try std.testing.expectEqualStrings("install", diagnostics.command);
    try std.testing.expectEqualStrings("--mirror", diagnostics.argument);
}

test "parseArgs reports the flag that is missing its value" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.MissingFlagValue, parseArgs(&.{ "zigup", "list", "-u" }, &diagnostics));
    try std.testing.expectEqualStrings("list", diagnostics.command);
    try std.testing.expectEqualStrings("-u", diagnostics.argument);
}

test "parseArgs reports the unexpected argument" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.UnexpectedArgument, parseArgs(&.{ "zigup", "install", "0.17.0", "0.16.0" }, &diagnostics));
    try std.testing.expectEqualStrings("install", diagnostics.command);
    try std.testing.expectEqualStrings("0.16.0", diagnostics.argument);
}

test "parseArgs reports the command that is missing its version" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.MissingVersion, parseArgs(&.{ "zigup", "install" }, &diagnostics));
    try std.testing.expectEqualStrings("install", diagnostics.command);
}
