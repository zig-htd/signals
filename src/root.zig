//! zig-signals: 阻塞式信号等待库。
//!
//! 使用 self-pipe 技巧把异步信号转换成可同步阻塞读取的事件：
//! 信号处理函数只向管道写入一个字节，`wait` 通过 poll 阻塞在管道读端，
//! 醒来后把字节还原成信号返回。详见 docs/usage.md。

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// 支持的信号数量上限，覆盖 Linux 的全部信号编号（1..64）。
pub const max_signals = linux.NSIG - 1;

var read_fd: posix.fd_t = -1;
var write_fd: posix.fd_t = -1;
var registered_signals: [max_signals]posix.SIG = undefined;
var old_actions: [max_signals]posix.Sigaction = undefined;
var registered: usize = 0;

pub const InitError = error{
    AlreadyInitialized,
    InvalidSignal,
    PipeFailed,
};

pub const WaitError = posix.PollError || posix.ReadError || error{
    NotInitialized,
    PipeClosed,
};

/// 初始化 self-pipe 并安装 `signals` 中每个信号的处理函数。
///
/// 会保存旧的 sigaction，`deinit` 时恢复。重复出现的信号会被去重。
pub fn init(signals: []const posix.SIG) InitError!void {
    if (write_fd != -1) return InitError.AlreadyInitialized;

    for (signals) |sig| {
        if (!isValidSignal(sig)) return InitError.InvalidSignal;
    }

    const fds = try makePipe();
    read_fd = fds[0];
    write_fd = fds[1];

    const action: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    var count: usize = 0;
    for (signals) |sig| {
        var duplicate = false;
        for (registered_signals[0..count]) |existing| {
            if (existing == sig) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        posix.sigaction(sig, &action, &old_actions[count]);
        registered_signals[count] = sig;
        count += 1;
    }
    registered = count;
}

/// 恢复旧的信号处理函数并关闭 self-pipe。
///
/// 未初始化时是空操作，可以重复调用。
pub fn deinit() void {
    if (write_fd == -1) return;

    // 顺序不能反：先摘掉 handler，再关闭 fd。
    // 否则 handler 可能写入已经关闭、甚至已被复用的 fd。
    for (0..registered) |i| {
        posix.sigaction(registered_signals[i], &old_actions[i], null);
    }
    registered = 0;

    rawClose(read_fd);
    rawClose(write_fd);
    read_fd = -1;
    write_fd = -1;
}

/// 阻塞等待，直到收到一个已注册的信号。
pub fn wait() WaitError!posix.SIG {
    // timeout 为 -1 时 poll 不会返回 0。
    return (try waitTimeout(-1)) orelse unreachable;
}

/// 最多等待 `timeout_ms` 毫秒。`timeout_ms` 为 `-1` 表示无限等待。
///
/// 超时返回 `null`。
pub fn waitTimeout(timeout_ms: i32) WaitError!?posix.SIG {
    if (read_fd == -1) return WaitError.NotInitialized;

    var poll_fds = [1]posix.pollfd{
        .{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        // posix.poll 内部已经处理了 EINTR。
        const n = try posix.poll(&poll_fds, timeout_ms);
        if (n == 0) return null;

        if (poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            return WaitError.PipeClosed;
        }

        var byte: [1]u8 = undefined;
        const len = posix.read(read_fd, &byte) catch |err| switch (err) {
            // poll 被唤醒但字节已被读走，重新等待。
            posix.ReadError.WouldBlock => continue,
            else => return err,
        };
        if (len != 1) return WaitError.PipeClosed;

        return @fromBackingInt(@intCast(byte[0]));
    }
}

/// 判断信号是否可以注册：排除 KILL/STOP，以及 1..NSIG 之外的非法值。
fn isValidSignal(sig: posix.SIG) bool {
    const value = @backingInt(sig);
    if (value == 0 or value >= linux.NSIG) return false;
    return sig != .KILL and sig != .STOP;
}

/// 信号处理函数。
///
/// 只能做异步信号安全的事：向管道写一个字节。不能分配、加锁、打印或处理错误。
/// 写满（EAGAIN）时直接忽略：管道非空意味着仍有待处理的信号通知。
fn signalHandler(sig: posix.SIG) callconv(.c) void {
    rawWrite(write_fd, @intCast(@backingInt(sig)));
}

/// 创建非阻塞、CLOEXEC 的管道。
fn makePipe() InitError![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;

    // 写入端非阻塞：handler 里的 write 永不阻塞。
    // 读取端非阻塞：等待交给 poll，而不是 read。
    // CLOEXEC：exec 出来的子进程不会继承这两个 fd。
    const rc = linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (rc != 0) return InitError.PipeFailed;

    return fds;
}

/// 原始写系统调用。返回 usize 而不是 error union，错误直接忽略。
fn rawWrite(fd: posix.fd_t, byte: u8) void {
    const buf: [1]u8 = .{byte};
    _ = posix.system.write(fd, &buf, 1);
}

/// 原始 close 系统调用。忽略错误：对 EINTR 重试反而可能关掉被复用的 fd。
fn rawClose(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

test "init and deinit lifecycle" {
    try init(&.{});
    try std.testing.expectError(InitError.AlreadyInitialized, init(&.{}));
    deinit();

    try init(&.{});
    deinit();
}

test "rejects invalid signals" {
    try std.testing.expectError(InitError.InvalidSignal, init(&.{.KILL}));
    try std.testing.expectError(InitError.InvalidSignal, init(&.{.STOP}));
    try std.testing.expectError(InitError.InvalidSignal, init(&.{@fromBackingInt(@intCast(0))}));
    try std.testing.expectError(InitError.InvalidSignal, init(&.{@fromBackingInt(@intCast(linux.NSIG))}));
}

test "deduplicates repeated signals" {
    var many: [100]posix.SIG = undefined;
    for (&many) |*sig| sig.* = .USR1;

    try init(&many);
    defer deinit();
}

test "waitTimeout returns null on timeout" {
    try init(&.{});
    defer deinit();

    try std.testing.expectEqual(@as(?posix.SIG, null), try waitTimeout(10));
}

test "wait returns raised signal" {
    try init(&.{.USR1});
    defer deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn raise() void {
            posix.raise(.USR1) catch {};
        }
    }.raise, .{});
    t.join();

    const sig = try waitTimeout(1000);
    try std.testing.expectEqual(posix.SIG.USR1, sig.?);
}
