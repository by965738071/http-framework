//! 应用级服务容器 —— 让 handler/中间件脱离全局变量（回应架构缺陷 #2）
//!
//! 问题：SessionManager / Logger / ORM Store 这类**进程级**单例，原来
//! 只能声明成文件级全局变量供 handler 访问。后果：无法多实例、测试要清
//! 全局、Context.user_data 是请求级的承载不了进程级服务。
//!
//! 方案：`Services` 是一个按类型索引的服务注册表，生命周期与 Server 绑定
//! （不随请求回收）。用户在启动时 `register(T, ptr)`，handler 通过
//! `ctx.service(T)` 取回，不再依赖全局符号。
//!
//! 线程安全：注册发生在启动阶段（单线程），之后只读——并发 dispatch 只
//! 调 `get`，无需锁。注册表本身不持有服务的所有权（只存指针），服务的
//! 生命周期仍由调用方（通常是 main 的 defer）管理。

const std = @import("std");

pub const Services = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    allocator: std.mem.Allocator,

    const Entry = struct {
        /// @typeName(T) —— 编译期字符串，稳定且唯一，作为类型键。
        key: []const u8,
        ptr: *anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator) Services {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Services) void {
        self.entries.deinit(self.allocator);
    }

    /// 注册一个服务实例（按类型索引）。重复注册同类型会覆盖旧指针。
    /// 只存指针，不接管所有权——服务的生命周期由调用方负责。
    /// 应在启动阶段（开始服务前）调用，不要在并发 dispatch 中调用。
    pub fn register(self: *Services, comptime T: type, ptr: *T) !void {
        const key = @typeName(T);
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.ptr = @ptrCast(ptr);
                return;
            }
        }
        try self.entries.append(self.allocator, .{ .key = key, .ptr = @ptrCast(ptr) });
    }

    /// 取回某类型的服务指针，未注册返回 null。
    pub fn get(self: *const Services, comptime T: type) ?*T {
        const key = @typeName(T);
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                return @ptrCast(@alignCast(e.ptr));
            }
        }
        return null;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Services register and get by type" {
    const allocator = std.testing.allocator;
    var svc = Services.init(allocator);
    defer svc.deinit();

    const Foo = struct { n: u32 };
    const Bar = struct { s: []const u8 };

    var foo = Foo{ .n = 42 };
    var bar = Bar{ .s = "hello" };

    try svc.register(Foo, &foo);
    try svc.register(Bar, &bar);

    try std.testing.expectEqual(@as(u32, 42), svc.get(Foo).?.n);
    try std.testing.expectEqualStrings("hello", svc.get(Bar).?.s);

    // 未注册的类型返回 null
    const Baz = struct {};
    try std.testing.expect(svc.get(Baz) == null);
}

test "Services register overwrites same type" {
    const allocator = std.testing.allocator;
    var svc = Services.init(allocator);
    defer svc.deinit();

    const Counter = struct { v: u32 };
    var a = Counter{ .v = 1 };
    var b = Counter{ .v = 2 };

    try svc.register(Counter, &a);
    try svc.register(Counter, &b);

    // 覆盖后指向 b，且只保留一条记录
    try std.testing.expectEqual(@as(u32, 2), svc.get(Counter).?.v);
    try std.testing.expectEqual(@as(usize, 1), svc.entries.items.len);
}
