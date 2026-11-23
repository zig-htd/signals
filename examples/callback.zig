const std = @import("std");
const Io = std.Io;
const signals = @import("signals");

var should_exit: Io.Event = .unset;

const Context = struct {
    io: Io,

    fn onSignal(ctx: *anyopaque, sig: std.posix.SIG) void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        std.debug.print("Received: {s}\n", .{@tagName(sig)});

        should_exit.set(self.io);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var context: Context = .{ .io = io };

    try signals.initCallback(
        io,
        &.{ .INT, .TERM },
        &context,
        Context.onSignal,
    );
    defer signals.deinit();

    std.debug.print("Waiting for SIGINT/SIGTERM via callback...\n", .{});
    try should_exit.wait(io);
    std.debug.print("Goodbye!\n", .{});
}
