const std = @import("std");
test "decompress api" {
    var out_buf: [100]u8 = undefined;
    var reader = std.Io.Reader.fixed("hello");
    const writer = std.Io.Writer.fixed(&out_buf);
    var cbuf: [100]u8 = undefined;
    const Container = std.compress.flate.Container;
    const info = @typeInfo(Container);
    std.debug.print("Container kind: {}\n", .{info});
}
