//! 应用级服务容器 —— 让 handler/中间件脱离全局变量（回应架构缺陷 #2）
//!
//! 问题：SessionManager / Logger / ORM Store 这类**进程级**单例，原来
//! 只能声明成文件级全局变量供 handler 访问。后果：无法多实例、测试要清
//! 全局、Context.user_data 是请求级的承载不了进程级服务。
//!
//! 方案：`Services` 是一个按类型索引的服务注册表，生命周期与 Server 绑定
//! （不随请求回收）。用户在启动时 `register(T, ptr)` 并在开始服务前 `seal()`，
//! handler 通过 `ctx.service(T)` 取回，不再依赖全局符号。
//!
//! 线程安全：注册发生在启动阶段（单线程），注册完成后调用 `seal()` 封箱，
//! 之后 `register` 返回 `error.ServicesSealed`（把「启动后不得再注册」从约定
//! 变成显式失败，防止运行期 realloc 与并发 `get` 竞态）。注意 seal 本身不加
//! 锁——它检测的是误用，不能替代对 register/seal 并发调用所需的同步。
//! 注册表不持有服务的所有权（只存指针），服务的生命周期仍由调用方
//! （通常是 main 的 defer）管理。

const std = @import("std");

pub const Services = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    allocator: std.mem.Allocator,
    /// 启动阶段结束后由 `seal()` 置位；置位后 `register` 一律失败。
    sealed: bool = false,

    pub const Error = error{ OutOfMemory, ServicesSealed };

    const Entry = struct {
        /// 类型对应的编译期唯一哨兵指针地址（只需指针相等，免字符串比较）。
        key: *const anyopaque,
        ptr: *anyopaque,
    };

    /// 为类型 T 生成编译期唯一的哨兵指针（每个 T 对应一个独立的静态地址）。
    /// 用作类型键比 @typeName 字符串更快（指针相等而非逐字节比较）。
    /// Tag 里嵌入 `const _t = T` 让不同 T 得到不同的泛型实例，实践中不会串键；
    /// 但语言规范不保证地址必然互异（理论上存在链接器折叠 identical 全局的
    /// 可能），故只用于非安全敏感的索引，鉴权等场景勿依赖它做唯一性证明。
    fn typeKey(comptime T: type) *const anyopaque {
        // 把 T 嵌入 Tag 使每个 T 得到独立的静态 sentinel（防止编译器合并实例）。
        const Tag = struct {
            const _t = T;
            var sentinel: u8 = 0;
        };
        return &Tag.sentinel;
    }

    pub fn init(allocator: std.mem.Allocator) Services {
        return .{ .allocator = allocator };
    }

    /// 封箱：声明注册阶段结束。在 Server 开始接受请求前调用，之后任何
    /// `register`（含覆盖注册）都会返回 `error.ServicesSealed`，把并发写
    /// entries 导致的 realloc 竞态/撕裂读变成可发现的显式错误。
    pub fn seal(self: *Services) void {
        self.sealed = true;
    }

    pub fn deinit(self: *Services) void {
        self.entries.deinit(self.allocator);
    }

    /// 注册一个服务实例（按类型索引）。重复注册同类型会覆盖旧指针。
    /// 只存指针，不接管所有权——服务的生命周期由调用方负责。
    /// 只能在启动阶段（`seal()` 之前）调用；封箱后返回 `error.ServicesSealed`。
    pub fn register(self: *Services, comptime T: type, ptr: *T) Error!void {
        if (self.sealed) return error.ServicesSealed;
        const key = typeKey(T);
        for (self.entries.items) |*e| {
            if (e.key == key) {
                e.ptr = @ptrCast(ptr);
                return;
            }
        }
        try self.entries.append(self.allocator, .{ .key = key, .ptr = @ptrCast(ptr) });
    }

    /// 取回某类型的服务指针，未注册返回 null。
    pub fn get(self: *const Services, comptime T: type) ?*T {
        const key = typeKey(T);
        for (self.entries.items) |e| {
            if (e.key == key) {
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

test "Services seal blocks further register" {
    const allocator = std.testing.allocator;
    var svc = Services.init(allocator);
    defer svc.deinit();

    const Foo = struct { n: u32 };
    const Bar = struct { m: u32 };
    var foo = Foo{ .n = 1 };
    var foo2 = Foo{ .n = 2 };
    var bar = Bar{ .m = 3 };

    try svc.register(Foo, &foo);
    svc.seal();

    // 封箱后：新增类型和覆盖已有类型都被拒绝
    try std.testing.expectError(error.ServicesSealed, svc.register(Bar, &bar));
    try std.testing.expectError(error.ServicesSealed, svc.register(Foo, &foo2));

    // 已注册的服务不受影响，仍能取回且仍指向旧实例
    try std.testing.expectEqual(@as(u32, 1), svc.get(Foo).?.n);
    try std.testing.expect(svc.get(Bar) == null);
}

test {
    std.testing.refAllDecls(@This());
}
