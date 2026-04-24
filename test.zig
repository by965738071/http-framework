const std = @import("std");

fn async_fn(io: std.Io, i: usize) usize {
    io.sleep(.fromSeconds(@intCast(i)), .awake) catch {};
    return i;
}

const MyUnion = union(enum) {
    first: usize,
    second: usize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [256]MyUnion = undefined;
    var select = std.Io.Select(MyUnion).init(io, &buffer);
    defer {
        const a = select.cancel();
        if (a) |b| {
            std.debug.print("cancel: {}\n", .{b});
        }
    }
     select.async(.first, async_fn, .{ io, 1 });
    select.async(.first, async_fn, .{ io, 10 });
   

    const selected = switch (try select.await()) {
        .first => |x| x,
        .second => |x| x,
    };
    std.debug.print("{}\n", .{selected});
}
