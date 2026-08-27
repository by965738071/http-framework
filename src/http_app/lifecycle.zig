//! 统一生命周期钩子（回应 bug.md §9）
//!
//! 原来有 3 套独立的接入方式：Logger（vtable + setLogger）、
//! RequestObserver（vtable + setObserver）、Worker（vtable + setWorker）。
//! 加新钩子类型要改 core。
//!
//! 现在用统一的 `Hook` trait + `Event` enum。Logger/Observer/Worker
//! 都变成 Hook 的具体实现，各自注册自己关心的 Event。扩展点开放。

const std = @import("std");
const Context = @import("context.zig").Context;
const Response = @import("http_protocol").Response;

pub const Event = enum {
    connection_open,
    connection_close,
    request_start,
    request_end,
    request_error,
    tick,
};

pub const EventData = struct {
    ctx: ?*const Context = null,
    res: ?*const Response = null,
    err: ?anyerror = null,
    duration_ns: ?u64 = null,
    method: ?std.http.Method = null,
    path: ?[]const u8 = null,
    status: ?std.http.Status = null,
    route_pattern: ?[]const u8 = null,
};

pub const Hook = struct {
    ptr: *anyopaque,
    callback: *const fn (*anyopaque, Event, *const EventData) void,

    pub fn init(comptime T: type, ptr: *T) Hook {
        const cb = struct {
            fn call(any: *anyopaque, event: Event, data: *const EventData) void {
                const self: *T = @ptrCast(@alignCast(any));
                self.onEvent(event, data);
            }
        }.call;
        return .{ .ptr = @ptrCast(ptr), .callback = cb };
    }
};

pub const Lifecycle = struct {
    hooks: []const Hook = &.{},

    pub fn emit(self: Lifecycle, event: Event, data: EventData) void {
        for (self.hooks) |h| h.callback(h.ptr, event, &data);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Lifecycle emits events to all hooks" {
    const Counter = struct {
        count: u32 = 0,
        last_event: ?Event = null,

        pub fn onEvent(self: *@This(), event: Event, _: *const EventData) void {
            self.count += 1;
            self.last_event = event;
        }
    };

    var counter = Counter{};
    const hooks = [_]Hook{Hook.init(Counter, &counter)};
    const lifecycle = Lifecycle{ .hooks = &hooks };

    lifecycle.emit(.request_start, .{});
    try std.testing.expectEqual(@as(u32, 1), counter.count);
    try std.testing.expectEqual(Event.request_start, counter.last_event.?);

    lifecycle.emit(.request_end, .{});
    try std.testing.expectEqual(@as(u32, 2), counter.count);
    try std.testing.expectEqual(Event.request_end, counter.last_event.?);
}

test "Logger as a Hook implementation" {
    const Logger = struct {
        lines: *std.ArrayList([]const u8),
        alloc: std.mem.Allocator,

        pub fn onEvent(self: *@This(), event: Event, data: *const EventData) void {
            switch (event) {
                .request_start => {
                    const method = if (data.method) |m| @tagName(m) else "?";
                    const path = if (data.path) |p| p else "?";
                    self.lines.append(self.alloc, std.fmt.allocPrint(self.alloc, "[REQ] {s} {s}", .{ method, path }) catch "?") catch {};
                },
                else => {},
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lines = std.ArrayList([]const u8).empty;
    var logger = Logger{ .lines = &lines, .alloc = arena.allocator() };
    const hooks = [_]Hook{Hook.init(Logger, &logger)};
    const lifecycle = Lifecycle{ .hooks = &hooks };

    lifecycle.emit(.request_start, .{ .method = .GET, .path = "/hello" });
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "/hello") != null);
}

test {
    std.testing.refAllDecls(@This());
}
