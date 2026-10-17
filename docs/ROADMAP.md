# 功能路线图（ROADMAP）

> 生成日期：2026-10-17。依据：ANALYSIS.md 全文复审、FRICTION.md 未解决项逐条代码核实（行号基于当前工作树）、
> 15 个模块公开 API 盘点（docs/API_generated.md）。
> 评级原则：框架定位 **demo 级/轻量生产**——core 保持精简，addon 承担扩展；「真 bug / 静默错误」优先于「新功能」。
> 所有「现状」均经过代码核实，标注文件:行；与 FRICTION 编号的映射见文末。

## 一、总览

| 优先级 | 条目 | 类型 | 落点模块 | 工作量 |
| --- | --- | --- | --- | --- |
| P0-1 | `In`/`NotIn` 死操作符：实现或编译期封禁 | 真 bug（静默错误） | http_orm | S |
| P0-2 | 损坏单行导致整表打不开：容忍模式 | 真 bug | http_orm | S |
| P0-3 | 错误渲染失败被静默吞掉：补 warn | 真 bug | http_server | XS |
| P0-4 | 程序化关机 `Server.requestShutdown()` | 功能缺失 | http_server | S |
| P1-1 | 密码哈希/校验工具（argon2id） | 功能缺失 | http_security | S |
| P1-2 | 配置文件加载器（JSON → Config，与 env 分层） | 功能缺失 | http_app | M |
| P1-3 | Session：类型化值 + 可插拔持久化后端 | 功能缺失 | http_session | M |
| P1-4 | SSE 助手 `res.sse()` | 功能缺失 | http_protocol 或 addon | S |
| P1-5 | ORM：带过滤/排序的 paginate、QueryBuilder 一步式糖 | API 不顺手 | http_orm | M |
| P1-6 | ORM：快照级事务（begin/commit/rollback） | 功能缺失 | http_orm | M |
| P1-7 | ORM：Migration 执行器（最小集） | 功能缺失 | http_orm | M |
| P1-8 | 动态响应 ETag/304（提炼 static 的条件请求逻辑为 `http_cache` addon） | 功能缺失 | 新 addon | M |
| P1-9 | `/metrics`（Prometheus 文本）+ `/healthz` 助手 addon | 功能缺失 | 新 addon | M |
| P1-10 | WebSocket 连接集合管理（broadcast/closeAll/room） | 功能缺失 | http_websocket | M |
| P1-11 | 时间助手（HTTP date / Unix ms） | API 不顺手 | http_app | XS |
| P2-x | 见「四、P2 生态与 DX」 | — | — | — |

## 二、P0：真 bug / 静默错误（建议尽快修）

### P0-1 ORM `In` / `NotIn` 是死操作符（F-03）
- **现状（已核实）**：`Operator` 枚举公开了 `.In/.NotIn` 且有 `symbol()`（`src/http_orm/query.zig:27-28,41-42`），
  但匹配逻辑硬编码 `.In, .NotIn => false`（`query.zig:443`）——条件**永远不命中**且无任何报错。
  源码注释自己也承认（`query.zig:183-184`）。
- **建议二选一**：
  1. 实现之：`FieldValue` 加 `list` 变体（或新增 `whereIn(field, values)` 入口），匹配时线性扫描列表；
  2. 最小修：`where(.In, ...)` 改 `@compileError`，把静默错误变成编译错误。
- **验收**：`where(.In, "id", .{ .list = .{1,2,3} })` 返回三行；或编译失败有明确信息。

### P0-2 一条坏数据让整张表打不开（F-16）
- **现状**：store 加载任一行的字段解析失败 → 整个 `JsonStore.init` 失败，进程起不来（examples 实测踩过）。
- **建议**：`ModelOptions` 加 `skip_corrupt_rows: bool = false`（默认严格不变）；
  开启时坏行跳过 + `std.log.warn`（带行号），并计入 `store.corrupt_row_count` 便于运维发现。
- **验收**：人为写坏一行 JSON，默认模式照旧拒绝启动；容忍模式可启动且只丢该行。

### P0-3 成功路径渲染 AppError 失败被静默吞掉（F-NEW-4）
- **现状**：连接层兜底渲染 AppError 失败时无任何日志，排障无线索。
- **建议**：catch 分支补 `std.log.warn`（带请求 id）；不改控制流。
- **验收**：构造渲染失败（如超长头），log 可见 warn 行。

### P0-4 程序化关机接口（docs/API.md §14 第 21 条已承诺为缺口）
- **现状（已核实）**：`std_server.zig:514` 已有 `shutdown_requested` 原子量 + 信号处理
  （`std_server.zig:153-193,517`），`zio_server.zig:204-205` 同样监听 SIGINT/SIGTERM，但都没有对外入口。
- **建议**：两个 Server 都加 `pub fn requestShutdown(self: *Server): void`（内部就是 store 原子量）；
  或 `runZio/runStd` 返回一个带 `shutdown()` 的句柄。文档同步改 §14 第 21 条。
- **验收**：测试里后台起服务 → 发请求 → `requestShutdown()` → `run` 返回 0。

## 三、P1：功能补齐（demo 高频需求，按投入产出排序）

### P1-1 密码哈希/校验工具（F-07）
- **现状（已核实）**：全 `src/` 无 argon2/bcrypt/scrypt 相关代码；examples/FRICTION 记录业务层只能裸存。
  `http_security` 已有 `constantTimeEql`（`root.zig:39`），差一个哈希入口。
- **建议**：`http_security` 加 `hashPassword(allocator, password, out_buf)` / `verifyPassword(hash, password) bool`，
  用 `std.crypto.pwhash.argon2id`（标准库自带，无新依赖），PHC 字符串格式存 `[]const u8`，正好适配 ORM 的 string 字段。
- **验收**：往返测试 + 错误密码拒绝 + 计时安全（复用 constantTimeEql）。

### P1-2 配置文件加载器（F-08）
- **现状（已核实）**：`config.zig` 只有环境变量注入（`applyEnv`，`config.zig:79`）；无文件加载（grep toml/yaml/fromFile 均无）。
- **建议**：`Config.fromFile(allocator, path)`（JSON 格式，`std.json.parseFromSlice` 进 `Config`）；
  优先级链：显式赋值 < 文件 < 环境变量；`validate()`（已实现）照管非法值。YAML/TOML 不做（避免拉依赖，对齐 core 精简）。
- **验收**：三层优先级测试；非法 JSON 报 `error.InvalidConfigFile` 而不是 panic。

### P1-3 Session：类型化值 + 可插拔持久化（F-10）
- **现状（已核实）**：`setValue`/`getValue` 只收/返 `[]const u8`（`session.zig:176,201`）；存储纯内存，重启全丢。
- **建议**：① `set`/`get` 支持 `anytype`（内部 JSON 序列化，复用 http_codec 思路）；
  ② 存储后端接口化（get/set/remove/list 四个 vtable 函数），默认内存实现不变；
  加一个 `FileSessionStore`（写 JSON 文件，对齐 ORM 风格）。Redis 类外部后端不做（见「不做什么」）。
- **验收**：跨重启会话存活测试；`set("n", 42)` / `get("n", u8)` 往返。

### P1-4 SSE 助手 `res.sse()`（FRICTION 未覆盖，属盘点发现）
- **现状（已核实）**：全仓无 `text/event-stream`；`res.stream()`（`response.zig:376`）已提供 chunked 流式底座。
- **建议**：addon 自由函数 `sse(res)` 返回包装器：`event()/data()/retry()/comment()` + 自动 `\n\n` 组帧与各字段转义；
  底层就是 stream + 禁用压缩。约 80 行。
- **验收**：`http_testing` 断言帧格式；examples 加一个 5 行推送 demo。

### P1-5 ORM 查询糖（F-19 / F-21）
- **现状（已核实）**：`paginate(gpa, page, per_page)` 无过滤/排序参数（`engine.zig:697`）；QueryBuilder 一次查询要 5 行样板（F-19）。
- **建议**：① `paginate_where(page, per_page, where)` / `QueryBuilder.paginate`（两者共用现有匹配器）；
  ② `query()` 支持 comptime 链式字面量一步出结果（或 `findWith(.{ .where = ..., .order = ..., .limit = ... })`）。
- **验收**：examples 的分页列表接口能用一行替代现在的循环手筛。

### P1-6 ORM 快照级事务（F-04）
- **现状**：无事务原语（F-04：多表写无法原子化，中途失败留脏数据）。
- **建议**：`store.begin()` 克隆当前行表作内存快照，`commit()` 释放快照，`rollback()` 恢复；
  多表用 `Transaction{ &a, &b }`。注释写清语义边界：进程崩溃不在保护范围（与 flush 同一语义）。
- **验收**：中途注入失败 → 两表都回到事务前状态。

### P1-7 Migration 执行器最小集（F-05）
- **现状（已核实）**：`schema.zig:97-142` 定义了 `MigrationOp`/`Migration`，但 `engine.zig` 全文无 `migrat` 命中——纯死代码。
- **建议**：`store.migrate(m)` 实现 `add_field`（补默认值）/`drop_field`/`rename_field` + `.version` 版本号；
  其余 op 返 `error.MigrationUnsupported`。**或反向决策：删掉 Migration 类型**避免误导（二选一，不建议维持现状）。
- **验收**：v1→v2 加字段后旧数据自动补默认值。

### P1-8 `http_cache` addon：动态响应条件请求
- **现状（已核实）**：static 已完整支持 ETag/Last-Modified/If-None-Match/304（`static.zig:145-172`）与 Range/206（`static.zig:183-218`），
  但只服务静态文件；动态 JSON 接口（仪表盘/列表）无法复用。
- **建议**：新 addon `http_cache`：自由函数 `res.conditional(etag)`（命中直接 304，不执行 handler body）；
  `ifNoneMatch` 等纯函数下沉到 http_protocol 复用。
- **验收**：同一请求发两次，第二次 304 且 handler 未执行（计数器断言）。

### P1-9 `http_metrics` addon：`/metrics` + `/healthz`
- **现状（已核实）**：`ServerStats`/`RuntimeState`（`config.zig:255-263`）已有运行数据原料，但没有对外端点。
- **建议**：① `/healthz` 返 JSON（存活/启动时长）；② `/metrics` 输出 Prometheus 文本格式：
  requests_total{route,method,status}、request_duration 直方图、active_connections；
  一个计数中间件 + 一个渲染 handler，纯文本拼接零依赖。
- **验收**：格式肉眼可辨；压测后计数与 bench 量级一致。

### P1-10 WebSocket 连接集合管理
- **现状（已核实）**：`WebSocket` 只管单连接；examples 自己维护连接数组做广播（`admin.zig` 通知推送），每个业务重复登记/摘除/广播/锁。
- **建议**：`ConnSet`：登记/摘除/`broadcast(text)/broadcastBinary`/`closeAll`，内部 Mutex，写失败自动摘除；与现有 hijack 模式配合（upgrade 后把 ws 登记进 ConnSet）。
- **验收**：两连接广播各收到一份；断连后集合无残留。

### P1-11 时间助手（F-22）
- **现状**：业务里到处手写 `std.time.milliTimestamp()` 与 HTTP date；`formatHttpDateForTest`（`static.zig:650`）只在测试用。
- **建议**：`http_app` 加自由函数 `nowUnixMs()/nowUnixSec()` + `formatHttpDate(buf, unix_sec)`/`parseHttpDate`，static 内部实现改用之。
- **验收**：往返测试（格式化→解析）；examples 删掉手写时间码。

## 四、P2：生态与 DX（不阻塞，想做再做）

1. **路由元数据 attrs（F-09/F-NEW-3/F-NEW-6）**：`Route` 加可选标签，404/405 路径也能拿到路由信息；日志埋点、P1-9 标签、OpenAPI 的共同前置。
2. **限流窗口升级（FRICTION 未提，盘点发现）**：现为固定窗口（`rate_limiter.zig:21,163`），窗口边界可被双倍突发；可选 sliding window 或 token bucket，配置项二选一。
3. **ORM 字段类型扩展（F-18）**：仅支持 int/float/bool/string（+optional）；嵌套结构可先走「JSON 字符串字段 + 存取助手」缓和，不扩 schema 类型系统。
4. **fuzz 测试**：对 HTTP 请求解析、multipart、WS 帧解码加模糊测试（协议层是攻击面，性价比最高的安全投入）。
5. **gen-api 增强**：现清单只到顶层符号；加 `--methods` 模式输出 struct 成员函数级列表，并接入 CI 做 diff 告警。
6. **OpenAPI 骨架生成**：基于第 1 项的路由元数据，从路由表导出 openapi.json 骨架（字段细节靠注解/手填）；demo 级不求全自动。
7. **zstd/brotli 压缩**：`Encoding` 现仅 gzip/deflate（`http_compress/root.zig:27-39`）；阻塞在 std 无实现，第三方库引入与否单独评估。
8. **CI 增强**：bench 阈值回归门、文档链接检查、PR 跑 examples 测试；zig 版本已在 ci.yml 钉死（0.18.0-dev.253，与 vendored zio 配套），升级前跑 zio+windows/linux 交叉编译验证（注释已写明）。
9. **`groupForPath` 线性扫描优化（F-NEW-1）**：只在 404/405 路径跑的 O(组数) 扫描，收益低，组数很多时再换前缀索引。
10. **examples 回归测试**：用 http_testing 给 `examples/src/app` 的 handler/中间件补测试（FRICTION 阶段只验证了框架层）。

## 五、明确不做什么（DECISION，重提前先读这里）

| 项 | 理由 | 重新考虑的触发条件 |
| --- | --- | --- |
| HTTPS/TLS | std TLS 未成熟，硬接有稳定性风险；生产用 nginx/Caddy 终止 TLS | std.crypto TLS 稳定后进 addon |
| 模板引擎 | 客户端渲染 + `res.html()` + JSON API 已够；第三方模板库可自接 | 不再重提 |
| SQL/Redis 等外部依赖进 core | 框架职责边界；外部存储一律走接口（见 P1-3 存储后端接口） | 不进入 core，只做 addon |
| 热重载 | zig build run 编译快；外部 watchexec 即可 | 不重提 |
| ORM 普通索引/SQL 化 | demo 级定位（ANALYSIS §3.3 + 历史 DECISION）；若 F-NEW-8 全表扫成为实测瓶颈，可加内存 hash 索引再评 | 实测成为瓶颈 |
| HTTP 客户端 | `std.http.Client` 直接可用，非框架职责 | 不重提 |
| 分布式 session/限流 | 单进程定位；多实例用网关层 | 不重提 |

## 六、与 FRICTION.md 对照表

| FRICTION | 去向 | FRICTION | 去向 |
| --- | --- | --- | --- |
| F-01/F-02/F-06/F-11/F-13/F-20/F-25 | ✅ 已解决（见 FRICTION 已解决表） | F-16 | P0-2 |
| F-03 | P0-1 | F-17/F-23/F-24 | 文档已覆盖（API.md §14） |
| F-04 | P1-6 | F-18 | P2-3 |
| F-05 | P1-7 | F-19/F-21 | P1-5 |
| F-07 | P1-1 | F-22 | P1-11 |
| F-08 | P1-2 | F-NEW-1 | P2-9 |
| F-09 | P2-1 | F-NEW-2 | 观察项：Router「注册期构建」前提靠约定，改配置类 API 时注意 |
| F-10 | P1-3 | F-NEW-3 | P2-1 |
| F-12/F-NEW-6 | 剩余一半并入 P2-1（路由元数据后才能做组级 404 体） | F-NEW-4 | P0-3 |
| F-14 | 维持现状：flush 时机是已知取舍（docs/API.md 已统一口径） | F-NEW-5 | 唯一约束局限，与「不做索引」绑定 |
| F-15 | 已用 §14 第 12 条约束覆盖 | F-NEW-7 | 文档口径：catch-all 组内非 GET 可能 405，按需用独立组规避 |
| | | F-NEW-8 | 见「不做 ORM 索引」行（瓶颈时重评） |

## 七、维护规则

1. 本文件是**活文档**：每次落地一条路线图项，同步更新状态列/删行，并同步 README / docs/API.md / FRICTION.md。
2. 新功能提案先查「五、明确不做什么」；表中项若要翻案，需给出实测理由并更新该表。
3. P0 项均为静默错误类真 bug，修复时附带回归测试；P1/P2 不强制排期，按兴趣与痛点驱动。
