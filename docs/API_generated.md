# Public API signature inventory

## http_protocol

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `ConnectionLoop` | src/http_protocol/conn_loop.zig:15 | `const ConnectionLoop = struct` |
| `Request` | src/http_protocol/request.zig:25 | `const Request = struct` |
| `urlDecode` | src/http_protocol/request.zig:462 | `fn urlDecode(allocator: mem.Allocator, s: []const u8) ![]const u8` |
| `urlDecodePath` | src/http_protocol/request.zig:470 | `fn urlDecodePath(allocator: mem.Allocator, s: []const u8) ![]const u8` |
| `Sink` | src/http_protocol/response.zig:20 | `const Sink = struct` |
| `Cookie` | src/http_protocol/response.zig:134 | `const Cookie = struct` |
| `Response` | src/http_protocol/response.zig:145 | `const Response = struct` |

## http_app

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `Arenas` | src/http_app/arena.zig:15 | `const Arenas = struct` |
| `applyEnv` | src/http_app/config.zig:79 | `fn applyEnv(comptime T: type, target: *T, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, comptime prefix: []const u8,) EnvError!void` |
| `Config` | src/http_app/config.zig:102 | `const Config = struct` |
| `NetworkConfig` | src/http_app/config.zig:206 | `const NetworkConfig = struct` |
| `HttpConfig` | src/http_app/config.zig:226 | `const HttpConfig = struct` |
| `BodyConfig` | src/http_app/config.zig:240 | `const BodyConfig = struct` |
| `PoolConfig` | src/http_app/config.zig:248 | `const PoolConfig = struct` |
| `RuntimeState` | src/http_app/config.zig:255 | `const RuntimeState = struct` |
| `ServerStats` | src/http_app/config.zig:263 | `const ServerStats = struct` |
| `Hijack` | src/http_app/context.zig:30 | `const Hijack = struct` |
| `PathParams` | src/http_app/context.zig:49 | `const PathParams = struct` |
| `RequestState` | src/http_app/context.zig:103 | `const RequestState = struct` |
| `UserData` | src/http_app/context.zig:178 | `const UserData = struct` |
| `RequestConfig` | src/http_app/context.zig:186 | `const RequestConfig = struct` |
| `Context` | src/http_app/context.zig:193 | `const Context = struct` |
| `AppError` | src/http_app/error.zig:15 | `const AppError = struct` |
| `ErrorRenderer` | src/http_app/error.zig:101 | `const ErrorRenderer = struct` |
| `Handler` | src/http_app/handler.zig:20 | `const Handler = union` |
| `Event` | src/http_app/lifecycle.zig:14 | `const Event = enum` |
| `EventData` | src/http_app/lifecycle.zig:23 | `const EventData = struct` |
| `Hook` | src/http_app/lifecycle.zig:34 | `const Hook = struct` |
| `Lifecycle` | src/http_app/lifecycle.zig:49 | `const Lifecycle = struct` |
| `Next` | src/http_app/middleware.zig:40 | `const Next = struct` |
| `Middleware` | src/http_app/middleware.zig:67 | `const Middleware = struct` |
| `DynPipeline` | src/http_app/middleware.zig:157 | `const DynPipeline = struct` |
| `Pipeline` | src/http_app/middleware.zig:198 | `fn Pipeline(comptime N: usize) type` |
| `RequestId` | src/http_app/request_id.zig:29 | `const RequestId = struct` |
| `RequestIdMiddleware` | src/http_app/request_id.zig:38 | `const RequestIdMiddleware = struct` |
| `Services` | src/http_app/services.zig:20 | `const Services = struct` |

## http_router

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `RouteGroup` | src/http_router/router.zig:57 | `const RouteGroup = struct` |
| `Router` | src/http_router/router.zig:136 | `const Router = struct` |
| `Route` | src/http_router/trie.zig:25 | `const Route = struct` |
| `Trie` | src/http_router/trie.zig:54 | `const Trie = struct` |

## http_server

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `ConnectionRunner` | src/http_server/connection.zig:24 | `const ConnectionRunner = struct` |
| `run` | src/http_server/zio_server.zig:21 | `fn run(allocator: std.mem.Allocator, comptime appFn: fn (std.Io, std.mem.Allocator) anyerror!void,) !void` |
| `Server` | src/http_server/zio_server.zig:66 | `const Server = struct` |

## http_security

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `AuthStrategy` | src/http_security/auth.zig:20 | `const AuthStrategy = enum` |
| `AuthInfo` | src/http_security/auth.zig:29 | `const AuthInfo = struct` |
| `Identity` | src/http_security/auth.zig:42 | `const Identity = struct` |
| `IdentityResolver` | src/http_security/auth.zig:58 | `const IdentityResolver = struct` |
| `AuthConfig` | src/http_security/auth.zig:64 | `const AuthConfig = struct` |
| `AuthMiddleware` | src/http_security/auth.zig:88 | `const AuthMiddleware = struct` |
| `CorsConfig` | src/http_security/cors.zig:17 | `const CorsConfig = struct` |
| `CorsMiddleware` | src/http_security/cors.zig:33 | `const CorsMiddleware = struct` |
| `CsrfConfig` | src/http_security/csrf.zig:24 | `const CsrfConfig = struct` |
| `CsrfMiddleware` | src/http_security/csrf.zig:36 | `const CsrfMiddleware = struct` |
| `constantTimeEql` | src/http_security/root.zig:39 | `fn constantTimeEql(a: []const u8, b: []const u8) bool` |
| `SecurityHeadersConfig` | src/http_security/security_headers.zig:11 | `const SecurityHeadersConfig = struct` |
| `SecurityHeaders` | src/http_security/security_headers.zig:24 | `const SecurityHeaders = struct` |

## http_session

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `SessionConfig` | src/http_session/session.zig:31 | `const SessionConfig = struct` |
| `SessionManager` | src/http_session/session.zig:48 | `const SessionManager = struct` |

## http_rate_limit

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `RateLimitConfig` | src/http_rate_limit/rate_limiter.zig:20 | `const RateLimitConfig = struct` |
| `RateLimiter` | src/http_rate_limit/rate_limiter.zig:54 | `const RateLimiter = struct` |

## http_compress

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `Encoding` | src/http_compress/root.zig:27 | `const Encoding = enum` |
| `CompressConfig` | src/http_compress/root.zig:46 | `const CompressConfig = struct` |
| `CompressMiddleware` | src/http_compress/root.zig:77 | `const CompressMiddleware = struct` |
| `chooseEncoding` | src/http_compress/root.zig:154 | `fn chooseEncoding(accept: []const u8, supported: []const Encoding) ?Encoding` |
| `shouldCompressContentType` | src/http_compress/root.zig:208 | `fn shouldCompressContentType(content_type: []const u8, skip_list: []const []const u8) bool` |
| `initStreamingEncoder` | src/http_compress/root.zig:295 | `fn initStreamingEncoder(encoder: *flate.Compress, out: *std.Io.Writer, hist_buf: []u8, encoding: Encoding, level: flate.Compress.Options,) !void` |

## http_static

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `StaticFileServer` | src/http_static/static.zig:19 | `const StaticFileServer = struct` |
| `formatHttpDateForTest` | src/http_static/static.zig:609 | `fn formatHttpDateForTest(buf: []u8, mtime_ns: i128) ?[]const u8` |

## http_logging

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `Level` | src/http_logging/root.zig:58 | `const Level = enum` |
| `Value` | src/http_logging/root.zig:81 | `const Value = union` |
| `Field` | src/http_logging/root.zig:120 | `const Field = struct` |
| `fstr` | src/http_logging/root.zig:127 | `fn fstr(key: []const u8, val: []const u8) Field` |
| `fint` | src/http_logging/root.zig:130 | `fn fint(key: []const u8, val: i64) Field` |
| `fuint` | src/http_logging/root.zig:133 | `fn fuint(key: []const u8, val: u64) Field` |
| `ffloat` | src/http_logging/root.zig:136 | `fn ffloat(key: []const u8, val: f64) Field` |
| `fbool` | src/http_logging/root.zig:139 | `fn fbool(key: []const u8, val: bool) Field` |
| `fnull` | src/http_logging/root.zig:142 | `fn fnull(key: []const u8) Field` |
| `Format` | src/http_logging/root.zig:147 | `const Format = enum` |
| `Output` | src/http_logging/root.zig:153 | `const Output = enum` |
| `FileOutputConfig` | src/http_logging/root.zig:160 | `const FileOutputConfig = struct` |
| `LoggerConfig` | src/http_logging/root.zig:172 | `const LoggerConfig = struct` |
| `Logger` | src/http_logging/root.zig:190 | `const Logger = struct` |
| `LoggingMiddleware` | src/http_logging/root.zig:693 | `const LoggingMiddleware = struct` |
| `LoggingHook` | src/http_logging/root.zig:734 | `const LoggingHook = struct` |

## http_codec

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `parseJson` | src/http_codec/root.zig:35 | `fn parseJson(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !*T` |
| `JsonBody` | src/http_codec/root.zig:71 | `fn JsonBody(comptime T: type) type` |

## http_multipart

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `FileField` | src/http_multipart/root.zig:29 | `const FileField = struct` |
| `FormData` | src/http_multipart/root.zig:92 | `const FormData = struct` |
| `extractBoundary` | src/http_multipart/root.zig:118 | `fn extractBoundary(content_type: []const u8) ?[]const u8` |
| `from` | src/http_multipart/root.zig:150 | `fn from(ctx: *Context, limit: u64) !FormData` |
| `parseBody` | src/http_multipart/root.zig:174 | `fn parseBody(allocator: std.mem.Allocator, body: []const u8, delimiter: []const u8) !FormData` |

## http_testing

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `Harness` | src/http_testing/root.zig:113 | `const Harness = struct` |

## http_orm

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `JsonStore` | src/http_orm/engine.zig:28 | `fn JsonStore(comptime T: type, comptime schema: TableSchema) type` |
| `fieldTypeOf` | src/http_orm/model.zig:14 | `fn fieldTypeOf(comptime T: type) FieldType` |
| `ModelOptions` | src/http_orm/model.zig:35 | `const ModelOptions = struct` |
| `modelSchema` | src/http_orm/model.zig:166 | `fn modelSchema(comptime T: type, comptime table_name: []const u8) TableSchema` |
| `modelSchemaWith` | src/http_orm/model.zig:171 | `fn modelSchemaWith(comptime T: type, comptime table_name: []const u8, comptime opts: ModelOptions) TableSchema` |
| `Model` | src/http_orm/model.zig:176 | `fn Model(comptime T: type, comptime table_name: []const u8) type` |
| `ModelWith` | src/http_orm/model.zig:188 | `fn ModelWith(comptime T: type, comptime table_name: []const u8, comptime opts: ModelOptions) type` |
| `Operator` | src/http_orm/query.zig:19 | `const Operator = enum` |
| `SortDirection` | src/http_orm/query.zig:50 | `const SortDirection = enum` |
| `QueryType` | src/http_orm/query.zig:56 | `const QueryType = enum` |
| `WhereCondition` | src/http_orm/query.zig:65 | `const WhereCondition = struct` |
| `Logic` | src/http_orm/query.zig:72 | `const Logic = enum` |
| `OrderClause` | src/http_orm/query.zig:78 | `const OrderClause = struct` |
| `QueryBuilder` | src/http_orm/query.zig:84 | `fn QueryBuilder(comptime T: type) type` |
| `getFieldValue` | src/http_orm/query.zig:524 | `fn getFieldValue(comptime T: type, instance: T, field_name: []const u8) FieldValue` |
| `getFieldValueOpt` | src/http_orm/query.zig:531 | `fn getFieldValueOpt(comptime T: type, instance: T, field_name: []const u8) ?FieldValue` |
| `isFieldNull` | src/http_orm/query.zig:552 | `fn isFieldNull(comptime T: type, instance: T, field_name: []const u8) bool` |
| `toFieldValue` | src/http_orm/query.zig:569 | `fn toFieldValue(value: anytype) FieldValue` |
| `setFieldFromValue` | src/http_orm/query.zig:610 | `fn setFieldFromValue(comptime T: type, instance: *T, field_name: []const u8, value: FieldValue) void` |
| `FieldType` | src/http_orm/schema.zig:9 | `const FieldType = enum` |
| `FieldValue` | src/http_orm/schema.zig:33 | `const FieldValue = union` |
| `FieldConstraints` | src/http_orm/schema.zig:44 | `const FieldConstraints = struct` |
| `FieldDef` | src/http_orm/schema.zig:60 | `const FieldDef = struct` |
| `IndexDef` | src/http_orm/schema.zig:67 | `const IndexDef = struct` |
| `TableSchema` | src/http_orm/schema.zig:74 | `const TableSchema = struct` |
| `MigrationOp` | src/http_orm/schema.zig:97 | `const MigrationOp = union` |
| `Migration` | src/http_orm/schema.zig:142 | `const Migration = struct` |

## http_websocket

| 符号 | 文件:行 | 签名 |
| --- | --- | --- |
| `Message` | src/http_websocket/connection.zig:38 | `const Message = struct` |
| `CloseCode` | src/http_websocket/connection.zig:49 | `const CloseCode = enum` |
| `WebSocket` | src/http_websocket/connection.zig:68 | `const WebSocket = struct` |
| `OpCode` | src/http_websocket/frame.zig:41 | `const OpCode = enum` |
| `Frame` | src/http_websocket/frame.zig:66 | `const Frame = struct` |
| `encode` | src/http_websocket/frame.zig:93 | `fn encode(writer: *std.Io.Writer, opcode: OpCode, payload: []const u8, mask: bool, masking_key: [4]u8,) !void` |
| `decode` | src/http_websocket/frame.zig:152 | `fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator, max_payload: usize) !Frame` |
| `applyMask` | src/http_websocket/frame.zig:236 | `fn applyMask(payload: []u8, key: [4]u8) void` |
| `setAllowedOrigins` | src/http_websocket/handshake.zig:63 | `fn setAllowedOrigins(origins: ?[]const []const u8) void` |
| `handshake` | src/http_websocket/handshake.zig:138 | `fn handshake(ctx: *Context, res: *Response) !bool` |
| `computeAcceptKey` | src/http_websocket/handshake.zig:163 | `fn computeAcceptKey(client_key: []const u8, out: *[@This().ACCEPT_KEY_LEN]u8) ![]const u8` |
| `upgrade` | src/http_websocket/handshake.zig:224 | `fn upgrade(ctx: *Context, res: *Response, hijack_ctx: anytype, comptime handlerFn: fn (ws: *connection.WebSocket, user: @TypeOf(hijack_ctx)) anyerror!void,) !bool` |
