const std = @import("std");
const admin = @import("admin.zig");

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

test {
    std.testing.refAllDecls(@This());
}
