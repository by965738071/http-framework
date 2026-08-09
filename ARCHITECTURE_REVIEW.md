# 架构评审：对标 http.zig

> 日期：2026-08-09
> 对比对象：[karlseguin/http.zig](https://github.com/karlseguin/http.zig)（本地副本 `../http.zig`，已适配 Zig 0.16 `std.Io` 的版本）
> 目的：梳理 http.zig 的架构设计与设计思想，对比本项目，确定值得借鉴与明确不借鉴的部分。

---

## 一、http.zig 架构梳理

### 1.1 分层

```
httpz.zig (2635行, 门面)  Server(H) 泛型 / Action / Middleware / FallbackAllocator
   ├─ worker.zig (2010)   Blocking | NonBlocking 双实现 + KQueue/EPoll + HTTPConn + ConnPool
   ├─ thread_pool.zig     自研线程池（批量投递 + 每线程静态 buffer 注入）
   ├─ request.zig (2310)  Request(视图) + Request.State(可复用解析状态机)
   ├─ response.zig        Response + State + writev 序列化
   ├─ router.zig          每 method 一棵 trie
   └─ buffer.zig / key_value.zig / params.zig / posix.zig / windows.zig
```

`build.zig` 只暴露一个模块 `httpz`，硬依赖 `metrics` 与 `websocket`。编译期开关仅两个：`httpz_blocking`（`build.zig:26`，模块内固定 false，`-Dforce_blocking` 只作用于测试）与 `-Dtsan`。

websocket 没有 build option——通过 `Handler.WebsocketHandler` 是否存在（`httpz.zig:243`）在 comptime 退化成 `DummyWebsocketHandler`，buffer 池大小填 0。这是「零成本可选特性」的一个技巧：用类型内省代替 build option。

### 1.2 五个核心设计决策

#### 决策 1：三级内存漏斗 + 带类型标签的 Buffer

```
thread_buf (线程池线程持有的 32KB 静态内存，零分配零竞争)
   ↓ 装不下
req_arena (挂在 HTTPConn 上，每请求 reset(.{ .retain_with_limit = 8192 }))
   ↓ 大块
BufferPool (预分配的大 buffer 池，池空则直接堆分配并打 metrics)
```

- `FallbackAllocator`（`httpz.zig:716-765`）把前两级缝合成一个普通 `Allocator` 交给用户，用户侧只看到 `req.arena`。其 `resize` 失败时必须保持原分配有效（`:740-745` 的注释记录了一次因回收导致 arena 节点被重复发放的 bug）。
- `Buffer{ data, type: {arena, static, pooled, dynamic} }`（`buffer.zig`）——**内存的来源是数据而不是控制流**。`release()` 一个函数按 tag 分派四种归还方式，调用方完全不需要知道这块内存哪来的。
- 池空或请求超过 `buffer_size` 时不排队、直接 fallback 到堆，并打点 metrics（`allocBufferEmpty` / `allocBufferLarge`）。
- `conn_arena`：连接级、只在 conn 创建时用一次，分配 `Request.State` / `Response.State` 的所有固定内存。

#### 决策 2：「读非阻塞、写阻塞」的混合 I/O

事件循环只负责把碎片攒成完整请求；攒齐后整个请求-响应在线程池里同步跑完。

accept 出来的 socket 是 NONBLOCK（`worker.zig:711`），但 `writeAll` 一遇 `WouldBlock` 就 `fcntl` 临时切回阻塞（`worker.zig:1769-1776`），请求结束再切回（`requestDone(..., revert_blocking)`）。

作者的理由写在 `worker.zig:343-346`：**给应用一个可预测的 response 生命周期**。代价是慢客户端占死一个线程池线程（`thread_pool.count` 默认 32 即最大并发写），必须挂反向代理。这是一笔清醒的「用架构复杂度换 API 简单度」的交易。

#### 决策 3：comptime 反推 ActionArg

```zig
const ActionArg = if (hasFn(Handler, "dispatch"))
    @typeInfo(@TypeOf(Handler.dispatch)).@"fn".param_types[1].?
  else Action(H);
```

从用户自己写的 `dispatch` 方法的**第二个参数类型**反推出全应用的 action 签名（`httpz.zig:241`）。于是 `dispatch(self, action: Action(*Env), req, res)` 让所有 handler 变成 `fn(*Env, *Request, *Response)`——"每请求上下文"这种一般要靠运行期 DI 的能力，变成了纯编译期、零开销、类型安全的。

配合 `std.meta.hasFn` 鸭子类型探测钩子（`handle` / `dispatch` / `notFound` / `uncaughtError` / `WebsocketHandler`），**整个框架没有一个需要用户显式实现的 interface**。

#### 决策 4：连接状态 = 链表归属

4 个按超时时刻有序的侵入式链表（`worker.zig:386-409`）：

```
request_list (半包等待) → active_list (线程池处理中) → handover_list (线程池交还) → keepalive_list
```

- 超时检查退化成"从头扫到第一个未超时的"（`collectTimedOut`, `worker.zig:959`），O(超时数) 而非 O(连接数)。
- `swapList`（`worker.zig:668`）在锁下集中处理所有状态迁移。
- per-worker 完全独立的池 / 事件循环 / 线程池，多 worker 靠内核 `SO_REUSEPORT_LB`(BSD) / `SO_REUSEPORT`+`EPOLLEXCLUSIVE`(Linux) 分发，用户态零负载均衡逻辑。

#### 决策 5：State 与视图分离，且 State 跨请求复用

`Request.State` / `Response.State` 挂在 `HTTPConn` 上（含解析器断点续传状态，支持非阻塞下的分片到达），`reset()` 只重置游标不释放内存；`Request` / `Response` 是每请求在 `thread_buf` 上现造的轻量视图。

副产品：`testing.zig` 能用**真解析器**喂一段真实报文（`GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n`）构造测试对象，测试路径与生产路径完全同构。

### 1.3 body 的静态/动态边界（`request.zig:1083-1136`）

单独值得记录的一段：

| 条件 | 策略 |
|---|---|
| `content_length == 0` | 无 body |
| 已随 header 一起读完 | `body = {.static, buf[pos..len]}`，**零拷贝直接切 header buffer** |
| 缺的字节数 < header buffer 剩余空间 | 仍用 `buf`，只把 `pos` 预推到最终位置 |
| 否则 | `buffer_pool.arenaAlloc(req_arena, cl)`，已读部分 memcpy 过去 |
| 配了 `lazy_read_size` 且 `cl >= lazy_read` | 完全不缓冲，置 `unread_body`，交给 `req.reader()` 流式读 |

chunked 单独申请一块 raw 输入缓冲，**不复用 `self.buf`**——因为 URL 和 header value 都是指向 `buf` 的切片（`:1157-1159`）。

### 1.4 其他值得记的细节

- **响应写出**：非 chunked 时把 header 和 body 组成 2 个 iovec 一次 `writev`——单请求单 syscall。状态行对常见状态码用 `inline` switch + `comptimePrint` 直接 memcpy。`chunk()` 用 16 字节栈缓冲写十六进制长度 + `writev` 两段，零分配。
- **KeyValue**（`key_value.zig`）：一次 `alignedAlloc` 承载 keys + values + hashes 三个数组，定容、线性扫描、先比 1 字节 hash 再 `memEql`。头部 32 个以内时比 HashMap 快。
- **路由**：每 method 一棵独立 trie，method 分发是 switch 无字符串比较。参数"先存值、匹配到叶子后再从 `param_names` 批量填名"——因为 trie 遍历时还不知道最终路由的参数名。
- **中间件**：注册期就把最终数组算好存进 `DispatchableAction`，运行期零开销。404 路径也会跑全局中间件（`httpz.zig:557-560`），这点设计得好。
- **metrics**：`httpz_alloc_buffer_empty` / `alloc_buffer_large` / `alloc_unescape` 直接暴露"内存快路径失效了多少字节"——**把内存池的失效当作一等监控指标**。

---

## 二、本项目现状

`src/` 共 21254 行、51 个 `.zig` 文件。

| 目录 | 行数 | 职责 |
|---|---|---|
| `core/` | 4819 | server / router / request / response / handler / middleware + 3 个 vtable 接口 |
| `orm/` | 4125 | engine / query / schema / model（独立，不依赖 core） |
| `observability/` | 1768 | FileLogger、MetricsCollector、OpenAPI |
| `codec/` | 1722 | deserialize / validation / compression / body_signature |
| `security/` | 1689 | cors / auth / csrf / security_headers |
| `rate_limit/` | 1278 | rate_limiter + token_bucket |
| 其他 | — | template 1301 / policy 1014 / protocol 870 / multipart 447 / pool 418 / test 401 / api 345 / session 314 / background 249 / static 234 |

**模块边界靠 build.zig 强制**：`core` 的 `.imports` 为空（`build.zig:19-23`），9 个 addon 各自只 import core（`:52-60`），4 个 standalone 连 core 都不 import（`:62-69`）。`build.zig:77-81` 为每个模块单独建 test 目标，core 的测试目标只含 core 模块——任何 `@import("session")` 会直接编译失败。铁律不是文档而是编译期约束。

**编译期选项：零。** 全仓无 `b.option` / `addOptions`，所有可调项都在运行时 `Config` 里。

**并发模型**：thread-per-connection，跑在 `std.Io` 的并发任务上。`run()` 把 accept 循环丢到 `io.concurrent`（`server.zig:199-213`）；`acceptLoop()` 先 `conn_semaphore.wait` 取许可 → `tcp_server.accept(io)` → `conn_group.concurrent(...)` 派发（`server.zig:250-288`）。keep-alive 在 `handleConnection` 的 while 循环里逐个 `receiveHead()`。空闲超时自建 `IdleTimeoutReader` 用 `io.operateTimeout`，而非 `SO_RCVTIMEO`（后者会让 `Io.Threaded` 把 EAGAIN 当 programmer bug 直接 panic）。

**内存**：读写缓冲是两个按**编译期上限**声明的栈数组，合计 128KiB/连接（`server.zig:400-401`），`config.read_buffer_size` 只是 `@min` 后切片——调小配置一分不省。跨连接零复用、无 buffer pool、无 arena、无对象池。`RequestContext.init` / `Response.init` 直接吃全局 GPA。

**测试**：614 个 `test` 块内联在源文件中 + `src/test/integration_test.zig`（401 行，9 用例，用 `Head.parse` 构造假请求跑 `router.dispatch` 全链路）。分布极不均：`orm/query.zig` 93 个，而 `core/server.zig` 只有 6 个且全不碰 socket。

---

## 三、逐项对比

| 维度 | http.zig | 本项目 | 判断 |
|---|---|---|---|
| 模块边界 | 单个 2635 行巨型门面，websocket 硬依赖 | build.zig 强制的模块图，core 零 imports | **我方更好，别动** |
| I/O 抽象 | 手写 posix + kqueue/epoll | std.Io.net | **我方更好** |
| HTTP 解析 | 自写、可复用、可断点续传 | std.http.Server | 各有取舍 |
| 请求内存 | 三级漏斗 + arena reset 保留容量 | 全局 GPA，满地 dupe/free | **差距最大** |
| 连接缓冲 | ConnPool 预分配 + BufferPool | 128KiB 栈数组，跨连接零复用 | **差距最大** |
| 路由 | 每 method 一棵 trie，无回溯 | ArrayList 线性扫描，匹配跑两遍 | 它更快，但它无 405 |
| App state | comptime 泛型 `Server(H)` | `ctx.user_data` 单槽 | **我方有 bug** |
| 流式响应 | chunk / SSE / disown / lazy body | 全量入内存，无 chunked | 缺失 |
| 405 / Allow | 没有，一律 404 | 有，带 Allow 头 | **我方更好** |
| 扩展点 | hasFn 鸭子类型 | vtable 反转 Logger / Observer / Worker | 我方更显式，各有优势 |
| Config | 全 `?T`，默认值散落各使用点 | 具名默认值集中 | **我方更好，别抄它** |
| 内存 metrics | 池失效是一等指标 | 无 | 该抄 |
| core 测试 | testing 模块 + 真解析器 | server.zig 仅 6 个，不碰 socket | 该补 |

### 关于 std.Io vs std.posix

**我方选择是对的，理由比"更现代"更强**：`std.Io` 的整个设计意图是"用阻塞风格写代码，由 Io 实现决定它是线程还是事件循环"。当前跑在 `Io.Threaded` 上是 thread-per-connection，但当 io_uring / evented 后端落地时，**同一份 `handleConnection` 代码零改动就变成事件驱动**。http.zig 手写的那 2000 行 kqueue/epoll 状态机，在我方是白送的。

但要清醒认识当前代价：一条空闲 keep-alive 连接会占住一个 OS 线程整整 `idle_timeout_ns`（默认 30s），而 `max_connections=10000` 的信号量许可远超 `Io.Threaded` 的实际线程容量——池满时 `conn_group.concurrent` 失败，`server.zig:282-286` 的处理是**直接关掉连接**。所以背压是假的，真实表现是丢连接。**这个问题不需要退回 posix 来解决。**

---

## 四、改进建议（按 ROI 排序）

### A 组：值得做，且不违反 core 零依赖铁律

#### A1. 每请求 arena（收益最大，改动集中）

把 `RequestContext` / `Response` 的 allocator 从全局 GPA 换成挂在连接上的 `ArenaAllocator`，每请求 `reset(.{ .retain_with_limit = N })`。

受益点：
- `router.zig:492-503` 的 param dupe
- `request.zig:209-221` 的 query dupe、`:476-494` 的 form key+value dupe
- `response.zig:129-134` / `:208-215` 的 header + Cookie dupe

这些的 `deinit` 全部消失，变成一次 arena reset。`owned_strings` 这个结构本身可以整个删掉。

#### A2. 连接缓冲池化，消灭 128KiB 栈

`server.zig:400-401` 两个按编译期上限声明的栈数组，是"用户调小 config 也一分不省"的设计。

换成从一个 `BufferPool` 借 `read_buffer_size + write_buffer_size` 字节，连同 arena 一起打包成 `ConnState`：预分配 `min_conn` 个、超出动态创建、归还时池满即销毁（http.zig `HTTPConnPool` 的自动缩容策略）。

`src/pool/connection_pool.zig` 已写好但未接入 accept 循环（`root.zig:115-116` 自注），这次一并接上。

**A1 与 A2 是同一次改造，一起做。**

#### A3. 修 `user_data` 单槽（真 bug，不是优化）

`request.zig:368-374` 的 `setUserData` 无条件覆盖，旧 `destroyFn` 永不调用。后果不只是泄漏：**auth 中间件与 session 中间件无法共存**。

两个方向：
- **小修**：改成按类型/key 的多槽 map（配合 A1 的 arena，析构成本几乎为零）
- **根治**：引入 `Server(App)` comptime 泛型，handler 签名变 `fn(*App, *Ctx, *Res)`，共享状态走类型安全的 App 而不是 `*anyopaque`。这是破坏性变更，需单独讨论。

#### A4. 内存快路径失效打进 metrics

已有 `MetricsCollector`，加 `buffer_pool_empty` / `buffer_too_large` / `arena_overflow` 三个计数器。http.zig 把"内存池什么时候失效"当一等可运维指标，这个思路很便宜但很值钱。

#### A5. 让背压真实

`max_connections` 默认值应与 `Io.Threaded` 实际线程数挂钩，而不是拍脑袋 10000；`conc_err` 时不应直接关连接，应让信号量真正卡住 accept。

### B 组：值得做，但要改造后再抄

#### B1. 流式响应

抄 `res.chunk()` 的零分配写法（16 字节栈缓冲写十六进制长度 + `writev` 两段），解锁大文件下载、SSE、流式 JSON。

**别抄** `startEventStream`——它每个 SSE 连接 `Thread.spawn` + `detach`、无上限无 join。我方有 `Io.Group`，用它。

#### B2. lazy body

加 `lazy_read_size` 配置，超阈值不缓冲直接给 reader。当前 `readBody()`（`request.zig:286-336`）全量入内存 + 10MB 硬限，把 multipart（`multipart.zig:282`）和静态文件（`static.zig:111`）一起锁死了。

#### B3. 路由 trie

每 method 一棵 trie + 参数"先存值、匹配到叶子后按 `param_names` 批量填名"。

注意：**trie 化后现有的 405 全表扫描会失效，别为了性能把 405 丢了**（http.zig 就是没做）。路由数量到几百条之前，本条优先级低于 A 组。

顺带补一个注册期重复路由检测——`examples/.../middleware_demo.zig:253` 与 `:269` 注册了两条相同的 `GET /api/hello`，第二条永远不可达，框架静默接受。

#### B4. 公开 testing 模块

`src/test/integration_test.zig` 已在用 `Head.parse` 构造真请求，方向正确，把它提升成公开 API（`.url()` / `.param()` / `.expectStatus()` / `.expectJson()`）。

同时补 core 的并发路径测试——`core/server.zig` 6 个测试全不碰网络，keep-alive 循环和 `IdleTimeoutReader` 零覆盖。

### C 组：明确不要抄

- 手写 posix / kqueue 事件循环（理由见 §3）
- **KeyValue 静默截断**：超过 32 个 header 直接丢弃且无报错（`key_value.zig:43-45`），而重复 `Content-Length` 检测正是靠遍历这个数组做的（`request.zig:1033`）——理论上可构造请求走私
- 路由无回溯：`/:any/users` 与 `/hello/users/test` 共存会匹配失败，作者自己在 readme 承认
- 无 405、无自动 HEAD/OPTIONS、无 `Date` 头、无 HTTP/1.0 keepalive
- `router.get()` 失败直接 `@panic`（`router.zig:99`），`Group.createPath` 用 `catch unreachable`
- `res.body` 生命周期只靠 `defer assert(res.written)` 保护，传栈数组就 UAF 且不易察觉
- `route_data` 是 `*const anyopaque` 需用户手动 `@ptrCast(@alignCast(...))`，作者自己注释说 "a bit ugly"
- Config 全 optional、默认值散落各使用点——它的 readme 已与代码不同步（`thread_pool.buffer_size` 代码 32768 / 文档 8192）
- 附带发现：`thread_pool.zig:53` 的 `@mod(i + i, len)` 几乎肯定是 `i + 1` 的笔误，work-stealing 的 peer 环不闭合

### D 组：本项目已有优势，重构中别弄丢

- build.zig 强制的模块边界（core 零 imports）
- 405 + `Allow` 头
- vtable 反转的三个接口（Logger / RequestObserver / Worker）
- 通配符边界检查（`router.zig:436-438`，防 `static/*` 吃掉 `/staticky/secret`，有专门测试）
- TLS 显式报错而非静默降级（`server.zig:124-126`）
- `Io.Group.cancel` 优雅关闭
- 集中的具名默认配置
- `RequestObserver` 刻意只给 `route_pattern` 不给原始路径，防指标基数爆炸

---

## 五、结论与推进顺序

http.zig 真正的护城河是**内存管理**（三级漏斗 + 类型标签 buffer + State 复用）和 **comptime 类型推导带来的零开销 App state**，不是它的 posix 事件循环。

- 前者本项目几乎全缺，且改造成本低（A1 + A2 是同一次改动）
- 后者是 `user_data` 那个真 bug 的根治方案

**推进顺序：**

```
A1 + A2 + A3  →  A4 + A5  →  B1 + B2  →  B3 + B4
每请求 arena     可观测性      流式响应     路由 trie
连接池化         真背压        lazy body    testing 模块
user_data 多槽
```

### 次级问题（不入前 5，但记录在案）

- `parseIp4`（`server.zig:128`）导致 **IPv4-only**，`::1` / 主机名 / 双栈监听均不可用
- TLS 未实现；HTTP/2 仅为升级检测桩（`protocol/http2.zig:1-10`）
- `session` 未实现 `worker()`，清理仍是请求内联触发（`session.zig:149-156`）
- 全局中间件与路由级中间件的拦截逻辑基本重复（`router.zig:240-267` vs `:321-357`）
- 一个 HTTP 框架里最大的非 core 模块是 ORM（4125 行，占 19.4%），定位值得商榷
