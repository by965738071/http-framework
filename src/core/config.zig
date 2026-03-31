const std = @import("std");
allocator: std.mem.Allocator,

address: std.Io.net.IpAddress,

const Self = @This();

pub fn parse(text: []const u8) !Self {
    const colon_pos = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidConfig;
    const ip = text[0..colon_pos];
    const port = try std.fmt.parseInt(u16, text[colon_pos + 1 ..], 10);
    return .{ .address = .{ .ip4 = .parse(ip, port) } };
}
