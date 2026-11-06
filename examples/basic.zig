const std = @import("std");
const signals = @import("zig_signals");

pub fn main() !void {
    try signals.init(&.{ .INT, .TERM });
    defer signals.deinit();

    std.debug.print("Waiting for SIGINT/SIGTERM...\n", .{});

    const sig = try signals.wait();
    std.debug.print("Received: {s}\n", .{@tagName(sig)});
}
