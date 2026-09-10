const std = @import("std");
const framework = @import("http_framework");
const admin = @import("admin");
const devices = @import("devices");
const register = @import("register");

// Re-export admin declarations for testing
pub const Role = admin.Role;
pub const AdminUser = admin.AdminUser;
pub const SystemLog = admin.SystemLog;
pub const AdminServices = admin.AdminServices;
pub const Notifications = admin.Notifications;

// Middleware and handler types
pub const RequireAuthMiddleware = admin.RequireAuthMiddleware;
pub const RequireRoleMiddleware = admin.RequireRoleMiddleware;

// Handler structs
pub const LoginPageHandler = admin.LoginPageHandler;
pub const LoginApiHandler = admin.LoginApiHandler;
pub const LogoutHandler = admin.LogoutHandler;
pub const DashboardHandler = admin.DashboardHandler;
pub const UserListHandler = admin.UserListHandler;
pub const UserCreateHandler = admin.UserCreateHandler;
pub const UserGetHandler = admin.UserGetHandler;
pub const UserUpdateHandler = admin.UserUpdateHandler;
pub const UserDeleteHandler = admin.UserDeleteHandler;
pub const LogListHandler = admin.LogListHandler;
pub const LogClearHandler = admin.LogClearHandler;
pub const SettingsHandler = admin.SettingsHandler;
pub const MeHandler = admin.MeHandler;
pub const WsNotificationsHandler = admin.WsNotificationsHandler;

// Device management exports
pub const DeviceModel = devices.DeviceModel;
pub const DeviceStore = devices.DeviceStore;
pub const DeviceListHandler = devices.DeviceListHandler;
pub const DeviceCreateHandler = devices.DeviceCreateHandler;
pub const DeviceGetHandler = devices.DeviceGetHandler;
pub const DeviceUpdateHandler = devices.DeviceUpdateHandler;
pub const DeviceDeleteHandler = devices.DeviceDeleteHandler;

// User registration exports
pub const RegisterHandler = register.RegisterHandler;

test "Notifications: register 在 capacity 内扩窗写入（越界写回归）" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var notifications = admin.Notifications.init(allocator, io);
    defer notifications.deinit();

    var fakes: [3]*framework.WebSocket = undefined;
    for (&fakes) |*slot| slot.* = try allocator.create(framework.WebSocket);
    defer for (fakes) |p| allocator.destroy(p);

    // 修复前：register 用 index == len 写切片 → Debug 下这里直接 panic。
    notifications.register(fakes[0]);
    notifications.register(fakes[1]);
    try std.testing.expectEqual(@as(usize, 2), notifications.connections.len);

    // swap-remove：删第一个后，最后一个补位、长度缩回。
    notifications.unregister(fakes[0]);
    try std.testing.expectEqual(@as(usize, 1), notifications.connections.len);
    try std.testing.expect(notifications.connections[0] == fakes[1]);

    // 塞满 capacity（16）后多余的 register 静默丢弃，不得越界写。
    for (0..20) |_| notifications.register(fakes[0]);
    try std.testing.expectEqual(@as(usize, 16), notifications.connections.len);
}

test {
    std.testing.refAllDecls(@This());
}
