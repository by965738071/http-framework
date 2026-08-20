//! Cross-platform signal handling for graceful shutdown.
//!
//! On POSIX systems, uses sigaction to register handlers for SIGINT/SIGTERM.
//! On Windows, uses SetConsoleCtrlHandler to catch Ctrl+C and console close events.
//!
//! The handler only sets an atomic flag AND (on Windows) signals a shutdown
//! event. The main loop waits on that event to unblock itself, because
//! Windows Ctrl+C does not interrupt a blocking accept() the way POSIX
//! signals do via EINTR.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const is_windows = builtin.target.os.tag == .windows;

/// Opaque handle to the shutdown trigger.
/// On POSIX this is just a pointer to the atomic flag; on Windows it's
/// the same — we keep it opaque so the handler stays platform-agnostic.
pub const ShutdownHandle = struct {
    flag: *std.atomic.Value(bool),
};

/// Global handle so the C-style signal handler can access the shutdown flag.
/// Only one server instance exists per process, so a single global is fine.
var global_handle: ?ShutdownHandle = null;

/// Optional shutdown event handle (Windows only). Signaled by the Ctrl
/// handler so the run loop can wake out of WaitForMultipleObjects without
/// touching the listening socket.
var global_event: ?std.os.windows.HANDLE = null;

/// Set the global shutdown handle. Must be called before installing handlers.
pub fn setHandle(handle: ShutdownHandle) void {
    global_handle = handle;
}

/// Register the shutdown event handle (Windows only). Must be called before
/// install(). The handler signals this event; the run loop waits on it.
/// Pass null to unregister (called when the server exits).
pub fn setEventHandle(handle: ?std.os.windows.HANDLE) void {
    global_event = handle;
}

/// Trigger graceful shutdown via the global handle and event.
fn triggerShutdown() void {
    if (global_handle) |h| {
        h.flag.store(true, .monotonic);
    }
    if (global_event) |ev| {
        _ = SetEvent(ev);
    }
}

// ─── POSIX implementation ──────────────────────────────────────────────

fn posixSignalHandler(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    // On POSIX the signal interrupts the blocking accept() syscall (EINTR),
    // so setting the flag is enough — the run loop observes it and breaks.
    if (global_handle) |h| {
        h.flag.store(true, .monotonic);
    }
}

fn installPosixHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posixSignalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    _ = posix.sigaction(.INT, &act, null);
    _ = posix.sigaction(.TERM, &act, null);
}

// ─── Windows implementation ────────────────────────────────────────────

const windows = std.os.windows;

/// Windows console control handler.
/// Ctrl+C (0)、Ctrl+Break (1)、控制台关闭 (2) 均触发优雅关机。
/// 返回 TRUE 表示已自行处理——进程必须在 run() 退出后自行终止，
/// 否则（如控制台关闭）系统只等待约 5 秒便会强制结束进程。
fn windowsCtrlHandler(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    std.debug.print("windowsCtrlHandler: ctrl_type = {}\n", .{ctrl_type});
    switch (ctrl_type) {
        0, 1, 2 => {
            triggerShutdown();
            return windows.BOOL.TRUE; // handled
        },
        else => return windows.BOOL.FALSE, // let other handlers run
    }
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetEvent(h_event: windows.HANDLE) callconv(.c) windows.BOOL;

fn installWindowsHandlers() void {
    _ = SetConsoleCtrlHandler(windowsCtrlHandler, windows.BOOL.TRUE);
}

// ─── Public API ────────────────────────────────────────────────────────

/// Install signal handlers for graceful shutdown.
/// Must be called after setHandle() (and setEventHandle() on Windows).
pub fn install() void {
    if (comptime is_windows) {
        installWindowsHandlers();
    } else {
        installPosixHandlers();
    }
}
