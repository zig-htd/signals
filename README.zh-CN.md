# signals

安全处理进程信号的 Zig 库，支持阻塞式等待和回调两种使用模式。

## 介绍

处理 POSIX 信号不算麻烦，但它很不安全，因为异步信号处理函数（handler）可能在任意指令处打断正常线程的执行。在这个中断上下文中，任何加锁、分配内存、I/O 缓冲、修改复杂共享状态、等待其他线程等操作，都可能死锁、重入、数据竞争或发生未定义行为。大家的共识是在 handler 里尽量少做事，经典的[自管道技巧](https://cr.yp.to/docs/selfpipe.html)很适合处理这个场景！

本库的实现建立在自管道的设计之上（以及 Zig 0.16 的异步任务）。

## 安装

添加依赖到 `build.zig.zon`：

```sh
zig fetch --save git+https://github.com/zig-htd/signals
```

然后在 `build.zig` 中添加模块：

```zig
const signals = b.dependency("signals", .{});
// ...
exe.root_module.addImport("signals", signals.module("signals"));
```

## 使用

用等待信号来阻塞主线程，是常见的使用场景。我们通常无需担心程序的优雅结束，因为 main 函数正常结束（`defer` 会被执行）。

```zig
const std = @import("std");
const signals = @import("signals");

pub fn main() !void {
    try signals.init(&.{ .INT, .TERM });  // <- 初始化时注册要处理的信号
    defer signals.deinit();               // <- 记得 deinit

    std.debug.print("Waiting for SIGINT/SIGTERM...\n", .{});

    const sig = try signals.wait();       // <- 此处会阻塞，等待信号（作为返回值）
    std.debug.print("Received: {s}\n", .{@tagName(sig)});
    std.debug.print("Goodbye!\n", .{});
}
```

有时候，长任务会提前造成阻塞。或需要将“阻塞”的权利移交出去。这时候我们需要回调。在回调中实施“控制”，以优雅结束：

```zig
const std = @import("std");
const signals = @import("signals");

var should_exit: std.Io.Event = .unset; // <- 是否退出的标识

const Context = struct {
    io: std.Io,

    fn onSignal(ctx: *anyopaque, sig: std.posix.SIG) void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        std.debug.print("Received: {s}\n", .{@tagName(sig)});

        should_exit.set(self.io);       // <- 告知阻塞的位置，应该退出了
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
    try should_exit.wait(io);           // <- 阻塞直到收到退出事件
    std.debug.print("Goodbye!\n", .{});
}
```

当收到信号，执行我们的回调代码时，它在一个独立的异步任务中。它不会“打断”任何上下文的执行，相比于 POSIX 原生行为它安全得多。

## 注意事项

本库仅在 Linux 平台充分测试，其它平台是否可用尚不确定。以及它不是“最现代”的做法，更现代的方法是使用 `signalfd`（Linux 特有），但自管道是最经典的方法。
