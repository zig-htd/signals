# signals

A Zig library for safely handling process signals, with both blocking wait and callback usage modes.

## Introduction

Handling POSIX signals is not especially difficult, but it is unsafe because an asynchronous signal handler can interrupt normal thread execution at any instruction. Inside this interruption context, operations such as locking, allocating memory, I/O buffering, modifying complex shared state, or waiting for another thread can deadlock, re-enter code, introduce data races, or cause undefined behavior. The usual recommendation is to do as little as possible in a handler. The classic [self-pipe trick](https://cr.yp.to/docs/selfpipe.html) is well suited to this problem.

This library implements that self-pipe design (along with asynchronous tasks in Zig 0.16).

## Installation

Add the dependency to `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/zig-htd/signals
```

Then add the module to `build.zig`:

```zig
const signals = b.dependency("signals", .{});
// ...
exe.root_module.addImport("signals", signals.module("signals"));
```

## Usage

Blocking the main thread while waiting for a signal is a common use case. We usually do not need to worry about graceful shutdown because a normally exiting `main` function executes `defer` statements.

```zig
const std = @import("std");
const signals = @import("signals");

pub fn main() !void {
    try signals.init(&.{ .INT, .TERM });  // <- Register the signals to handle during initialization
    defer signals.deinit();               // <- Remember to call deinit

    std.debug.print("Waiting for SIGINT/SIGTERM...\n", .{});

    const sig = try signals.wait();       // <- Block here until a signal arrives
    std.debug.print("Received: {s}\n", .{@tagName(sig)});
    std.debug.print("Goodbye!\n", .{});
}
```

Sometimes a long-running task blocks execution first, or you need to hand off the responsibility for blocking. In that case, use callbacks. Implement graceful shutdown in the callback:

```zig
const std = @import("std");
const signals = @import("signals");

var should_exit: std.Io.Event = .unset; // <- Whether the program should exit

const Context = struct {
    io: std.Io,

    fn onSignal(ctx: *anyopaque, sig: std.posix.SIG) void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        std.debug.print("Received: {s}\n", .{@tagName(sig)});

        should_exit.set(self.io);       // <- Tell the blocking location to exit
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
    try should_exit.wait(io);           // <- Block until the exit event is received
    std.debug.print("Goodbye!\n", .{});
}
```

When a signal arrives, our callback code runs inside a separate asynchronous task. It does not interrupt the execution of any context and is therefore substantially safer than native POSIX signal behavior.

## Notes

This library is well tested only on Linux; availability on other platforms is uncertain. It is also not the most modern approach: the more modern option is `signalfd`, a Linux-specific mechanism. However, the self-pipe technique is the classic solution.
