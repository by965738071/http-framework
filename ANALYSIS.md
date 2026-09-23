# HTTP Framework 架构分析与改进报告

## 一、项目概述

本项目是一个基于 Zig 语言的高性能、轻量级 HTTP 服务器框架。框架主体构建在标准 `std.Io` 接口之上，运行在 [zio](https://github.com/lalinsky/zio) 异步运行时（Linux io_uring / macOS kqueue / Windows IOCP + 协程）上，实现跨平台统一异步 I/O。

框架采用 **4 层核心 + addon 扩展** 的分层架构：

- **core 最小化**：4 层核心只做 HTTP 协议解析、应用抽象、路由和服务器组装，不包含 session、ORM、WebSocket 等业务能力。
- **能力 addon 化**：所有业务扩展能力（鉴权、会话、限流、压缩、日志、ORM、WebSocket 等）以独立 addon 模块形式存在，单向依赖核心层，按需引入。
- **后端可替换**：框架核心只依赖 `std.Io` 接口，与具体异步运行时绑定的代码隔离在单一文件（`zio_server.zig`），未来更换运行时只需新增一个文件，公共逻辑不改。

**性能表现**（macOS, ReleaseFast）：

| 指标 | 数值 |
|------|------|
| 端到端 QPS（200 并发） | ~38,000 req/s |
| P50 延迟 | 0.64 ms |
| 框架内部微基准（静态路由） | ~8.1M ops/s, ~123 ns/op |
| 框架内部微基准（参数路由） | ~7.5M ops/s, ~133 ns/op |

**代码规模**：核心 4 层约 7,900 行，addon 约 13,900 行，总计约 21,800 行（含测试）。

## 二、架构分析

### 2.1 分层设计

框架采用严格的 DAG（有向无环图）模块依赖图，而非传统的星形依赖（所有 addon 直接依赖单一 core）。依赖方向由 `build.zig` 模块边界在编译期强制保证：

```
http_protocol  (零依赖)
    ↑
http_app       → http_protocol
    ↑
http_router    → http_app, http_protocol
    ↑
http_server    → http_router, http_app, http_protocol, zio

Addons（依赖 http_app / http_protocol，可互相依赖）：
  http_security   → http_app, http_protocol
  http_session    → http_app, http_protocol
  http_rate_limit → http_app, http_protocol
  http_compress   → http_app, http_protocol
  http_static     → http_app, http_protocol, http_compress
  http_logging    → http_app, http_protocol
  http_codec      → http_app, http_protocol
  http_multipart  → http_app, http_protocol
  http_testing    → http_app, http_protocol
  http_orm        (零依赖，独立 addon)
  http_websocket  → http_app, http_protocol

http_framework → 以上全部（伞形聚合模块）
```

这种 DAG 设计的关键优势：
1. **addon 之间可以互相依赖**（如 `http_static` 依赖 `http_compress`），不需要绕道 core
2. **编译期隔离**：模块边界由 `build.zig` 强制，错误方向的 `@import` 会在编译期失败
3. **按需引入**：用户可以只依赖核心 4 层，或选择性引入 addon，不需要全量依赖

### 2.2 核心模块

#### http_protocol（零依赖协议层）

**职责**：字节 ↔ 报文转换，是最底层的模块。

**核心组件**：
- `Request`：不可变的请求解析结果（方法、路径、查询字符串、头部、Cookie）
- `Response`：响应构建器（只持 Writer，不持 Server.Request 句柄）
- `BodyReader`：请求体读取（支持 Content-Length 与 chunked）
- `ConnectionLoop`：keep-alive 连接状态机
- `urlDecode` / `urlDecodePath`：共享的 percent/form-urlencoded 解码器

**设计要点**：
- 零依赖：不依赖任何其他框架模块，可独立使用
- `Response` 只持 Writer 不持连接句柄，解耦了协议层与传输层
- `ConnectionLoop` 作为独立状态机，将 keep-alive 逻辑从服务器层提取出来

#### http_app（应用层抽象）

**职责**：定义框架的核心抽象——生命周期管理、管道、配置。

**核心组件**：
- `Context`：拆分后的请求上下文（Request + RequestState + RequestConfig），包含 `param`/`query`/`header`/`readBody`/`service`/`arena`/`failWith`/`getUserData` 等方法
- `Handler`：`union(enum)` 替代传统 vtable，三种模式——`fromFn`（纯函数）、`initSingleton`（单例）、`initFactory`（请求级）
- `Middleware`：经典 `process(ctx, res, next)` 管道模型，支持前置/后置/缓冲模式
- `AppError`：错误是一等公民（状态码 + 消息），`ErrorRenderer` 渲染
- `Config`：分层配置（network / http / body / pool）+ 环境变量加载（`fromEnv` / `applyEnv`）
- `Lifecycle`：统一生命周期钩子（`Hook` / `Event` / `EventData`）
- `Arenas`：两级 arena（请求级 + 连接级），请求级 arena 池化复用
- `Services`：应用级服务容器（`register`/`seal`/`service(T)`），脱离全局变量

**设计要点**：
- `Handler` 用 `union(enum)` 替代 vtable：编译期已知调用路径，零间接调用的纯函数模式、单次间接的单例模式、请求级 create/destroy 的工厂模式
- `Context` 拆分了不可变 `Request` 和可变 `RequestState`，职责清晰
- 错误处理不是 throw-and-catch 的附庸：`AppError` 是结构化的，`ErrorRenderer` 是管道最外层兜底
- `Services` 容器支持 `seal()` 封箱，启动后注册返回 `error.ServicesSealed`

#### http_router（路由层）

**职责**：radix trie 路由引擎。

**核心组件**：
- `Trie`：radix trie 数据结构，支持 `:param` 路径参数与 `*` 通配符匹配
- `Router`：路由注册与派发（`route` / `use` / `notFound` / `dispatch`）
- `RouteGroup`：路由分组（组级中间件叠加）

**设计要点**：
- O(路径段数) 匹配，而非线性扫描
- 前缀共享，注册时做静态冲突检测
- HEAD 自动回退到 GET handler
- 405 带 `Allow` 头列出可用方法
- 组级中间件叠加，不影响全局管道

#### http_server（服务器层）

**职责**：组装层，将路由、中间件、连接管理组合成可运行的服务器。

**核心组件**：
- `ConnectionRunner`（`connection.zig`）：**后端无关**的纯 HTTP 引擎——只依赖 `std.Io.Reader/Writer`，跑 HTTP 状态机 + router + 中间件 + dispatch
- `Server`（`zio_server.zig`）：**zio 专属**——监听/accept/背压/信号/关机/连接读写/运行时启动
- `runZio`：启动 zio 运行时并在其协程上下文中运行应用

**设计要点**：
- 后端无关的 `ConnectionRunner` 与运行时绑定的 `zio_server` 分离：换运行时只需新增一个 `xxx_server.zig`，复用 `ConnectionRunner`
- `zio_server.zig` 是唯一 `@import("zio")` 的文件，依赖隔离做到极致
- 优雅关闭：zio.Signal 同时处理 SIGINT 与 SIGTERM → 取消 accept → drain 在途连接

### 2.3 Addon 扩展机制

框架的所有业务扩展能力都以独立 addon 模块形式存在，每个 addon 职责单一，单向依赖核心层：

| Addon | 职责 | 依赖 |
|-------|------|------|
| `http_security` | 鉴权（Bearer/Basic/API Key/自定义 resolver）、CORS（预检/Vary）、CSRF（双提交）、安全响应头 | http_app, http_protocol |
| `http_session` | 基于 Cookie 的内存 Session 存储（`std.Io.Mutex` 保护） | http_app, http_protocol |
| `http_rate_limit` | 速率限制（窗口计数、429 + Retry-After/X-RateLimit-*） | http_app, http_protocol |
| `http_compress` | 响应压缩（gzip/deflate 流式，q 值协商） | http_app, http_protocol |
| `http_static` | 静态文件服务（路径遍历防护、ETag/304/HEAD/gzip/目录 index） | http_app, http_protocol, http_compress |
| `http_codec` | JSON body 解析（`parseJson` 自由函数） | http_app, http_protocol |
| `http_multipart` | multipart/form-data 解析（文件上传、字段提取） | http_app, http_protocol |
| `http_logging` | 结构化日志（JSON/文本、文件轮转、O_APPEND 快路径） | http_app, http_protocol |
| `http_orm` | JSON 文件持久化 ORM（编译期反射表结构、CRUD、查询、分页） | 零依赖（独立） |
| `http_websocket` | WebSocket RFC 6455（握手 + 帧编解码 + 连接劫持） | http_app, http_protocol |
| `http_testing` | 离线测试 harness（驱动中间件 + handler，不走真实 TCP） | http_app, http_protocol |

**addon 互相依赖的实例**：`http_static` 依赖 `http_compress`（静态文件需要 gzip 压缩能力），这是 DAG 设计优于星形依赖的直接体现——不需要把压缩能力塞进 core。

### 2.4 架构亮点

1. **DAG 依赖图（非星形）**
   - 传统框架的 addon 全部直接依赖一个"核心大杂烩"模块，导致核心膨胀。
   - 本框架的 addon 可以互相依赖（如 `http_static` → `http_compress`），依赖关系由 `build.zig` 在编译期强制。
   - 效果：addon 之间组合自由，core 不膨胀。

2. **core 最小化 + addon 扩展**
   - core（4 层）只做：协议解析、应用抽象、路由、服务器组装。
   - session、鉴权、压缩、日志、ORM、WebSocket 等全部是 addon。
   - 效果：不需要的能力不会进入编译，二进制体积最小化。

3. **后端无关 ConnectionRunner**
   - `ConnectionRunner` 只依赖 `std.Io.Reader/Writer`，不含任何运行时特定代码。
   - `zio_server.zig` 是唯一 `@import("zio")` 的文件。
   - 效果：换运行时（如 future `io_uring` 直连或 `epoll` 直连）只需新增一个 `xxx_server.zig`，公共逻辑不改。

4. **Handler `union(enum)` 替代 vtable**
   - 三种模式（纯函数/单例/工厂）用 `union(enum)` 标签，编译期已知调用路径。
   - 纯函数模式零间接调用，单例模式仅一次间接调用。
   - 效果：框架开销趋近于零，微基准 ~123 ns/op（含 trie 匹配 + 3 层中间件 + handler + 响应构建）。

5. **错误一等公民**
   - `AppError`（状态码 + 消息）是结构化类型，不是 throw-and-catch 的附属品。
   - `ErrorRenderer` 作为管道最外层中间件，兜底所有 handler 抛出的错误。
   - 无 `ErrorRenderer` 时框架自动用 `AppError` 的状态码渲染（不再静默 500）。
   - 效果：错误响应语义明确，不丢失状态码信息。

6. **两级 arena 内存管理**
   - 请求级 arena：每个请求一个 arena，请求结束自动回收，handler 内无需 `free`。
   - 连接级 arena：跨请求复用（池化），减少分配器调用。
   - 效果：keep-alive 复用 arena 时微基准达 8M+ ops/s。

7. **分层配置 + 环境变量加载**
   - `Config` 分为 network / http / body / pool 四层，纯数据类型。
   - `fromEnv` 支持环境变量覆盖（前缀匹配），`applyEnv` 支持应用自有配置字段。
   - 配置文件场景：`std.json.parseFromSlice` 直接吃 JSON。
   - 效果：部署时改端口/地址不用重新编译，配置入口统一。

8. **服务容器（Services）**
   - `Services.init/register` 注册进程级单例，`server.setServices(&services)` 装配。
   - handler 里用 `ctx.service(T)` 取回，脱离全局变量。
   - `seal()` 封箱机制防止运行时意外注册。
   - 效果：依赖注入模式，测试友好。

### 2.5 架构评估结论

**架构设计优秀，无需大重构。**

具体评价：
- **分层清晰**：4 层核心各司其职，职责边界由 `build.zig` 模块边界编译期强制，无逾越。
- **依赖方向正确**：严格 DAG，无循环依赖，addon 可互相依赖但方向单一。
- **扩展性强**：新增能力只需新增 addon 模块，不改 core；换运行时只需新增 server 文件。
- **性能导向**：Handler `union(enum)`、arena 池化、后端无关 ConnectionRunner 等设计都以零开销为目标。
- **安全意识**：路径遍历防护、XSS 转义、恒定时间比较、CSRF 双提交、帧长上限防 DoS 等安全考量贯穿各模块。

**不足之处**（均为小改进即可，不需要大重构）：
- 缺少极简的 hello world 示例（现有示例功能全面但体量大，新手入门门槛偏高）。
- 部分配置项是死开关（`body.lazy_read_size`、`network.idle_timeout_ns`、`http.access_log_enabled`），虽不影响正确性但可能误导用户。

## 三、功能完整性分析

### 3.1 已具备功能

#### 路由（radix trie）
- 静态路由：精确路径匹配
- 参数路由：`/users/:id` 路径参数提取
- 通配符路由：`/static/*` 前缀匹配
- 路由分组：`router.group("/admin")` 组级中间件叠加
- HEAD 自动回退到 GET handler
- 405 带 `Allow` 头列出可用方法
- 自定义 404 handler
- 评价：**完整**，覆盖了生产级路由的全部常见需求。

#### 中间件管道
- 前置逻辑：`next.call` 之前执行
- 后置逻辑：`next.call` 之后执行（需 `res.setBuffered()` 缓冲模式）
- 短路：中间件不调 `next.call` 直接响应
- 缓冲模式：`res.setBuffered()` 保证 next() 后可改响应
- 所有权管理：`Middleware.init` 在 `T` 有 `deinit` 时自动注册销毁钩子，`router.deinit` 统一释放
- 评价：**完整**，经典 `process(ctx, res, next)` 模型，非 threadlocal，无并发隐患。

#### 请求解析
- 方法/路径/版本
- 查询字符串：`ctx.query("key")`（原始，未解码）/ `ctx.queryDecoded("key")`（解码）
- 表单字段：`ctx.formDecoded("name", limit)`（urlencoded body）
- 请求头：`ctx.header("Content-Type")` / `ctx.request.getHeader("X-Id")`
- Cookie：`ctx.request.getCookie("sid")`
- 请求体：`ctx.readBody(allocator, limit)`（支持 Content-Length 与 chunked，首次读入后缓存）
- 无 body 方法携带请求体的宽容处理：GET/HEAD/DELETE 等携带 body 时收下但忽略，排空后 keep-alive 继续
- 评价：**完整**，对 nginx 式宽容处理（无 body 方法携带 body 的排空）体现了生产级细节。

#### 响应构建
- 状态码：`res.statusCode(.ok)` 链式调用
- JSON：`res.json(.{ ... })`
- 纯文本：`res.text("Hello")`
- HTML：`res.html("<h1>")`
- 原始字节：`res.raw(bytes, "application/octet-stream")`
- 自定义头：`res.header("X-Custom", "value")`
- Cookie：`res.setCookie("token", "abc")` / `res.setCookieFull(.{...})`
- 重定向：`res.redirect("/new", false)` / `res.redirectStatus("/new", .see_other)`
- 流式响应：`res.stream(buffer, .{...})`
- 评价：**完整**，覆盖了所有常见响应类型，链式调用 API 设计简洁。

#### 静态文件服务
- 路径遍历防护
- ETag / `If-None-Match`（`*`/列表/`W/` 弱比较）
- `Last-Modified` / `If-Modified-Since` → 304
- HEAD（只发头不读体）
- 目录自动 `index.html`
- 大文件流式 + gzip 压缩
- MIME 类型大小写不敏感
- 评价：**完整**，安全防护和生产级缓存协商齐备。

#### 错误处理
- `AppError` 结构化错误（状态码 + 消息）
- `ctx.failWith(app_err)` 返回 `error.AppError`
- `ErrorRenderer` 管道最外层渲染
- 无 ErrorRenderer 时框架兜底用 AppError 状态码渲染
- 评价：**完整**，错误不丢失语义，不静默 500。

#### 安全
- 鉴权：Bearer Token / Basic Auth / API Key / 自定义 resolver（带状态身份解析器）
- CORS：预检 OPTIONS 自动处理、Vary 头
- CSRF：双提交 Cookie 模式
- 安全响应头：X-Content-Type-Options、X-Frame-Options、X-XSS-Protection 等
- 恒定时间比较：`constantTimeEql` 防 timing 侧信道
- HTML 转义：示例中的 `escapeHtml` 防反射型 XSS
- 评价：**完整**，安全考量贯穿各模块，resolver 机制补齐了 session/DB 类登录态的身份解析。

#### Session
- 基于 Cookie 的内存 Session 存储
- `SessionManager.init` / `getOrCreate` / `setData` / `getValue` / `getData`
- `std.Io.Mutex` 保护并发安全
- Session 超时配置
- 评价：**完整**，满足中小型应用需求；大规模分布式场景需要替换为 Redis 等（框架不阻止）。

#### WebSocket
- RFC 6455 握手 + 帧编解码 + 连接劫持
- `wsUpgrade` 一步升级（校验 + 注册 hijack 回调）
- 分片拼合
- ping/pong 自动回复
- 帧长上限防 DoS
- 连接级读写 API（`WebSocket.initServer/initClient`）
- 底层帧编解码 API（`wsEncodeFrame/wsDecodeFrame`）
- 评价：**完整**，从高层 `wsUpgrade` 到底层帧编解码全覆盖，连接劫持设计优雅。

#### 限流
- 窗口计数限流
- 429 + `Retry-After` / `X-RateLimit-*` 响应头
- per_ip 配置（需 trust_proxy_headers）
- `exclude_paths` 豁免路径
- 评价：**完整**，满足基础限流需求。

#### 压缩
- gzip / deflate 流式压缩
- `Accept-Encoding` q 值协商
- 默认 >=1KB 才压缩
- `Content-Type` 敏感（不压缩已压缩格式）
- 评价：**完整**，q 值协商和 Content-Type 敏感体现了正确性。

#### 日志
- 结构化日志（JSON / 文本格式）
- 文件输出 + 文件轮转 + gzip 压缩
- O_APPEND 内核原子追加（POSIX，可选 libc 链接）
- 请求级日志钩子（`LoggingHook` 挂到 `server.setLifecycle`）
- 评价：**完整**，文件轮转和 O_APPEND 快路径设计周到。

#### ORM
- JSON 文件持久化
- 编译期反射自动推导表结构（`id` 字段自动主键 + 自增）
- `Model(T, "table")` / `ModelWith(T, "table", .{ .unique = ... })`
- CRUD：`insert` / `findById` / `all` / `updateById` / `deleteById`
- 条件查询：`Query(T).init` / `where` / `orderBy` / `limit` / `offset`
- `findAll` / `findOne` / `count` / `paginate`
- 唯一约束：`error.UniqueViolation`（锁内校验，insert 失败不写入）
- 评价：**功能完整但定位为 demo 级**——JSON 文件存储无并发安全保障，适合中小规模或原型场景。生产环境需替换为 SQLite/PostgreSQL。

#### Multipart
- multipart/form-data 解析
- 字段提取（`getText` / `getFile`）
- 文件名安全化（`safeBaseName`）
- 错误细分：`NotMultipart` / `MissingBoundary` / `TooManyParts` / `MalformedPart` / `DuplicateField` / `BodyTooLarge`
- 评价：**完整**，错误语义细分到位。

### 3.2 功能评价

综合评价：**功能齐全**。框架覆盖了 HTTP 服务器框架的全部核心能力——路由、中间件、请求解析、响应构建、静态文件、错误处理、安全、Session、WebSocket、限流、压缩、日志、ORM、Multipart。每个功能模块都达到了生产级实现的质量标准，安全考量和边界处理到位。

### 3.3 缺失功能分析

#### HTTPS / TLS
- **现状**：不支持 HTTPS。
- **原因**：Zig 标准库的 TLS 实现尚不成熟（`std.crypto.tls` 仍有限），硬接 TLS 会引入稳定性风险。
- **建议**：暂不考虑。生产环境用反向代理（nginx/Caddy）终止 TLS，后端走 HTTP 是成熟做法。等 Zig std TLS 成熟后再以 addon 形式接入。

#### 模板引擎
- **现状**：无内置模板引擎。
- **评估**：模板引擎有成熟替代方案（客户端渲染 + JSON API）。框架的 `res.html()` 已支持原始 HTML 输出，第三方模板库可轻松集成。
- **建议**：不做内置，保持 core 精简。

#### 数据库连接池 / ORM 扩展
- **现状**：ORM 基于 JSON 文件，无 SQL 数据库支持。
- **评估**：Zig 生态中 SQLite 绑定（如 `zsqlite`）可用，但不在框架职责范围内。
- **建议**：以 addon 形式接入，不进 core。

#### 热重载 / 开发服务器
- **现状**：无热重载。
- **评估**：Zig 编译速度极快，`zig build run` 已足够开发迭代。
- **建议**：不做内置，可结合外部工具（如 `watchexec`）实现。

## 四、用户易用性分析

### 4.1 API 设计评价

**优点**：
- **入口极简**：`pub fn main(init: std.process.Init) !void` + `framework.runZio(allocator, appMain)` 两步启动，入口不直接依赖 zio。
- **链式调用**：`res.statusCode(.ok).json(.{ ... })` 一行完成状态码 + body 设置。
- **命名清晰**：`fromFn` / `initSingleton` / `initFactory` 三种 Handler 模式的工厂函数名直白表意。
- **错误处理简洁**：`try ctx.failWith(framework.AppError.notFound("..."))` 一行完成错误抛出，`ErrorRenderer` 兜底渲染。
- **零 boilerplate**：纯函数 handler 只需 `fn(ctx, res) !void` 签名 + `fromFn` 包装，无结构体、无 trait、无宏。
- **按需引入**：`@import("http_framework")` 一次拿全部，也可只依赖核心 4 层或个别 addon。

**不足**：
- 中间件所有权约束较为隐晦（`Middleware.init` 后所有权移交框架，手动 `deinit` 会 double-free），需要文档反复强调。
- `initFactory` 的 `deinit` 规则（只释放内部字段，不 `destroy(self)`）对新手不直觉。
- 部分配置项是死开关，用户可能设置后期待效果但实际无效。

### 4.2 文档评价

**优点**：
- README.md 详尽：快速开始、三种 Handler 模式、路由/中间件/错误处理/Session/WebSocket/静态文件/日志/ORM 各有示例代码。
- examples/API.md 是真实业务后端接口契约文档，展示了框架在真实业务中的使用方式。
- examples/FRICTION.md 记录了真实业务压测的踩坑清单，坦诚记录设计缺陷和 API 不顺手之处。
- 示例代码头部注释有完整的 curl 测试清单。
- README 中对死开关配置项有明确标注。

**不足**：
- 无 API 参考文档（函数签名 / 参数 / 返回值的系统列表），依赖 README 中的代码片段和源码注释。
- FRICTION.md 是宝贵的设计反馈，但部分已解决项和未解决项混杂，需要额外梳理。

### 4.3 示例评价

**优点**：
- `examples/` 是一个完整、可运行的服务器，覆盖框架绝大部分功能（路由/中间件/JSON/multipart/静态文件/压缩/会话/鉴权/限流/ORM/WebSocket）。
- 示例包含分层业务后端（`examples/src/app/`：model/repo/service/handler/middleware），展示了如何在框架上构建真实业务。
- `src/main.zig` 作为框架自带示例，展示完整中间件管道配置。
- `examples/build.zig` 正确演示了 `b.dependency("http_framework", .{...})` 接线方式。

**不足**：
- 缺少极简的 hello world 示例。现有示例功能全面但体量大（`examples/src/main.zig` 57K+），新手入门门槛偏高。

### 4.4 入门门槛

- **对 Zig 新手**：需要理解 `std.Io`、`std.mem.Allocator`、arena、`union(enum)` 等概念，门槛中等。
- **对 HTTP 框架新手**：README 快速开始 + 三种 Handler 模式表格 + 中间件示例足够上手，门槛偏低。
- **对资深开发者**：分层配置、服务容器、生命周期钩子、后端无关 ConnectionRunner 等设计使得框架能力可深可浅，门槛低。

## 五、改进建议

### 5.1 已实施改进

本次改进中实施了以下小改动：

1. **创建 `examples/hello.zig` 极简示例**：展示最基本的 HTTP server 用法（3 条路由 + JSON 响应），降低新手入门门槛。在 `examples/build.zig` 中注册为独立可执行目标 `hello`。

2. **README.md API 一致性检查**：确认 README 中的示例代码与实际 API 一致。README 快速开始部分的 `pub fn main(init: std.process.Init)` 签名、`framework.runZio` 调用、`Router.init` / `router.route` / `Handler.fromFn` / `Context.param` / `Response.json` 等 API 均与源码一致。`src/main.zig` 使用 `DebugAllocator`（开发期泄漏检测），README 展示 `init.gpa`（生产推荐写法），二者均为有效 API 用法，不算不一致。

3. **TODO/FIXME 检查**：全 `src/` 目录扫描无实际 TODO/FIXME 项（唯一匹配是 `router.zig` 中一个测试名称含 "fix TODO"，非代码 TODO）。

### 5.2 未来建议

以下建议均为非侵入式改进，不需要大重构：

1. **死开关配置项标注或实现**：
   - `body.lazy_read_size`：标注 "planned, not yet effective" 或实现延迟读取。
   - `network.idle_timeout_ns`：明确 keep-alive 空闲由 `read_timeout_ns` 约束，或移除该字段。
   - `http.access_log_enabled`：明确要访问日志需注册 `LoggingHook`/`LoggingMiddleware`。

2. **API 参考文档**：生成或手写函数签名列表，补充 README 无法覆盖的参数细节。

3. **测试覆盖持续补全**：`http_testing` addon 已提供离线测试 harness，继续利用它驱动中间件和 handler 测试。

4. **ORM 增强**（定位为 demo 级，只修真 bug）：
   - `findAllBy` / `countAll` 等便捷方法（FRICTION F-02 记录的需求）。
   - 索引支持（当前只有唯一约束，无普通索引）。

5. **中文文档持续维护**：README.md 和示例注释已是中文，保持一致性。

## 六、总结

本 HTTP Framework 是一个设计成熟、实现完整的高性能 Zig HTTP 框架。

**架构方面**：4 层核心 + addon 扩展的 DAG 分层设计优秀，职责边界清晰，编译期强制隔离。后端无关的 `ConnectionRunner` + 运行时绑定的 `zio_server` 分离是亮点设计。`Handler` 用 `union(enum)` 替代 vtable、错误一等公民、两级 arena 内存管理等设计体现了对性能和正确性的双重追求。**无需大重构。**

**功能方面**：路由、中间件、请求解析、响应构建、静态文件、错误处理、安全、Session、WebSocket、限流、压缩、日志、ORM、Multipart 全部齐备，每个模块都达到了生产级实现的质量标准。缺失的 HTTPS 暂不考虑（Zig std TLS 限制），模板引擎和数据库连接池不属于框架职责。

**易用性方面**：API 设计简洁（零 boilerplate、链式调用、三种 Handler 模式命名直白），文档详尽（README + API.md + FRICTION.md + curl 清单），示例功能全面。主要不足是缺少极简 hello world 示例——本次已补充。

**改进方面**：只需小改进——补充极简示例、标注死开关配置项、持续补全测试和文档。核心架构不需要动。
