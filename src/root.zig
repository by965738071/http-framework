//! `http_framework` — 新架构伞形聚合模块
//!
//! 一次 `@import("http_framework")` 拿到全部能力。
//!
//! # 新架构 4 层
//!
//! ```text
//! http_protocol   字节 ↔ 报文（Request/Response/ConnectionLoop）
//! http_app        生命周期 + 管道（Context/Handler/Middleware/AppError/Config/Lifecycle）
//! http_router     radix trie 路由（Router/Trie）
//! http_framework   字节 ↔ 报文（Request/Response/ConnectionLoop）
//! http_app        生命周期 + 管道（Context/Handler/Middleware/AppError/Config/Lifecycle）
//! http_router     radix trie 路由（Router/Trie）
//! http_server     组装（zio_server + 后端无关的 ConnectionRunner）
//! ```
//!
//! 回应 bug.md §1：core 不再是一个"最小核心"扴 5 层职责。
//! 回应 bug.md §6：模块图是 DAG，不是星形。

pub const http_protocol = @import("http_protocol");
pub const http_app = @import("http_app");
pub const http_router = @import("http_router");
pub const http_server = @import("http_server");
pub const http_security = @import("http_security");
pub const http_session = @import("http_session");
pub const http_rate_limit = @import("http_rate_limit");
pub const http_static = @import("http_static");
pub const http_codec = @import("http_codec");
pub const http_multipart = @import("http_multipart");
pub const http_compress = @import("http_compress");
pub const http_logging = @import("http_logging");
pub const orm = @import("http_orm");
pub const http_websocket = @import("http_websocket");

// ── http_protocol ──────────────────────────────────────────────
pub const Request = http_protocol.Request;
pub const Response = http_protocol.Response;
pub const Cookie = http_protocol.Cookie;
pub const Sink = http_protocol.Sink;
pub const ConnectionLoop = http_protocol.ConnectionLoop;
pub const BodyReader = http_protocol.BodyReader;

// ── http_app ──────────────────────────────────────────────────
pub const Context = http_app.Context;
pub const RequestState = http_app.RequestState;
pub const RequestConfig = http_app.RequestConfig;
pub const Handler = http_app.Handler;
pub const Middleware = http_app.Middleware;
pub const Next = http_app.Next;
pub const DynPipeline = http_app.DynPipeline;
pub const Pipeline = http_app.Pipeline;
pub const AppError = http_app.AppError;
pub const ErrorRenderer = http_app.ErrorRenderer;
pub const RequestId = http_app.RequestId;
pub const RequestIdMiddleware = http_app.RequestIdMiddleware;
pub const REQUEST_ID_HEADER = http_app.REQUEST_ID_HEADER;
pub const Config = http_app.Config;
pub const NetworkConfig = http_app.NetworkConfig;
pub const HttpConfig = http_app.HttpConfig;
pub const BodyConfig = http_app.BodyConfig;
pub const PoolConfig = http_app.PoolConfig;
pub const RuntimeState = http_app.RuntimeState;
pub const ServerStats = http_app.ServerStats;
pub const Event = http_app.Event;
pub const EventData = http_app.EventData;
pub const Hook = http_app.Hook;
pub const Lifecycle = http_app.Lifecycle;
pub const Arenas = http_app.Arenas;
pub const Services = http_app.Services;

// ── http_router ──────────────────────────────────────────────
pub const Router = http_router.Router;
pub const Trie = http_router.Trie;
pub const RouteGroup = http_router.RouteGroup;

// ── http_server ──────────────────────────────────────────────
// ── http_server（默认 zio 后端）────────────────────────
pub const Server = http_server.Server;
pub const ConnectionRunner = http_server.ConnectionRunner;
/// 启动 zio 运行时并在其协程上下文中运行 app（io, allocator）。
pub const runZio = http_server.runZio;

// ── http_security ─────────────────────────────────────────────
pub const CsrfMiddleware = http_security.csrf.CsrfMiddleware;
pub const CsrfConfig = http_security.csrf.CsrfConfig;
pub const AuthMiddleware = http_security.auth.AuthMiddleware;
pub const AuthConfig = http_security.auth.AuthConfig;
pub const AuthInfo = http_security.auth.AuthInfo;
pub const AuthStrategy = http_security.auth.AuthStrategy;
pub const CorsMiddleware = http_security.cors.CorsMiddleware;
pub const CorsConfig = http_security.cors.CorsConfig;
pub const SecurityHeaders = http_security.security_headers.SecurityHeaders;
pub const SecurityHeadersConfig = http_security.security_headers.SecurityHeadersConfig;
pub const constantTimeEql = http_security.constantTimeEql;

// ── http_session ───────────────────────────────────────────────
pub const SessionManager = http_session.SessionManager;
pub const SessionConfig = http_session.SessionConfig;
pub const SessionData = http_session.SessionData;

// ── http_rate_limit ───────────────────────────────────────────
pub const RateLimiter = http_rate_limit.RateLimiter;
pub const RateLimitConfig = http_rate_limit.RateLimitConfig;

// ── http_static ───────────────────────────────────────────────
pub const StaticFileServer = http_static.StaticFileServer;

// ── http_codec ────────────────────────────────────────────────
pub const parseJson = http_codec.parseJson;
pub const JsonBody = http_codec.JsonBody;

// ── http_multipart ───────────────────────────────────────────
pub const FormData = http_multipart.FormData;
pub const FileField = http_multipart.FileField;
pub const multipartFrom = http_multipart.from;
pub const parseMultipart = http_multipart.parseBody;
pub const extractBoundary = http_multipart.extractBoundary;

// ── http_compress ─────────────────────────────────────────────
pub const CompressMiddleware = http_compress.CompressMiddleware;
pub const CompressConfig = http_compress.CompressConfig;
pub const CompressEncoding = http_compress.Encoding;
pub const initStreamingEncoder = http_compress.initStreamingEncoder;
pub const chooseCompressEncoding = http_compress.chooseEncoding;
pub const shouldCompressContentType = http_compress.shouldCompressContentType;

// ── http_logging ───────────────────────────────────────────────
pub const Logger = http_logging.Logger;
pub const LoggerConfig = http_logging.LoggerConfig;
pub const FileOutputConfig = http_logging.FileOutputConfig;
pub const LogLevel = http_logging.Level;
pub const LogField = http_logging.Field;
pub const LogValue = http_logging.Value;
pub const LogFormat = http_logging.Format;
pub const LogOutput = http_logging.Output;
pub const LoggingMiddleware = http_logging.LoggingMiddleware;
pub const LoggingHook = http_logging.LoggingHook;
pub const fstr = http_logging.fstr;
pub const fint = http_logging.fint;
pub const fuint = http_logging.fuint;
pub const ffloat = http_logging.ffloat;
pub const fbool = http_logging.fbool;
pub const fnull = http_logging.fnull;

// ── http_orm ────────────────────────────────────────────────────
pub const JsonStore = orm.JsonStore;
pub const Model = orm.Model;
pub const Query = orm.Query;
pub const TableSchema = orm.TableSchema;
pub const FieldDef = orm.FieldDef;
pub const FieldType = orm.FieldType;
pub const FieldValue = orm.FieldValue;
pub const FieldConstraints = orm.FieldConstraints;
pub const Operator = orm.Operator;
pub const SortDirection = orm.SortDirection;
pub const WhereCondition = orm.WhereCondition;

// ── http_websocket ──────────────────────────────────────────────
pub const WebSocket = http_websocket.WebSocket;
pub const WsMessage = http_websocket.Message;
pub const WsFrame = http_websocket.Frame;
pub const OpCode = http_websocket.OpCode;
pub const CloseCode = http_websocket.CloseCode;
pub const wsHandshake = http_websocket.handshake;
pub const wsUpgrade = http_websocket.upgrade;
pub const wsComputeAcceptKey = http_websocket.computeAcceptKey;
pub const wsEncodeFrame = http_websocket.encode;
pub const wsDecodeFrame = http_websocket.decode;

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
