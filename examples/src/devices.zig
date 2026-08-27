//! Device management module
//!
//! 功能：
//!   ├─ 设备 CRUD（列表/创建/获取/更新/删除）
//!   └─ 设备模型（name, type, status, serial_number, location）

const std = @import("std");
const framework = @import("http_framework");

// ────────────────────────────────────────────────────────────────────────────
// 设备类型和状态枚举
// ────────────────────────────────────────────────────────────────────────────

pub const DeviceType = enum {
    sensor,
    actuator,
    gateway,
    controller,

    pub fn toString(self: DeviceType) []const u8 {
        return switch (self) {
            .sensor => "sensor",
            .actuator => "actuator",
            .gateway => "gateway",
            .controller => "controller",
        };
    }

    pub fn fromString(str: []const u8) ?DeviceType {
        if (std.mem.eql(u8, str, "sensor")) return .sensor;
        if (std.mem.eql(u8, str, "actuator")) return .actuator;
        if (std.mem.eql(u8, str, "gateway")) return .gateway;
        if (std.mem.eql(u8, str, "controller")) return .controller;
        return null;
    }
};

pub const DeviceStatus = enum {
    online,
    offline,
    maintenance,
    error_status,

    pub fn toString(self: DeviceStatus) []const u8 {
        return switch (self) {
            .online => "online",
            .offline => "offline",
            .maintenance => "maintenance",
            .error_status => "error",
        };
    }

    pub fn fromString(str: []const u8) ?DeviceStatus {
        if (std.mem.eql(u8, str, "online")) return .online;
        if (std.mem.eql(u8, str, "offline")) return .offline;
        if (std.mem.eql(u8, str, "maintenance")) return .maintenance;
        if (std.mem.eql(u8, str, "error")) return .error_status;
        return null;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// ORM 模型定义
// ────────────────────────────────────────────────────────────────────────────

const OrmDevice = struct {
    id: u64 = 0,
    name: []const u8,
    type: []const u8,
    status: []const u8,
    serial_number: []const u8,
    location: []const u8,
    created_at: u64 = 0,
    last_seen: u64 = 0,
};

pub const DeviceModel = framework.orm.Model(OrmDevice, "devices");
pub const DeviceStore = DeviceModel.Store;

// ────────────────────────────────────────────────────────────────────────────
// Handler 实现函数
// ────────────────────────────────────────────────────────────────────────────

/// 设备列表（支持 type/status 过滤）
pub fn deviceListHandler(ctx: *framework.Context, res: *framework.Response, store: *DeviceStore) !void {
    const all_devices = try store.all(ctx.arena);

    // 支持 query 参数过滤
    const type_filter = ctx.query("type");
    const status_filter = ctx.query("status");

    // 如果有过滤条件，进行过滤
    if (type_filter != null or status_filter != null) {
        var filtered = std.ArrayList(OrmDevice).empty;
        defer filtered.deinit(ctx.arena);

        for (all_devices) |device| {
            var match = true;
            if (type_filter) |tf| {
                if (!std.mem.eql(u8, device.type, tf)) {
                    match = false;
                }
            }
            if (status_filter) |sf| {
                if (!std.mem.eql(u8, device.status, sf)) {
                    match = false;
                }
            }
            if (match) {
                try filtered.append(ctx.arena, device);
            }
        }
        try res.json(.{ .total = filtered.items.len, .devices = filtered.items });
    } else {
        try res.json(.{ .total = all_devices.len, .devices = all_devices });
    }
}

/// 创建设备
pub fn deviceCreateHandler(ctx: *framework.Context, res: *framework.Response, store: *DeviceStore, io: std.Io) !void {
    const name = (ctx.formDecoded("name", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("name required"));
        return;
    };

    const device_type = (ctx.formDecoded("type", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("type required"));
        return;
    };

    // 验证设备类型
    if (DeviceType.fromString(device_type) == null) {
        try ctx.failWith(res, framework.AppError.badRequest("invalid device type. Must be: sensor, actuator, gateway, controller"));
        return;
    }

    const serial_number = (ctx.formDecoded("serial_number", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("serial_number required"));
        return;
    };

    const location = (ctx.formDecoded("location", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse "";

    const status_str = (ctx.formDecoded("status", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse "offline";

    // 验证设备状态
    if (DeviceStatus.fromString(status_str) == null) {
        try ctx.failWith(res, framework.AppError.badRequest("invalid device status. Must be: online, offline, maintenance, error"));
        return;
    }

    const now = @as(u64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000)));

    const id = store.insert(.{
        .id = 0,
        .name = name,
        .type = device_type,
        .status = status_str,
        .serial_number = serial_number,
        .location = location,
        .created_at = now,
        .last_seen = now,
    }) catch |err| {
        if (err == error.UniqueViolation) {
            try ctx.failWith(res, framework.AppError.conflict("serial number already exists"));
            return;
        }
        return err;
    };
    try store.flush();

    try res.statusCode(.created).json(.{
        .id = id,
        .name = name,
        .type = device_type,
        .status = status_str,
        .serial_number = serial_number,
        .location = location,
        .created_at = now,
        .last_seen = now,
    });
}

/// 获取单个设备
pub fn deviceGetHandler(ctx: *framework.Context, res: *framework.Response, store: *DeviceStore) !void {
    const id = parseId(ctx, res) orelse return;

    const device = try store.findById(ctx.arena, id) orelse {
        try ctx.failWith(res, framework.AppError.notFound("device not found"));
        return;
    };

    try res.json(device);
}

/// 更新设备
pub fn deviceUpdateHandler(ctx: *framework.Context, res: *framework.Response, store: *DeviceStore) !void {
    const id = parseId(ctx, res) orelse return;

    var device = try store.findById(ctx.arena, id) orelse {
        try ctx.failWith(res, framework.AppError.notFound("device not found"));
        return;
    };

    // 更新字段（可选）
    if (ctx.formDecoded("name", 1 << 16) catch null) |name| {
        device.name = name;
    }

    if (ctx.formDecoded("type", 1 << 16) catch null) |device_type| {
        if (DeviceType.fromString(device_type) == null) {
            try ctx.failWith(res, framework.AppError.badRequest("invalid device type"));
            return;
        }
        device.type = device_type;
    }

    if (ctx.formDecoded("status", 1 << 16) catch null) |status_str| {
        if (DeviceStatus.fromString(status_str) == null) {
            try ctx.failWith(res, framework.AppError.badRequest("invalid device status"));
            return;
        }
        device.status = status_str;
    }

    if (ctx.formDecoded("serial_number", 1 << 16) catch null) |serial_number| {
        device.serial_number = serial_number;
    }

    if (ctx.formDecoded("location", 1 << 16) catch null) |location| {
        device.location = location;
    }

    _ = try store.updateById(id, device);
    try store.flush();

    try res.json(device);
}

/// 删除设备
pub fn deviceDeleteHandler(ctx: *framework.Context, res: *framework.Response, store: *DeviceStore) !void {
    const id = parseId(ctx, res) orelse return;

    const deleted = try store.deleteById(id);
    if (!deleted) {
        try ctx.failWith(res, framework.AppError.notFound("device not found"));
        return;
    }
    try store.flush();
    try res.json(.{ .ok = true, .message = "device deleted" });
}

// ────────────────────────────────────────────────────────────────────────────
// Handler wrapper structs
// ────────────────────────────────────────────────────────────────────────────

pub const DeviceListHandler = struct {
    store: *DeviceStore,

    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return deviceListHandler(ctx, res, self.store);
    }
};

pub const DeviceCreateHandler = struct {
    store: *DeviceStore,
    io: std.Io,

    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return deviceCreateHandler(ctx, res, self.store, self.io);
    }
};

pub const DeviceGetHandler = struct {
    store: *DeviceStore,

    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return deviceGetHandler(ctx, res, self.store);
    }
};

pub const DeviceUpdateHandler = struct {
    store: *DeviceStore,

    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return deviceUpdateHandler(ctx, res, self.store);
    }
};

pub const DeviceDeleteHandler = struct {
    store: *DeviceStore,

    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return deviceDeleteHandler(ctx, res, self.store);
    }
};

// ────────────────────────────────────────────────────────────────────────────
// 辅助函数
// ────────────────────────────────────────────────────────────────────────────

fn parseId(ctx: *framework.Context, res: *framework.Response) ?u64 {
    const id_str = ctx.param("id") orelse {
        ctx.failWith(res, framework.AppError.badRequest("missing :id")) catch {};
        return null;
    };
    return std.fmt.parseInt(u64, id_str, 10) catch {
        ctx.failWith(res, framework.AppError.badRequest("id must be an integer")) catch {};
        return null;
    };
}

// ────────────────────────────────────────────────────────────────────────────
// 测试
// ────────────────────────────────────────────────────────────────────────────

test "DeviceType enum" {
    try std.testing.expectEqual(DeviceType.sensor, DeviceType.fromString("sensor").?);
    try std.testing.expectEqual(DeviceType.actuator, DeviceType.fromString("actuator").?);
    try std.testing.expectEqual(DeviceType.gateway, DeviceType.fromString("gateway").?);
    try std.testing.expectEqual(DeviceType.controller, DeviceType.fromString("controller").?);
    try std.testing.expectEqual(@as(?DeviceType, null), DeviceType.fromString("invalid"));
}

test "DeviceStatus enum" {
    try std.testing.expectEqual(DeviceStatus.online, DeviceStatus.fromString("online").?);
    try std.testing.expectEqual(DeviceStatus.offline, DeviceStatus.fromString("offline").?);
    try std.testing.expectEqual(DeviceStatus.maintenance, DeviceStatus.fromString("maintenance").?);
    try std.testing.expectEqual(DeviceStatus.error_status, DeviceStatus.fromString("error").?);
    try std.testing.expectEqual(@as(?DeviceStatus, null), DeviceStatus.fromString("invalid"));
}
