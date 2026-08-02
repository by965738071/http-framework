//! Core module entry point — only the basic HTTP server modules.
//! The build system uses this file as `coreMod.root_source_file`.

pub const Logger = @import("logger.zig");
pub const Middleware = @import("middleware.zig");
pub const RequestContext = @import("request.zig");
pub const Response = @import("response.zig");
pub const Router = @import("router.zig");
pub const Server = @import("server.zig");
pub const ConnectionPool = @import("connection_pool.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
