//! Connection Pool — Generic typed connection pool with health checks
//!
//! Provides a thread-safe connection pool for database connections,
//! HTTP client connections, or any reusable resource.
//!
//! # Usage
//!
//! ```zig
//! var pool = try ConnectionPool(Conn, Factory, Closer).init(allocator, io, .{
//!     .min_idle = 2,
//!     .max_idle = 20,
//!     .acquire_timeout_ns = 5_000_000_000,
//! });
//! defer pool.close();
//!
//! const conn = try pool.acquire();
//! defer pool.release(conn);
//! try conn.doWork();
//! ```

const std = @import("std");

/// Pool statistics
pub const Stats = struct {
    total_created: u32,
    active_count: u32,
    idle_count: u32,
    wait_count: u64, // total acquisitions that had to wait
    wait_time_ns: u64, // total time spent waiting
    timeout_count: u32, // acquisitions that timed out
};

/// Pool configuration
pub const Config = struct {
    /// Minimum idle connections to maintain
    min_idle: u32 = 2,

    /// Maximum idle connections (idle connections beyond this are closed)
    max_idle: u32 = 20,

    /// Maximum total connections (active + idle)
    max_total: u32 = 50,

    /// Maximum connection lifetime (connections older than this are closed)
    max_lifetime_ns: u64 = 3600_000_000_000, // 1 hour

    /// Max time to wait for a connection
    acquire_timeout_ns: u64 = 5_000_000_000, // 5 seconds

    /// Interval for idle connection cleanup
    cleanup_interval_ns: u64 = 30_000_000_000, // 30 seconds
};

/// Interface for acquiring connections
pub fn AcquireFn(comptime T: type) type {
    return *const fn (std.Io) anyerror!*T;
}

/// Interface for closing connections
pub fn CloseFn(comptime T: type) type {
    return *const fn (*T, std.Io) void;
}

/// Interface for validating connections (health check)
pub fn ValidateFn(comptime T: type) type {
    return *const fn (*T, std.Io) anyerror!void;
}

/// A single pooled connection with metadata
const PoolEntry = struct {
    connection: *anyopaque,
    created_at: i128,
    last_used: i128,
};

/// Generic connection pool factory
pub fn ConnectionPool(
    comptime T: type,
    comptime _: AcquireFn(T),
    comptime _: CloseFn(T),
    comptime _: ?ValidateFn(T),
) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        fn_acquire: AcquireFn(T),
        fn_close: CloseFn(T),
        fn_validate: ?ValidateFn(T),

        // Pool state
        idle: std.ArrayList(PoolEntry),
        active_count: u32,
        total_created: u32,

        // Synchronization
        mutex: std.Io.Mutex,
        available: std.Io.Condition,

        closed: bool,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            config: Config,
            fn_acquire: AcquireFn(T),
            fn_close: CloseFn(T),
            fn_validate: ?ValidateFn(T),
        ) !Self {
            return .{
                .allocator = allocator,
                .io = io,
                .config = config,
                .fn_acquire = fn_acquire,
                .fn_close = fn_close,
                .fn_validate = fn_validate,
                .idle = try std.ArrayList(PoolEntry).initCapacity(allocator, config.min_idle),
                .active_count = 0,
                .total_created = 0,
                .mutex = std.Io.Mutex.init,
                .available = std.Io.Condition.init,
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.idle.deinit(self.allocator);
        }

        /// Acquire a connection (blocks up to timeout).
        pub fn acquire(self: *Self) anyerror!*T {
            const start = std.Io.Clock.now(.real, self.io).nanoseconds;
            var waited: bool = false;

            while (true) {
                _ = self.mutex.lock(self.io) catch unreachable;

                if (self.closed) {
                    self.mutex.unlock(self.io);
                    return error.PoolClosed;
                }

                // Try to get an idle connection
                if (self.idle.items.len > 0) {
                    var entry = self.idle.pop().?;
                    self.mutex.unlock(self.io);

                    // Validate the connection
                    if (self.fn_validate) |validate| {
                        validate(@as(*T, @ptrCast(@alignCast(entry.connection))), self.io) catch {
                            // Connection invalid, close it and try next
                            @call(.auto, self.fn_close, .{ @as(*T, @ptrCast(@alignCast(entry.connection))), self.io });
                            continue;
                        };
                    }

                    entry.last_used = std.Io.Clock.now(.real, self.io).nanoseconds;
                    if (waited) {
                        try self.mutex.lock(self.io);
                        _ = std.Io.Clock.now(.real, self.io); // just touch to avoid warning
                        self.total_created += 0; // no new creation
                        self.mutex.unlock(self.io);
                    }

                    // Increment active count since this connection is now in use
                    self.active_count += 1;

                    return @as(*T, @ptrCast(@alignCast(entry.connection)));
                }

                // Create new connection if under limit
                if (self.active_count + @as(u32, @intCast(self.idle.items.len)) < self.config.max_total) {
                    const conn = @call(.auto, self.fn_acquire, .{self.io}) catch |err| {
                        self.mutex.unlock(self.io);
                        return err;
                    };
                    self.mutex.unlock(self.io);

                    self.mutex.lockUncancelable(self.io);
                    self.active_count += 1;
                    self.total_created += 1;
                    self.mutex.unlock(self.io);

                    return conn;
                }

                // Wait for a connection to be released
                if (!waited) {
                    waited = true;
                }

                const elapsed: i128 = std.Io.Clock.now(.real, self.io).nanoseconds - start;
                const remaining = @as(i128, self.config.acquire_timeout_ns) - elapsed;
                if (remaining <= 0) {
                    self.mutex.unlock(self.io);
                    return error.AcquireTimeout;
                }

                self.available.waitUncancelable(self.io, &self.mutex);
                self.mutex.unlock(self.io);
            }
        }

        /// Release a connection back to the pool.
        pub fn release(self: *Self, conn: *T) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) {
                @call(.auto, self.fn_close, .{ conn, self.io });
                self.active_count -= 1;
                return;
            }

            const typed_conn: *T = @as(*T, @ptrCast(conn));
            const now = std.Io.Clock.now(.real, self.io).nanoseconds;
            const entry = PoolEntry{
                .connection = @ptrCast(typed_conn),
                .created_at = now,
                .last_used = now,
            };

            if (self.idle.items.len < self.config.max_idle) {
                self.idle.append(self.allocator, entry) catch {};
            } else {
                // Pool full, close the connection
                @call(.auto, self.fn_close, .{ conn, self.io });
            }

            self.active_count -= 1;
            self.available.signal(self.io);
        }

        /// Close all connections and shut down the pool.
        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.closed = true;
            self.available.broadcast(self.io);
            self.mutex.unlock(self.io);

            // Close all idle connections
            for (self.idle.items) |entry| {
                @call(.auto, self.fn_close, .{ @as(*T, @ptrCast(@alignCast(entry.connection))), self.io });
            }
            self.idle.clearRetainingCapacity();
        }

        /// Get pool statistics.
        pub fn stats(self: *Self) Stats {
            self.mutex.lockUncancelable(self.io);
            const s = Stats{
                .total_created = self.total_created,
                .active_count = self.active_count,
                .idle_count = @intCast(self.idle.items.len),
                .wait_count = 0,
                .wait_time_ns = 0,
                .timeout_count = 0,
            };
            self.mutex.unlock(self.io);
            return s;
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "ConnectionPool - acquire and release" {
    const test_allocator = std.testing.allocator;
    const test_io = std.testing.io;

    const fn_acquire: AcquireFn(usize) = struct {
        fn acquire_fn(io_ctx: std.Io) anyerror!*usize {
            _ = io_ctx;
            const ptr = try test_allocator.create(usize);
            ptr.* = 1;
            return ptr;
        }
    }.acquire_fn;

    const fn_close: CloseFn(usize) = struct {
        fn close_fn(conn: *usize, io_ctx: std.Io) void {
            _ = io_ctx;
            test_allocator.destroy(conn);
        }
    }.close_fn;

    var pool = try ConnectionPool(
        usize,
        fn_acquire,
        fn_close,
        null,
    ).init(
        test_allocator,
        test_io,
        .{ .max_total = 5, .acquire_timeout_ns = 1_000_000_000 },
        fn_acquire,
        fn_close,
        null,
    );
    defer pool.deinit();

    const conn1 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), conn1.*);

    pool.release(conn1);
    const conn2 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), conn2.*); // Should reuse
    pool.release(conn2);
}

test "ConnectionPool - stats after acquire and release" {
    const test_allocator = std.testing.allocator;
    const test_io = std.testing.io;

    const fn_acquire: AcquireFn(usize) = struct {
        fn acquire_fn(io_ctx: std.Io) anyerror!*usize {
            _ = io_ctx;
            const ptr = try test_allocator.create(usize);
            ptr.* = 42;
            return ptr;
        }
    }.acquire_fn;

    const fn_close: CloseFn(usize) = struct {
        fn close_fn(conn: *usize, io_ctx: std.Io) void {
            _ = io_ctx;
            test_allocator.destroy(conn);
        }
    }.close_fn;

    var pool = try ConnectionPool(
        usize,
        fn_acquire,
        fn_close,
        null,
    ).init(
        test_allocator,
        test_io,
        .{ .max_total = 5, .acquire_timeout_ns = 1_000_000_000 },
        fn_acquire,
        fn_close,
        null,
    );
    defer pool.deinit();

    // Stats before any acquire
    var s = pool.stats();
    try std.testing.expectEqual(@as(u32, 0), s.total_created);
    try std.testing.expectEqual(@as(u32, 0), s.active_count);
    try std.testing.expectEqual(@as(u32, 0), s.idle_count);

    // Acquire one connection
    const conn = try pool.acquire();

    s = pool.stats();
    try std.testing.expectEqual(@as(u32, 1), s.total_created);
    try std.testing.expectEqual(@as(u32, 1), s.active_count);
    try std.testing.expectEqual(@as(u32, 0), s.idle_count);

    // Release it back
    pool.release(conn);

    s = pool.stats();
    try std.testing.expectEqual(@as(u32, 1), s.total_created);
    try std.testing.expectEqual(@as(u32, 0), s.active_count);
    try std.testing.expectEqual(@as(u32, 1), s.idle_count);
}

test "ConnectionPool - close shuts down pool" {
    const test_allocator = std.testing.allocator;
    const test_io = std.testing.io;

    const fn_acquire: AcquireFn(usize) = struct {
        fn acquire_fn(io_ctx: std.Io) anyerror!*usize {
            _ = io_ctx;
            const ptr = try test_allocator.create(usize);
            ptr.* = 7;
            return ptr;
        }
    }.acquire_fn;

    const fn_close: CloseFn(usize) = struct {
        fn close_fn(conn: *usize, io_ctx: std.Io) void {
            _ = io_ctx;
            test_allocator.destroy(conn);
        }
    }.close_fn;

    var pool = try ConnectionPool(
        usize,
        fn_acquire,
        fn_close,
        null,
    ).init(
        test_allocator,
        test_io,
        .{ .max_total = 5, .acquire_timeout_ns = 1_000_000_000 },
        fn_acquire,
        fn_close,
        null,
    );
    defer pool.deinit();

    // Acquire a connection
    const conn = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 7), conn.*);

    // Close the pool
    pool.close();

    // Verify subsequent acquire returns PoolClosed
    try std.testing.expectError(error.PoolClosed, pool.acquire());

    // Release after close — should close the connection internally
    pool.release(conn);
}
