const std = @import("std");
const Io = std.Io;

const zigup = @import("zigup");

/// Restores the terminal if the TUI panics.
pub const panic = @import("zigtui").panic;

pub fn main(init: std.process.Init) !void {
    try zigup.main(init);
}
