const std = @import("std");
const Io = std.Io;

const version_info = @import("version");

pub fn main(io: Io) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("zigup {s} ({s})\n", .{ version_info.version, version_info.git_revision });
    try stdout.flush();
}
