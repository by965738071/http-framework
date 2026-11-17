# 代码审查问题记录

- **审查日期**：2026-11-16
- **审查范围**：`src/` 全部 15 个模块、`examples/`、`build.zig` / `build.zig.zon`
- **工具链**：Zig 0.18.0-dev.1124+2ecf4b5e2（std.Io 时代 API，依赖 `vendor/zio`）
- **方法**：分模块静态审查；所有 std API 用法逐条对照本机标准库源码（`/opt/homebrew/Cellar/zig-dev/0.18.0-dev.1124+2ecf4b5e2/lib/zig/`）核验；关键高危问题用探针程序实际复现；行号均已对照源文件确认
- **基线**：审查时 `zig build test --summary all` 全部通过（40/40）。下列问题均处于现有测试的盲区，未被 CI 捕获。

## 问题统计

| 严重度 | 数量 | 定义 |
|--------|------|------|
| 高 | 8 | 进程崩溃 / 数据不可逆损坏 / 编译炸弹 / 可复现越权 |
| 中 | 24 | 功能缺陷、资源可被耗尽、安全语义错误（有前提条件） |
| 低 | 54 | 边界错误、错误被吞、防御纵深缺口、文档-实现不符 |
| 信息 | 1 | 设计取舍注记 |
| **合计** | **87** | |

---

# 一、高严重度

## H-1 [http_orm] `?[]const u8` 字段走部分更新路径 = 编译错误（编译炸弹）
- **位置**：`src/http_orm/engine.zig:1731`、`src/http_orm/engine.zig:1733`（`prepareStringChanges`）
- **类别**：逻辑错误 / 编译期错误（已实测）
- **问题**：对 optional 直接 `switch (orig_opt)` / `switch (new_opt)`，本机编译器报 `error: switch on optional type '?[]const u8'`。只要任何模型含 optional 字符串字段且调用 `update`/`updateById`（实例化 `updateLocked → prepareStringChanges`），整个编译单元直接编译失败。现有测试全过，只是因为没有任何测试用 optional 字符串模型调过 update。
- **修复**：改为 `if (orig_opt == null) ... else { const orig_slice = orig_opt.?; ... }`；并补「optional 字段 + update」回归测试。

## H-2 [http_orm] float 字段为 NaN/Inf 时落盘非法 JSON，整张表永久打不开
- **位置**：`src/http_orm/engine.zig:1474-1477`（`appendJsonField` float 分支）
- **类别**：数据损坏 / DoS（已实测复现）
- **问题**：`{d}` 把 NaN 打成 `nan`、Inf 打成 `inf`，写入文件即非法 JSON；`std.json` 解析时报 `SyntaxError`。insert/update 对浮点值不做有限性校验，应用算出一次 `0.0/0.0` 并 flush 后，**下次 open() 永久失败，进程起不来**。实测：文件内容 `{"id": 1, "score": nan}` → reopen 报 `error.SyntaxError`。
- **修复**：insert/update/load 对 float 字段做 `std.math.isFinite` 校验（返回 `error.InvalidFloat`）；或序列化时把非有限值写成 `null` 并在 load 时映射回 NaN。

## H-3 [http_orm] load 默认值迁移会改写「存在但为零值」的字段，字符串默认值指向 rodata → 非法 free（挂死/UB）
- **位置**：`src/http_orm/engine.zig:264-277`（dup 循环）、`engine.zig:1294-1303`（`applyDefaults`）、`engine.zig:1305-1315`（`isZeroValue`）
- **类别**：内存错误（invalid free / UAF）+ 静默数据改写（已实测复现）
- **问题**：`needs_defaults` 是**行级**开关，但 `applyDefaults` 按 `isZeroValue` **字段级**改写——JSON 里存在但为空串/0 的字段也会被改成 schema 默认值；随后 dup 循环只 dup「键缺失」的字段，被覆写的字段留在 rodata 上，`close`/`delete`/`truncate` 的 `freeStringFields` 会 `free(rodata 指针)`。实测：文件 `{"id":1, "role":""}`（status 键缺失）加载后 `role` 被静默改成默认值，随后 `deleteById` 在 testing allocator 上挂死（GPA 下是 Invalid free panic / UB）。触发前提恰好是注释宣称支持的「加列迁移」场景。
- **修复**：把「键缺失」信息传入默认值应用逻辑（只对键缺失的字段应用默认值）；或 `applyDefaults` 之后对本行所有因默认值被改写的字符串字段统一 dup。

## H-4 [http_protocol/http_server] HEAD + Content-Length 请求 → std 断言崩溃，远程未认证 DoS
- **位置**：`src/http_protocol/request.zig:86-90`、`src/http_protocol/response.zig:73-80`（配合 `src/http_server/connection.zig:98-100`）
- **类别**：HTTP 协议正确性 / 可用性（已实测复现）
- **问题**：框架有意放行「HEAD 携带 `Content-Length: N>0`」（body 为 `.none`）。响应走 `prepareBodyNone` 时，HEAD 因 `requestHasBody()==false` 提前返回，reader 状态停留在 `.received_head`；随后 std `respond → discardBody(true)` 排空 0 字节后触发 `assert(r.state == .ready)`（`std/http/Server.zig:635`）。实测：发送 `HEAD / HTTP/1.1\r\nContent-Length: 5\r\n\r\n` 并正常 respond → 进程 `panic: reached unreachable code` 后 ABRT。Debug/ReleaseSafe 下**单个请求打死整个进程**；ReleaseFast 下断言消失，5 个未排空字节被当成下一个请求行解析——退化为请求走私。既有测试未覆盖是因为非 HEAD 方法走 bodyReader 排空路径。
- **修复**：在 `connection.zig:98-100` 的 keep-alive 决策处，对 `method == .HEAD and head.content_length != null` 强制 `response_keep_alive = false`（实测该路径 std 置 `.closing`，不触发断言）；更优方案是 respond 前手动排空 CL 字节保持连接复用。补 HEAD+CL 回归测试。

## H-5 [http_protocol/http_server] 流式 body 部分读取后正常响应 → 残留字节被解析为下一个请求（走私原语）
- **位置**：`src/http_protocol/request.zig:352-364`（`bodyReader`）、`src/http_server/connection.zig:136-146`（复用决策）
- **类别**：HTTP 协议正确性 / 请求走私（已实测复现）
- **问题**：handler 通过流式 reader 只读了部分 body 就返回并正常响应（keep-alive），std 的 `discardBody` 对 `.body_remaining_content_length` / `.body_remaining_chunk_len` 状态**直接 return 不排空**（`std/http/Server.zig:641`），而复用决策感知不到「body 没读净」。实测：POST CL=100，读 10 字节后 respond(keep-alive=true)，下一次 `receiveHead` 把残留 90 字节当请求行解析——攻击者把残留字节构造成合法请求行+头部即为经典 CL 走私原语。另外 `connection.zig:137-141` 注释宣称「std 0.18 起 discardBody 会自动消费残留字节」对 HEAD（H-4）和部分读取的流式 body 均不成立，属过期结论。
- **修复**：`processRequest` 返回后（136 行复用决策处）检查 `http_request.server.reader.state`，若仍为 `.body_remaining_*` 则强制 `response_keep_alive = false`。一行状态检查即可封死该原语；与 H-4 一并处理并修正过期注释。

## H-6 [http_app] `Context.readBody` 失败后二次调用 → 进程 panic（远程可触发）
- **位置**：`src/http_app/context.zig:263-274`（`readBody`）、根因在 `src/http_protocol/request.zig:283-346`（`readBodyInto`）
- **类别**：Context 生命周期 / 错误处理 / DoS
- **问题**：`readBody` 只在**成功**时写 `state.body_buffer`，失败路径不留任何「已尝试」标记。失败后第二次调用再次进入 `readBodyInto` 的 `.streaming` 分支：chunked 时跳过长度前置检查，直接 `readerExpectContinue` → std `readerExpectNone` 内 `assert(state == .received_head)` 失败（首次调用已把状态切到 body_remaining_*）。**Debug/ReleaseSafe 下整个进程 panic（一条请求打死全部连接）**，ReleaseFast 下是内存级 UB。触发面现实：中间件先 `readBody` 失败后放行、handler 再读一次，或 handler catch 413 后换更大 limit 重试。
- **修复**：`RequestState` 增加 `body_read_attempted: bool`，`readBody` 入口检查：已置位且 `body_buffer == null` 时直接返回缓存的 `body_read_error`，不再进入 `readBodyInto`。

## H-7 [examples] 注册接口明文存储密码，且与 admin 登录共享同一存储
- **位置**：`examples/src/register.zig:80`
- **类别**：认证 / 示例坏实践（可复现越权链的一环）
- **问题**：无认证的 `POST /api/register` 把明文口令写入 `data/admin/users.json`，该文件正是 admin 登录的凭证库（`examples/src/admin.zig:343` 用 `std.mem.eql` 明文比较）。示例自带的 `examples/src/app/core/password.zig` 已实现规范的 PBKDF2-HMAC-SHA256 + 随机盐 + `timing_safe.eql`，其注释甚至点名 admin.zig 的明文存储是遗留问题。
- **修复**：register/admin 全部走 `core.password.encode/verify`；示例不宜保留「明文演示」分支。

## H-8 [examples] admin 管理端点无角色门槛，与开放注册构成纵向越权链
- **位置**：`examples/src/main.zig:371-386`、`examples/src/admin.zig:439-474`
- **类别**：授权缺失 / 示例坏实践
- **问题**：`/admin/users` 等管理路由只挂 `requireAuth`（任何已登录会话即可），`userCreateHandler` 还直接接受客户端传入的任意 `role` 字段（无白名单）。结合开放注册（注册即得 viewer 会话），**任何自注册用户可以创建 admin 账号、增删用户、清空日志**。`admin.zig:250-251` 注释自己承认 `requireRole`「当前示例未挂载该中间件」。作为官方 admin 示范代码，展示的是坏的访问控制模型。
- **修复**：管理端点挂 `requireRole(.admin)`（或 app 层 `PermissionGuard`）；`role` 参数做枚举白名单校验。

---

# 二、中严重度

## http_orm

### M-1 部分更新无法把 nullable 字段置回 NULL：null 被静默写成零值
- **位置**：`src/http_orm/engine.zig:1586`（`setTypedField` 解包 optional）+ `engine.zig:603-604`；根源配合 `src/http_orm/query.zig:700-705`（`toFieldValue(null)` 产出零值）
- **问题**：`update_fields` 路径把 `query.data` 字段经 `FieldValue` 中转：`?[]const u8 = null` → `.string=""` → optional 变成 `SOME("")`；同理 `?int = null` → `SOME(0)`。**部分更新永远无法置回 NULL**，且无报错。（该路径因 H-1 暂时编译不过，运行时行为为代码级确认。）
- **修复**：对 optional 字段绕过 `FieldValue`，直接按字段名从 `query.data` 拷贝 optional 值。

### M-2 load 对恶意/损坏数据文件会 panic 而非报错
- **位置**：`src/http_orm/engine.zig:1623-1628`（`getFieldId` 的 `@intCast`）、`engine.zig:285-298`（`max_id + 1` 溢出）
- **问题**：① 模型 `id: i64` 时数据文件 `{"id": -5}` → `@intCast` 到 u64 → open() 时 panic；② `id: u64` 时超过 i64 的 JSON 整数 → `parseInt(u64)` 得 `maxInt(u64)` → `next_id = max_id + 1` 溢出 panic。
- **修复**：`getFieldId` 用 `std.math.cast(u64, ...)`，load 处把非正/溢出 id 归入 `error.CorruptData`；`next_id` 用 checked add。

### M-3 枚举字段加载：非法 tag 运行期 panic；「未知字符串回退 tag 0」对不从 0 起的枚举是编译错误
- **位置**：`src/http_orm/engine.zig:1452-1461`（`jsonValueToField` 枚举分支）（均实测）
- **问题**：① 数据文件 `{"kind": 3}`（枚举无 tag 3）→ `@fromBackingInt` 运行期 "invalid enum value" panic（ReleaseFast 是类型混淆 UB），发生在 open() 路径；② 字符串不匹配任何枚举名时回退 `@fromBackingInt(0)`，若枚举没有 0 号 tag 直接编译错误。
- **修复**：改用 `std.enums.fromInt(T, tag)`（返回 optional，无效值报 `error.CorruptData`）；字符串回退改为报 CorruptData。

### M-4 truncate 中 `initUniqueMaps` 失败后 store 进入永久损坏态：后续 insert/checkUnique 越界 panic
- **位置**：`src/http_orm/engine.zig:818-821`（truncate）、`engine.zig:1020-1029`（`initUniqueMaps`）
- **问题**：truncate 先 `destroyUniqueMaps()` 再 `try initUniqueMaps()`；后者 OOM 时行已清空、maps 归空切片，但 `unique_field_count > 0` 依然成立，此后任何 insert → checkUnique 都对空切片下标访问 → index out of bounds panic。open() 路径有 errdefer 兜底，truncate 没有。
- **修复**：先在局部分配好新 maps 再整体换入；或失败时保留旧 maps。

### M-5 `close()` 解锁后销毁：并发等待者醒来操作已释放内存（UAF）
- **位置**：`src/http_orm/engine.zig:153-169`
- **问题**：close 持锁清空 rows、释放 `data_dir`，然后 `unlock()` → `destroy(self)`。若此刻仍有线程阻塞在 `lock()`，`unlock` 的 futexWake 会唤醒它——它在已销毁的 mutex 上加锁成功并继续操作已 deinit 的数据 → UAF。
- **修复**：文档化「close 必须在外部与所有使用方同步」+ debug 断言；或引入 `closed` 标志在加锁成功后校验。

### M-6 字符串字段允许任意二进制（非法 UTF-8）落盘 → 下次 load SyntaxError，整表打不开
- **位置**：`src/http_orm/engine.zig:1533-1555`（`appendEscapedJson` 对 ≥0x80 字节原样直写）（实测）
- **问题**：`[]const u8` 字段存入非 UTF-8 字节时 flush 直写文件；`std.json` 对字符串做 UTF-8 校验，非法序列报 `SyntaxError` → 与 H-2 同构的「表变砖」。控制字符已正确转义，唯独缺 UTF-8 校验。
- **修复**：insert/update/load 校验字符串字段为合法 UTF-8（`std.unicode.utf8ValidateSlice`）；或文档强制「二进制走 base64」。

## http_router

### M-7 共享路由表：注册 API 与多线程 dispatch 之间无同步、约束未文档化
- **位置**：`src/http_router/router.zig:186-229`、`src/http_router/trie.zig:85-127`
- **问题**：`zio_server` 每个 worker 是真实 OS 线程，所有连接协程共享同一个 `*const Router`。并发 dispatch（只读）本身安全，但注册端没有任何互斥、断言或文档声明「必须在 serve 前完成注册」：运行期调 `router.route()` 会与其它线程正在进行的 `match` 数据竞争（ArrayList realloc → UB）。API 形状上这是完全合法的调用。
- **修复**：至少在 `Router` 文档头声明线程契约（注册期单线程；serve 后只读）；可加 debug-only 的 `sealed` 原子标志（`run` 启动时置位，注册 API 里 `assert(!sealed)`）。

## http_protocol / http_server

### M-8 慢速攻击（Slowloris）：per-op 超时 ≠ 头阶段总期限，连接可被无限占用
- **位置**：`src/http_server/zio_server.zig:328-329`、`src/http_server/std_server.zig:299-310`
- **问题**：两个后端的超时都是**单次 read 操作**级。`receiveHead` 内部循环 `fillMore`，客户端每隔小于 timeout 的时间滴 1 字节，头部阶段可无限延续——每条这样的连接长期占住读写缓冲和一个并发槽。攻击者用几百条连接即可耗尽内存/fd。
- **修复**：头部阶段传**绝对 deadline**（两边的超时抽象都支持 deadline 变体）——进入 `receiveHead` 前采样 `now + max_head_seconds`，头部读完后再恢复 per-op 超时；可选加每连接 `max_requests`。`connection.zig` 是后端无关层，deadline 逻辑放这里可两个后端一次修好。

### M-9 `flush()` 提前清空 cookies：无 body 缓冲响应的 Set-Cookie 被静默丢弃
- **位置**：`src/http_protocol/response.zig:216`（调用点）、`response.zig:220`（提前返回）、`response.zig:498`（清空）
- **问题**：`flush()` 在判断「是否真的要发送」**之前**调用 `addCookiesToHeaders()`，而该函数末尾无条件清空 cookies。缓冲模式下 handler 只设 cookie+status 不写 body → 中间件先调 `flush()` → cookie 被清空，随后因 `pending_body == null` 提前 return（什么都没发）→ 兜底发送时响应没有 Set-Cookie。注释声称「addCookiesToHeaders 幂等安全」，对「清空后早退」这个顺序不成立。
- **修复**：把 `addCookiesToHeaders()` 移到 pending_body/sent 判定之后、`sink.respond` 之前；补「缓冲模式 + 仅设 cookie + 中间件提前 flush」测试。

## http_logging / http_compress

### M-10 锁外 gzip 与下一次轮转竞态，可整档丢失归档
- **位置**：`src/http_logging/root.zig:436-441` + `558-601`
- **问题**：`rotate()` 在锁内 rename 出 `path.1` 后把路径记入 `pending_gzip`，`log()` 在**锁外**按**路径名**（而非 inode）执行压缩+删源，与下一次轮转的 shift rename 交错时：T1 压缩完 A 后 `deleteFile("path.1")` 删掉的可能是 T2 刚 rename 进来的新归档 B —— **B 的日志内容永久丢失**。默认 16 MiB 轮转阈值下高流量可触发。
- **修复**：rotate 在锁内把归档 rename 成唯一名（如 `{path}.1.{gen}`），压缩与删源都针对该唯一名；或把 `deleteFile(src)` 挪回锁内。

### M-11 文件写入失败被静默吞掉
- **位置**：`src/http_logging/root.zig:411-420`（含 pwrite 兼容路径 417-420）
- **问题**：`writeStreamingAll ... catch { unlock; return; }` 无任何记录。磁盘满、fd 失效等情况下所有日志**无声消失**，不降级到 stderr、不置 `file_paused`、无失败计数；对比轮转失败路径至少还有 stderr 降级，行为不一致。
- **修复**：写失败时向 stderr 打一条（限频提示），并考虑按错误类型决定是否 `pauseFileWrites()`。

## http_static

### M-12 TOCTOU：先按路径校验、后按路径打开
- **位置**：`src/http_static/static.zig:139`（关联 94、270、348、399）
- **问题**：防护顺序是 `statFile` → `realPathFile` 解析真实路径校验 → 之后**按路径**重新 `openFile`/`readFileAlloc`/`serveRange` 再 `openFile`。校验通过到 open 之间，对根目录有本地写权限者可原子 rename 换入指向根外的新符号链接，open 跟随后即读出根外文件。std 源码对 `realPathFile` 的文档明确警告该竞态。
- **修复**：每个请求只 open 一次，再对**已打开的 fd** 做 `file.stat(io)` 取 size/mtime，并通过 `/proc/self/fd/<fd>` realpath 或逐分量 `openat(..., O_NOFOLLOW)` 校验落点在根内；`serveRange` 复用同一 fd。

## http_security / examples

### M-13 CSRF Double-submit token 未绑定会话、登录后不轮换
- **位置**：`src/http_security/csrf.zig:49-62`、`106`
- **问题**：token 在任意 GET 无条件下发（无会话也可获取），验证只做 cookie/header 相等比较，与 session 无绑定，登录/会话轮换时不重新签发。`SameSite=Strict` 挡住跨站，但同站子域攻击者可通过 cookie tossing 同时固定 cookie 和 header 用自选 token 通过校验。
- **修复**：token 派生绑定会话（如 `HMAC(session_id, random)`）或登录成功后 rotate；校验时同时要求会话存在。

### M-14 `build.zig.zon` 的 `.paths` 遗漏 `vendor/` 与 `tools/`，url/hash 消费者构建必失败
- **位置**：`build.zig.zon:20-25`
- **问题**：`.paths` 只有 `build.zig`、`build.zig.zon`、`src`、`README.md`。但 build.zig 声明的 zio 依赖指向 `vendor/zio`，gen-api 工具在 `tools/`。以 url/hash 方式发布/消费本包时这两个目录不随包分发：http_server 编译失败（缺 zio），`zig build test` 因依赖 api_check 也失败。本地路径依赖不受影响，故日常开发发现不了。
- **修复**：`.paths` 补 `"vendor"` 和 `"tools"`；上游 zio 跟进后恢复 url 依赖时删除 vendor。

### M-15 examples 的 `RequireRoleMiddleware` 在用户不存在时 fail-open
- **位置**：`examples/src/admin.zig:284-302`
- **问题**：遍历用户匹配 session 用户名，匹配失败（用户被删、store 为空）时直接落到 `next.call` 不拒绝——与同文件 `RequireAuthMiddleware`（有 `found` 检查并 401）行为不一致。当前未挂载所以是潜伏缺陷，但复制该模板做 RBAC 的用户会继承一个 fail-open 的授权中间件。
- **修复**：循环未命中一律 `failWith(unauthorized)` 后 return。

### M-16 examples 的 logout 只清 cookie，不销毁服务端会话
- **位置**：`examples/src/main.zig:717-724`、`examples/src/admin.zig:390-397`
- **问题**：两个 logout handler 都只 `setCookieFull(max_age=0)`；服务端 session 仍有效，被窃取的旧 sid 可继续使用直到过期（1 小时）。框架已提供 `SessionManager.destroyFromRequest`，且 `examples/src/app/service/auth_service.zig:186-191` 演示了正确用法，但这两个入口用的是错误姿势。
- **修复**：logout 先调 `sessions.destroyFromRequest(ctx)` 再清 cookie。

### M-17 examples 沿用默认 `0.0.0.0` 监听，叠加弱凭据/明文 HTTP 暴露到 LAN
- **位置**：`examples/src/main.zig:127-132`（对照 `src/http_app/config.zig:199`）
- **问题**：示例未覆盖 `.address`，框架默认 `"0.0.0.0"`、端口 9000 对局域网开放。同一服务器上：硬编码 bearer token `demo-secret-token`（main.zig:361）、硬编码 `alice/secret` 明文凭据、session cookie `secure=false`（:153）、CORS 通配所有源（:236-237）、CSP 放开 `'unsafe-inline'`（:231）。文件头注释却写「访问 http://127.0.0.1:9000」，给人只在本地跑的错觉。
- **修复**：示例显式 `.network = .{ .address = "127.0.0.1" }`；bearer token 从环境变量读取。

### M-18 CORS `block_unauthorized=true` 的 403 短路路径缺 `Vary: Origin`
- **位置**：`src/http_security/cors.zig:54-59`
- **问题**：同一 URL 上允许的 origin 得到正常响应、被拒 origin 得到 403，响应随 Origin 变化，但 403 分支没像 60-69 行那样补 `Vary: Origin`（自己注释里陈述的防缓存投毒原则没有贯彻到底）。403 不在可启发式缓存状态码之列，实际风险低，属一致性问题。
- **修复**：block 分支 return 前同样调用 `addVaryOrigin`。

## http_app

### M-19 `RequestConfig.trust_proxy` / `body_size_limit` 是死配置，body 大小限制与执行脱节
- **位置**：`src/http_app/context.zig:214-217`（定义）；接线点 `src/http_server/connection.zig:169-172`
- **问题**：全仓库 grep 证实这两个字段只有定义和构造，**没有任何读取方**。后果一：`BodyConfig.trust_proxy_headers` 看似接线实则无效（限流器用自己的 `RateLimitConfig.trust_proxy`）。后果二：`Config.validate` 强制 `body.size_limit != 0`，但 `ctx.readBody` 的 limit 完全由 handler 手传，handler 传 `maxInt(u64)` 即完全绕过全局限制；`RequestConfig.body_size_limit` 的存在让人误以为有集中强制。
- **修复**：`readBody` 未显式传 limit（或传 0）时默认取 `self.config.body_size_limit`；或删掉死字段并把消费责任写进文档。

### M-20 `readBody` 接受任意 allocator，但成功缓冲永不释放——非 arena 调用即泄漏
- **位置**：`src/http_app/context.zig:263-274`（缓存）、`context.zig:139-154`（`RequestState.deinit` 不释放 `body_buffer`）
- **问题**：签名允许传任意 allocator；成功后 buffer 存入 `state.body_buffer`，而 `RequestState.deinit` 不释放它。`readBodyInto` 还会在传入 allocator 上分配 4096 字节 transfer buffer 挂到 std reader（生命周期长于函数，不能释放）。传请求 arena 时一切随 reset 回收（生产路径正确）；但传 gpa 的 handler 每请求泄漏 body 大小 + 4KB。契约只活在注释里。
- **修复**：签名去掉 `allocator` 参数、内部固定用 `self.arena`（`form`/`formDecoded` 已经是这个模式）；至少在文档与参数名上强制。

### M-21 `Config.validate` 缺失项：address 可解析性、buffer/上限类配置无上界
- **位置**：`src/http_app/config.zig:143-195`
- **问题**：validate 对数值只查「== 0」：① `network.address` 不做字面量可解析性检查（`IpAddress.parseLiteral`），非法字符串拖到 listen 才报错；② `http.read_buffer_size` / `write_buffer_size` 是**每连接**分配，无上限意味着配成 4GB 时 1024 连接直接 OOM；③ `pool.request_arena_retain_bytes`、`network.max_connections` 同样无上界。注释声称「新增配置字段应在此登记规则」，这几项恰好漏登记。
- **修复**：validate 里补 `IpAddress.parseLiteral` 预检（IPv6 需处理 `[..]` 形式）；给 buffer/retain/max_connections 设合理上界。

## http_websocket / http_session / http_rate_limit

### M-22 WS Origin 校验默认关闭，且配置白名单后无 Origin 头仍放行（CSWSH）
- **位置**：`src/http_websocket/handshake.zig:58`、`69-76`
- **问题**：`allowed_origins` 默认 `null` = 完全不校验 Origin；即使调用了 `setAllowedOrigins`，`isOriginAllowed` 对**缺失 Origin 头的请求直接放行**。握手无任何其他 CSRF 类校验，而浏览器发起 WS 会自动附带 cookie——若与 `http_session` 搭配做鉴权，默认配置下攻击页面 `new WebSocket("ws://victim/api/ws")` 即可以受害者身份建立连接。对比常见实现（gorilla/websocket 默认要求 Origin host == Host，无 Origin 也拒绝）明显宽松。
- **修复**：提供 `origin_mode` 配置（`deny_missing`/`allow_missing`），默认拒绝缺失 Origin 或至少显著警告；生产示例必须展示 `setAllowedOrigins`。

### M-23 限流 records 无条目数上限、identifier 未限长
- **位置**：`src/http_rate_limit/rate_limiter.zig:318-335`（无容量检查）、`:328`（`dupe` 无长度限制）、`:191-217`（清理只删过期条目，不控总量）
- **问题**：每个唯一 identifier 创建记录并 dup key。`trust_proxy=true` 时 XFF 值完全客户端可控（任意长、任意多唯一值）；即使 `false`，IPv6 单一 /64 也能产生海量唯一源 IP。清理周期 = 窗口长度，**单窗口内 map 可无限增长**（1M 唯一 key ≈ 数百 MB），`maybeCleanupLocked` 还要在锁内做全表 O(n) 扫描。session 侧有 `max_sessions=100_000` 上限，防 DoS 组件自身反而缺少 DoS 约束。
- **修复**：增加 `max_records` 上限，满员时采样驱逐（可复用 session.zig 的 `evictSampledLocked` 模式）；identifier 截断（如 ≤64 字节）。

### M-24 WS 默认单帧/消息上限 16MB，组装期双倍驻留
- **位置**：`src/http_websocket/frame.zig:142`（`DEFAULT_MAX_PAYLOAD = 16MB`）、`src/http_websocket/connection.zig:77-79`、`262-263`、`366-375`
- **问题**：`receive()` 组装消息时 `f.payload`（≤16MB）与 `payload_list`（≤16MB）同时驻留，ArrayList 扩容瞬间还有第三份，**单连接峰值 ≥32MB**。1000 个并发连接各推一个 16MB 帧 → 32GB 分配请求 → OOM。默认阈值对服务端过于宽大，且消息级与帧级同值放大了组装开销。
- **修复**：默认降到 1–4MB 并允许配置；`appendBounded` 改为流式消费（decode 支持分段读 payload 直写 list），消除双份驻留。顺带可修掉 `frame.zig:133-134` 掩码路径逐字节 `writeByte` 的热路径开销。

---

# 三、低严重度

## http_orm

### L-1 唯一索引维护里的 OOM 被 `catch return` 静默吞掉：约束悄然失效/误报 + key 泄漏
- **位置**：`src/http_orm/engine.zig:1059`、`1078`、`1100`、`1111`（register/unregister）、`1172`、`1179`、`1198`（buildUniqueIndexes）
- **问题**：`ensureUnusedCapacity` 只保证 map 容量，`fieldValuesKey`/`groupKey` 的 `allocPrint` 仍可 OOM。register 吞错 → 行已提交但索引缺项 → 后续同值 insert 不再报 UniqueViolation（静默违反约束）；unregister 吞错 → 残留旧 key → 后续同值写入被误拒 + key 泄漏到 close。
- **修复**：把 key 预分配纳入可失败段；或把 register/unregister 改为可失败并上抛。

### L-2 `number_string` 解析失败静默变 0 / 0.0
- **位置**：`src/http_orm/engine.zig:1423`、`1429`
- **问题**：数据文件畸形数字解析失败时静默落成 0/0.0，与同函数其它分支报 `error.CorruptData` 的策略不一致。
- **修复**：`catch return error.CorruptData`。

### L-3 writeFile：rename 后未 fsync 目录 → 崩溃时 rename 本身可能不持久；残留 .tmp 永不清理
- **位置**：`src/http_orm/engine.zig:358-360`
- **问题**：文件内容 fsync 了，但目录项（rename 结果）没有 fsync——掉电后可能回退到旧文件，绕过整套 tmp+fsync+rename 的设计目标；进程在 rename 前崩溃会永久留下 `*.json.*.tmp` 垃圾文件。
- **修复**：rename 后打开父目录 fsync；open() 时顺带清理同目录 `.{table}.json.*.tmp`。

### L-4 load 上限 100MB，flush 无上限：超过 100MB 的表 flush 后永久无法 reopen
- **位置**：`src/http_orm/engine.zig:205`（`.limited(100MB)`）vs `engine.zig:309-334`
- **问题**：flush 能写出 >100MB 的文件，下次 open() 报 `StreamTooLong` 失败，且因 open 失败连 truncate 补救都做不到。
- **修复**：flush 时按同一上限校验（超限报错而不是写出去），或上限常量共享 + 文档说明。

### L-5 整数条件值与浮点条件值混用：静默不匹配任何行
- **位置**：`src/http_orm/query.zig:492-496`（`evaluateCondition` 的 `.integer` 分支 `else => false`）
- **问题**：`where(.Gt, "age", .{ .float = 25.5 })`（u32 字段）恒为假；`compareValues`（排序用）已统一做 int↔float 提升，`evaluateCondition` 没跟上。
- **修复**：`evaluateCondition` 复用 `compareValues` 或对数值分支做一致提升。

### L-6 `isZeroValue` 设计：显式零值无法存储（insert 路径）
- **位置**：`src/http_orm/engine.zig:381` + `engine.zig:1294-1315`
- **问题**：insert 时 `active=false` 而 schema 默认 `true` → 被静默改写；默认值非零的 int 字段永远存不进 0，字符串字段存不进空串。零值与「未设置」不可区分是该方案的固有缺陷，但缺明确逃生通道。
- **修复**：文档明示 + 推荐 optional 字段表达「未设置」。

### L-7 跨进程并发无文件锁：多进程同时打开同一表 = 后写者覆盖前写者
- **位置**：`src/http_orm/engine.zig:336-361`
- **问题**：进程 A load → B load → A flush → B flush → A 的写丢失，无任何检测（tmp 名注释自述考虑了「多进程并发写」，但 read-modify-write 全程无 flock）。
- **修复**：open 时对表文件加 flock（或锁文件），或文档明确单进程约束。

### L-8 手写 schema 与 T 字段名不一致时运行期 panic（而非编译错误）
- **位置**：`src/http_orm/query.zig:626-629`（`getFieldValue` @panic），经 `engine.zig:1059/1100/1297` 可达
- **问题**：`JsonStore(T, schema)` 的两个 comptime 参数独立；手写 schema 写错字段名编译通过，运行到 insert/load 即 panic。
- **修复**：在 `JsonStore` 定义处加 comptime 校验（schema 每个字段名必须 `@hasField(T, name)`）。

## http_router / http_codec

### L-9 `RouteGroup.use` 两步 append 非原子，OOM 时中间件泄漏
- **位置**：`src/http_router/router.zig:64-71`
- **问题**：第 65 行先把中间件挂进组链（dispatch 生效），第 70 行才登记所有权（deinit 释放依据）。第二步 OOM 失败时中间件已进入 dispatch 链但不在所有权表里 → `Router.deinit` 永不调它的 deinit。
- **修复**：先登记所有权、成功后再挂组链；或对第一步加 errdefer 回滚。

### L-10 `Trie.insert` 遇 `RouteConflict` 半途失败会留下幽灵节点
- **位置**：`src/http_router/trie.zig:94-102` + `180, 188, 199, 203`
- **问题**：冲突路径没有「注册失败不留半态」保护：如注册 `/z/a/:x` 时 `/z`、`/z/a` 是新建节点，走到 `:x` 才撞上已存在的不同名参数返回冲突，静态链永久留在树里。影响仅限 arena 内存（幽灵节点不会误命中），但与文件自己声明的意图不一致，且测试未覆盖。
- **修复**：`findOrCreateChild` 增加 lookup-only 预扫模式；或记录本次新建节点、错误时从 parent 的 children 摘除。

### L-11 `registered` 按 Handler 值线性去重 → 注册期 O(n²)
- **位置**：`src/http_router/trie.zig:109-118`
- **问题**：每次 insert 全量扫描 `registered` 逐个 `std.meta.eql`。去重只对 factory handler 有意义（防 FactoryCtx 被_deinit 两次），`func`/`singleton` 的 deinit 是 no-op，重复登记无害。上万路由时注册期开销可感知。
- **修复**：只对 `.factory` handler 做去重，或换 HashMap 按位模式去重。

### L-12 `groupForPath` 平局判定用未 trim 的 prefix 长度，与段对齐语义不一致
- **位置**：`src/http_router/router.zig:380`（vs `:129`、`:369-372` 注释）
- **问题**：`/api` 与 `/api/` 在 `pathHasPrefix` 语义下等价，但平局「取最先注册」用原始长度：后注册的 `/api/`（len 5）会赢过先注册的 `/api`（len 4），与注释声明的行为相悖，404/405 会跑到错误组的中间件上。
- **修复**：比较前统一 trim 尾部 `/` 的长度，或注册期归一化 prefix。

### L-13 `Trie.match` 是公开 API 却没有段数/递归深度防护
- **位置**：`src/http_router/trie.zig:234-238`（`matchNode` 按段非尾递归）；对比 `router.zig:241-243` + `101-113`
- **问题**：`MAX_PATH_SEGMENTS=64` 的栈防护只存在于 `Router.dispatch`。`Trie` 经 `http_router/root.zig` 公开导出，绕过 Router 直接用 `Trie.match` 时超长路径递归深度不受限，协程栈下可被打穿。
- **修复**：把段数上限检查移进 `Trie.match` 本身。

### L-14 `parseJson` 对深嵌套 JSON + 可递归类型 T 无深度限制（条件性）
- **位置**：`src/http_codec/root.zig:39-47`
- **问题**：已核实 std 的 json Scanner/Value 解析是迭代的，**扁平 DTO 不受影响**；但当业务 T 可递归（`[]Node`、`?*Node` 自引用）时，`innerParse` 按输入嵌套深度递归，默认 1MiB limit 下约可构造 10 万层嵌套，在 zio 协程栈（池化、容量有限）上可溢出。
- **修复**：`parseJson` 文档注明约束；或预扫 `[[[` 深度上限。

## http_server

### L-15 `integration_test.zig` 测试盲区
- **位置**：`src/http_server/integration_test.zig`
- **问题**：缺以下恰好对应 H-4/H-5/M-8 的场景：① HEAD + Content-Length（正是这个盲区让 panic 漏网）；② 流式 body 部分读取 + keep-alive 复用；③ `Expect: 100-continue` 端到端（框架强依赖 `readerExpectContinue`，却无端到端验证）；④ chunked 请求 body 上传（含中途 `BodyTooLarge`）；⑤ HEAD 响应线上格式；⑥ `run()` 循环里 `writeError` 的裸 400/431 路径；⑦ hijack 路径。
- **修复**：优先补 ①②（直接封堵两个高危回归），其次 ③④。

## http_logging / http_compress

### L-16 `init` 失败路径泄漏 `owned_path`
- **位置**：`src/http_logging/root.zig:226-227`
- **问题**：`openLogFile` 失败（目录创建失败/无权限）时 `self.owned_path` 无 errdefer，泄漏。
- **修复**：`errdefer allocator.free(self.owned_path.?); self.owned_path = null;`

### L-17 `deinit` 关闭 fd 后未置 `file_paused`，并发 `log()` 仍会写已关闭 fd
- **位置**：`src/http_logging/root.zig:232-245`
- **问题**：`deinit` 持锁 close 后即解锁，再释放 `owned_path`。并发 `log()` 在解锁后拿到锁读到 `file_paused == false`，向已关闭 fd 写（fd 号可能已被其它 open 复用，字节落进无关文件）。
- **修复**：`deinit` 持锁期间先 `self.file_paused = true` 再 close。

### L-18 异常系统时钟导致 panic
- **位置**：`src/http_logging/root.zig:635`、`639-646`
- **问题**：① `EpochSeconds{ .secs = @intCast(ts) }`（`secs: u64`），时钟被设到 1970 前时 `@intCast` panic；② `bufPrint(...) catch unreachable`，年份 > 9999 时 `NoSpaceLeft` panic。日志库不应因时钟异常崩掉服务器。
- **修复**：`ts = @max(ts, 0)`；bufPrint 失败时返回固定占位串。

### L-19 用 `.real` 墙钟测请求耗时
- **位置**：`src/http_logging/root.zig:816-826`
- **问题**：`Timestamp.now(.real)` 两次相减算 `duration_ns`：NTP 步进/改时钟会得到负值或虚高数倍。std 已提供单调钟 `.awake`。
- **修复**：duration 改用 `.awake`；墙钟只用于 `ts` 字段。

### L-20 `.limited(cap)` 边界 off-by-one
- **位置**：`src/http_logging/root.zig:563-572`
- **问题**：已核 std `Reader.zig:375-392`：读满 limit 即返回 `StreamTooLong`（"reached or exceeded"）。归档恰好 `cap` 字节时两次读取都失败，该归档永远压缩不了。
- **修复**：`cap + 1`。

### L-21 `.gz` 归档写入非原子
- **位置**：`src/http_logging/root.zig:581-597`
- **问题**：`createFile(.truncate = true)` 后直接写：中途失败留下部分写入的 `path.1.gz`，而 rotate 的 shift 对 `path.N.gz` 无条件 rename 上移——损坏归档会被当作有效备份保留甚至上移。
- **修复**：写 `*.gz.tmp` 完成后 rename 到终名。

### L-22 压缩响应「先换 body 后挂头，且头失败被吞」→ 发出无 `Content-Encoding` 的 gzip 体
- **位置**：`src/http_compress/root.zig:150-154`
- **问题**：`header()` 失败（arena OOM）被 `catch {}` 吞掉，随后 `flush()` 把压缩字节按 identity 语义发给客户端——响应损坏而非降级。
- **修复**：先挂头（任一失败则不替换 body、直接 flush 原文），再 `replacePendingBody`。

### L-23 压缩中间件默认 `max_size = 0`（不设上限）
- **位置**：`src/http_compress/root.zig:67`
- **问题**：缓冲模式峰值约 3× body（dupeOwned 拷贝 + Allocating 输出 + 终品 dupe），旧 body 由 `owned_strings` 持有到请求结束。默认值下对意外巨大的响应（代理转发、handler 失控拼接）无保护。
- **修复**：默认给个如 8 MiB 的上限，`0` 留给显式关闭。

## http_static / http_multipart / http_testing

### L-24 请求带 `If-None-Match` 时仍评估 `If-Modified-Since`（违反 RFC 9110 §13.2.2）
- **位置**：`src/http_static/static.zig:162-168`
- **问题**：`inm_match == false`（INM 存在但不匹配）时仍评估 IMS（条件是 `!inm_match` 而非「INM 头不存在」），可能对本应 200 的请求返回 304。
- **修复**：改为「仅当 `If-None-Match` 头不存在才评估 IMS」。

### L-25 找不到有效首分隔符时静默返回空表单
- **位置**：`src/http_multipart/root.zig:199`
- **问题**：垃圾 body、boundary 不匹配、纯 LF 行尾的 body 都返回**成功的空 FormData**，调用方无法区分「空表单」和「无法解析」；而首分隔符存在但截断的情况却报 `TruncatedBody`，语义不一致。
- **修复**：返回新错误（如 `error.MalformedBody`），或文档标注该行为。

### L-26 testing 的 `req()` 不清空 `req_body`，第二次请求静默携带上一次的 body
- **位置**：`src/http_testing/root.zig:213-221`
- **问题**：`req()` 清空 `head` 但不重置 `req_body`；第二个请求带上旧 body 却没有对应 Content-Length 头。`reqBody` 被调用两次时还会写入重复的 Content-Length 头。
- **修复**：`req()` 开头加 `self.req_body = null;`；`reqBody` 防重复 Content-Length。

### L-27 `NotDir`/`SymLinkLoop` 等错误落入 else → 500 + 每请求一条 err 日志
- **位置**：`src/http_static/static.zig:104-109`
- **问题**：`GET /static/existing-file.txt/`（对已存在文件追加尾斜杠）时 `statFile` 返回 `error.NotDir`，落入 else 回 500 并 `std.log.err`。攻击者可零成本刷错误日志，且语义应为 404。
- **修复**：`error.NotDir` 映射为 404；`SymLinkLoop` 等映射为 400/404，仅真服务器错误留 500。

### L-28 目录重定向丢弃 query string
- **位置**：`src/http_static/static.zig:120-123`
- **问题**：`/static/dir?a=1` → 302 到 `/static/dir/`，query 丢失（nginx 等实现会保留）。
- **修复**：`loc` 后追加 `ctx.request.query`（非空时拼 `?query`）。

### L-29 `X-Content-Type-Options: nosniff` 仅对 SVG 设置
- **位置**：`src/http_static/static.zig:187-190`
- **问题**：若同一根目录承载用户上传（代码对 SVG 的处理说明该场景在威胁模型内），存储型 XSS 只挡了 SVG 一种；nosniff 对静态服务无副作用。
- **修复**：所有静态响应统一追加。

### L-30 媒体类型前缀匹配未校验子类型边界
- **位置**：`src/http_multipart/root.zig:153`
- **问题**：`startsWithIgnoreCase(ct, "multipart/form-data")` 会放行 `multipart/form-database; boundary=x`——与本项目在 M13/M17 修掉的是同一类前缀边界 bug。
- **修复**：校验第 20 个字符是 `;`、空白或串尾。

### L-31 testing 的 capturingSink 对 HEAD 不省略 body
- **位置**：`src/http_testing/root.zig:82-95`
- **问题**：生产路径 std 会按 `method == .HEAD` elide body，harness 无 HEAD 感知，HEAD 请求的 `h.body()` 仍有字节，用 harness 写的 HEAD 断言在生产不成立。
- **修复**：`req(.HEAD, ...)` 时把 method 传入 sink 或清空捕获 body；或文档明示该偏差。

### L-32 testing 的 dispatch 成功时 flush 错误仍被吞掉
- **位置**：`src/http_testing/root.zig:300`
- **问题**：`res.flush() catch {}` 在 `dispatch_err == null` 时把 flush 失败（如 OOM）也静默丢弃，测试可能带着残缺 wire 通过。
- **修复**：`if (self.dispatch_err == null) try res.flush();`

## http_security / examples

### L-33 HSTS 默认不发（null），且缺现代安全头配置项
- **位置**：`src/http_security/security_headers.zig:15`
- **问题**：HSTS 需使用者自行发现并配置；也没有 COOP/CORP/COEP 配置项。默认 CSP 未含 `object-src 'none'`、`base-uri`、`frame-ancestors` 等加固子句。
- **修复**：文档给出生产推荐值（`max-age=31536000; includeSubDomains`），考虑补 Cross-Origin-* 头配置。

### L-34 CSRF `token_length` 无下限
- **位置**：`src/http_security/csrf.zig:28`
- **问题**：默认 32 字节足够，但允许配成 1（仅 8 bit 熵）；溢出回归测试防了上限没防下限。
- **修复**：`generateToken` 内 clamp `@max(token_length, 16)`。

### L-35 `api_key_query` 的 query 参数名硬编码且该特性本质是明文泄露面
- **位置**：`src/http_security/auth.zig:220-228`、`277`
- **问题**：一次性 WARN（好），但 `?api_key=` 键名硬编码，与可配置的 `api_key_header` 不一致；密钥会进访问日志/浏览器历史/Referer。`AuthInfo.api_key` 还会被下游回显（`examples/src/main.zig:746`）。
- **修复**：键名跟随配置或单独配置；文档标注仅限开发环境。

### L-36 examples 的 `offset + limit` u64 溢出 panic
- **位置**：`examples/src/admin.zig:535-543`
- **问题**：两者均为 query 解析的 u64，`?offset=18446744073709551615` 时整数溢出，Debug/ReleaseSafe 下 panic（已登录管理员可触发 DoS；ReleaseFast 回绕后可能切片 start>end panic）。
- **修复**：饱和计算（先 clamp offset 到 `logs.len`，再 clamp limit）。

### L-37 examples 上传文件用客户端文件名直接写入进程 CWD
- **位置**：`examples/src/main.zig:595-601`
- **问题**：`safeBaseName()` 挡住了路径穿越，但 `createFile(.cwd(), ...)` 会截断覆盖 CWD 下任意同名文件（如 `build.zig`、`data/*.json`）。
- **修复**：写入专用 uploads 子目录 + 随机文件名 + 扩展名白名单。

### L-38 examples 把会话 ID 回显进响应体
- **位置**：`examples/src/main.zig:695`
- **问题**：`res.json(.{ .ok = true, .session = session_id })` 把 sid 写进 body，会进代理/日志/前端调试记录，HttpOnly 形同虚设。
- **修复**：删除该字段；调试走受保护的 `/session/me`。

### L-39 examples 整体未挂载 CSRF 中间件
- **位置**：`examples/src/main.zig:312-314`、`examples/src/admin.zig:353`
- **问题**：框架自带 `CsrfMiddleware`，但示例所有状态变更端点都没挂，只靠 sid cookie 的 `SameSite=Lax`（挡不住 same-site 攻击面与登录 CSRF）。
- **修复**：示例至少在会话登录/admin 组挂上 CsrfMiddleware，顺带演示用法。

### L-40
 CORS/auth 测试盲区 + examples 测试游离于根 CI 之外
- **位置**：`src/http_security/cors.zig:220-269`、examples 测试
- **问题**：cors.zig 只测了两个 helper，`process()` 全路径（预检短路、白名单反射、block 403、通配+credentials 降级）没有端到端测试；auth.zig 的 `checkApiKey` 路径无测试；examples 包的测试独立于根 `zig build test`，CI 若只跑根目录会漏掉。
- **修复**：为 CORS 补 harness 测试（仿 auth.zig 的 AuthTestEnv 套路）；CI 中加跑 examples 测试。

## http_app

### L-41 `RequestState.poisoned` 是死字段
- **位置**：`src/http_app/context.zig:127`
- **问题**：全仓库无任何读写（连赋值都没有），暗示存在「投毒」机制实则没有，易误导维护者。
- **修复**：删除，或补上写入点。

### L-42 `ErrorRenderer` 在 `res.sent` 时静默吞错，无日志
- **位置**：`src/http_app/error.zig:120`
- **问题**：handler 已写过响应后再抛错时，错误被无声丢弃；同函数其它路径都有日志，唯独这条没有任何痕迹。
- **修复**：return 前补一条 warn 日志。

### L-43 `TimingMiddleware` 成功路径对 header 写入用 `try`，与错误路径的 best-effort 风格自相矛盾
- **位置**：`src/main.zig:274`（对照 267-270）
- **问题**：错误路径刻意做「锦上添花」，成功路径的 `try res.header(...)` 却可能把一次**已成功**的响应变成错误传播。
- **修复**：与错误路径同口径 `catch {}`。

### L-44 middleware.zig 文档示例使用不存在的 `.monotonic` 时钟
- **位置**：`src/http_app/middleware.zig:22`、`24`
- **问题**：本工具链 std 的 `Clock` 枚举只有 `real / awake / boot / cpu_process / cpu_thread`，没有 `.monotonic`。用户照抄文件头示例即编译错误。项目其它处用的 `.awake` 才是正确成员。
- **修复**：示例改为 `.awake`。

### L-45 `applyEnv` 重复调用时字符串字段泄漏前一次 dupe
- **位置**：`src/http_app/config.zig:47-50`、`93-98`
- **问题**：字符串字段每次覆盖都 dupe 新内存，旧值指针直接丢弃。对同一 target 调两次 `applyEnv`（先 profile 默认再 env 覆盖是注释宣传的用法）就泄漏前一轮字符串。
- **修复**：文档标注「对同一 target 只应调用一次」。

### L-46 `Pipeline(N).set` 覆盖已有位置时旧中间件实例泄漏（已文档化的取舍）
- **位置**：`src/http_app/middleware.zig:227-242`
- **问题**：`idx < len` 时直接覆盖，旧 `Middleware` 值的 destroy 钩子永不执行——带 deinit 的中间件被 set 覆盖即泄漏。注释已声明「需要换中间件请重建管道」；若未来有人依赖 set 做热替换会踩中。
- **修复**：覆盖前对旧值调用 `mw.deinit()`，或编译期断言禁止覆盖。

## http_websocket / http_session / http_rate_limit

### L-47 子协议协商完全缺失
- **位置**：`src/http_websocket/handshake.zig:83-123`、`145-148`、`263-269`
- **问题**：既不读取也不回显 `Sec-WebSocket-Protocol`。RFC 6455 §4.2.2 允许不选子协议完成握手，故不构成协议违规，但库无协商能力，多协议端点无法使用。
- **修复**：`upgrade()` 增加可选的子协议选择回调或白名单参数。

### L-48 `closed` 标志无同步；close 后仍可发数据帧
- **位置**：`src/http_websocket/connection.zig:213`、`297-316`、`190-196`、`144-151`
- **问题**：`closed` 的检查在 `send_mutex` 之外。读循环收到对端 close 正在回应时，用户任务并发调 `close()` 会读到 `false`，两个任务各发一个 close 帧（违反 RFC 6455 §5.5.1）；close 握手发起后 `sendText` 等不拦截，可写出 close 之后的数据帧。
- **修复**：把 `closed` 检查+置位移入 `send_mutex` 临界区；发送数据帧前检查 `closed` 返回 `error.ConnectionClosed`。

### L-49 协议错误路径静默断连，不发 1002 close
- **位置**：`src/http_websocket/connection.zig:266`、`269`、`272`、`276`、`291`、`325`、`335`、`343` 及 `decode` 失败路径（262）
- **问题**：RSV 位非零、控制帧未分片、未 mask、close payload 长度 1、continuation 无首帧等所有协议错误都直接返回错误裸断 TCP。RFC 6455 §7.1.7 要求失败连接时以 close 帧（1002/1007/1009）完成关闭握手；与既有 `MessageTooBig`→1009、`InvalidUtf8`→1007 的处理不一致。
- **修复**：各 `ProtocolError` 出口统一 `closeWithCode(1002) catch {}` 后再返回错误。

### L-50 `upgrade()`/`handshake()` 声称「已写好错误响应」，但缺头场景什么都没写
- **位置**：`src/http_websocket/handshake.zig:217-218`（文档）对照 `85-102`（实现）
- **问题**：只有 Origin 失败写 403、版本失败写 426；其余失败路径返回 false 且响应为空，按文档直接 return 的 handler 会被 `processRequest` 兜底发**空 200**——升级失败路径返回错误状态码的承诺落空。
- **修复**：每个失败分支统一写 400；或至少修正 doc 注释。

### L-51 `setUnsupportedVersion` 失败被 `catch {}` 吞掉
- **位置**：`src/http_websocket/handshake.zig:114`
- **问题**：写 426 头失败（OOM）时静默降级为无响应，与 L118 的 `try` 不一致。
- **修复**：改为 `try`，让错误随 `handshake` 的错误集传播。

### L-52 会话驱逐按 `created` 而非最近活跃，滑动续期下会误逐活跃会话
- **位置**：`src/http_session/session.zig:231-249`（`evictSampledLocked` 按 created 找最旧）与 `:98`（滑动续期只更新 expires）
- **问题**：长期活跃的老会话（每次访问续期但 `created` 不变）永远是最旧候选，满员时优先被驱逐的是活跃用户而非空闲会话，「近似 LRU」实际近似 FIFO。
- **修复**：续期时同时更新 `created`，或新增 `last_access` 字段作为驱逐键。

### L-53 `setData` 无 value 大小限制
- **位置**：`src/http_session/session.zig:201-222`
- **问题**：`max_sessions` 限条数不限字节，单条 value 可为请求体任意大小。攻击前提是应用把用户输入写进 session，属纵深防御缺口。
- **修复**：`SessionConfig` 增加 `max_value_size`，超限返回 `error.ValueTooLarge`。

### L-54 过期清理全表 O(n) 扫描在全局互斥锁内执行
- **位置**：`src/http_session/session.zig:275-303`；`src/http_rate_limit/rate_limiter.zig:195-217`
- **问题**：两处 cleanup 都在全局锁内做全表迭代（session 每 300s 一次、限流器每窗口一次）。10 万条目时单次扫描为毫秒级持锁操作，期间所有请求的 session/限流判定串行排队，形成周期性延迟毛刺（也是可预测的放大点：清理触发前集中灌入接近上限的条目）。
- **修复**：过期时间组织成最小堆/时间轮，或分片 records，清理只扫单个分片。

## 信息 / 设计注记

### I-1 multipart 的 body 整体缓冲进内存
- **位置**：`src/http_multipart/root.zig:160`
- **说明**：`from(ctx, limit)` 经 `readBody` 把整个 body 缓冲进请求 arena（CL 与 chunked 的 limit 均正确执行，无无限读取），但内存占用 = `limit × 并发连接数`（10MB × 1000 连接 = 10GB），无磁盘落盘选项。属设计取舍，建议文档标注或提供全局并发上传预算。

---

# 四、已排查、确认无问题的方面

为避免重复排查/误报，以下方面已逐项核验（对照 std/zio 源码及运行探针）：

- **http_orm**：`matches` 的 AND/OR 折叠语义；`tableFilePath` 路径穿越防护；`findAll`/`updateLocked`/`deleteLocked` 的 errdefer 与两阶段所有权编排（无泄漏/UAF）；`likeMatchRecursive` 算法；无 SQL 注入面（无 SQL 拼接）。
- **http_router/http_codec**：Handler/Middleware/notFound 的所有权去重释放（无 double-free）；路径参数回滚与优先级（静态 > :param > *）；请求路径以 `:`/`*` 开头无注入面；405 短路、尾斜杠容错、HEAD→GET 回退；`bindQuery` 的双形状兼容写法；所引用的 std API（`mem.trim*`、`json.parseFromSliceLeaky`、`ascii.startsWithIgnoreCase`、`enums.EnumMap` 等）全部与 0.18.0-dev 匹配。
- **http_protocol/http_server**：`work_buf` 悬垂（std 两次请求间不解引用 transfer buffer，安全）；`TimedReader/TimedWriter` 与 std vtable 逐字段一致；`sigaction` 在 0.18-dev 存在且用法正确；fd/内存回滚严格 LIFO；关机顺序正确；arena `.retain_with_limit` 语义正确；`toPeerIp` 字节序正确；CRLF/大小写/CL+TE 冲突由 std 承担且被正确利用。
- **http_app**：arena 每请求重置时机安全（hijack 回调在 `endRequest` 之前执行，跳过 endRequest 与生命周期承诺一致）；Handler 工厂 create/destroy 严格配对；中间件链错误传播与顺序正确；request id 用 `io.random`（CSPRNG）无原子性问题；`failWith`/`ErrorRenderer`/兜底三处口径一致。
- **http_logging/http_compress**：句柄泄漏闭环完整；无 double-checked locking；`pending_gzip` 生命周期正确；日志注入已转义（`rid` 白名单校验封死）；多线程输出共用一把 mutex；无服务端解压路径（无解压炸弹）；`Accept-Encoding` 协商与 RFC 9110 一致；flate 用法（参数序、64KB hist_buf、`finish()` 语义）与 std 一致。
- **http_static/http_multipart/http_testing**：路径穿越四层防护顺序正确（`%2e%2e`/`%2f`/NUL/绝对路径均覆盖）；autoindex 未实现（无暴露面）；Range 边界（负数/-0/越界/空文件/多区间/If-Range）全部正确；multipart 边界校验（行首+后继字节双验证）、内容内边界子串、CRLF 归属、`safeBaseName` 完备；无 fd 泄漏。
- **http_websocket/http_session/http_rate_limit**：`Sec-WebSocket-Key/Accept` 计算正确（RFC 6455 样例测试覆盖）；帧解析核心（掩码、非最小长度拒绝、控制帧限制、分片重组、UTF-8 校验）正确；session id 32 字节 CSPRNG → 256 位熵；cookie 属性齐全且 `rotate` 提供会话固定防护；限流判定+计数在同一临界区（**无 check-then-act 竞态**），`proxyChainClient` 无死循环；hijack 的 arena 生命周期正确。
- **http_security**：所有凭证比对均走 `constantTimeEql`（实现正确，长度差混入累积器、无提前返回）；CORS 任意 Origin 反射+credentials 已正确防御（通配与 credentials 互斥并降级）；CSRF token 默认 32 字节 CSPRNG；base64 解码失败分支不读未初始化缓冲；vendor/zio 补丁均为语义等价的关键字更名，无安全影响。

---

# 五、修复优先级建议

1. **立即修（几行改动，封死远程 DoS/UB）**：H-4、H-5（同在 `connection.zig` 复用决策附近，建议一并处理 + 回归测试）、H-6（`body_read_attempted` 闩锁）、H-1（optional switch，一行改动解锁整条 optional 更新路径）。
2. **数据完整性**：H-2、H-3、M-3、M-6（三个「数据文件不可逆损坏 / open 崩溃」类）+ M-1/M-2 跟上。
3. **发布即咬人**：M-14（`build.zig.zon` 的 `.paths`，一旦以包形式发布必失败）。
4. **示例安全模型**：H-7、H-8、M-15/M-16/M-17（示例是用户模板来源，越权链真实可复现）。
5. **资源耗尽类**：M-8（Slowloris deadline）、M-22（WS Origin）、M-23/M-24（限流/WS 上限）、L-54。
6. **其余中/低**：随迭代处理；M-10（日志归档丢失）、M-9（Set-Cookie 丢失）优先级略高。
7. **补测试**：L-15 的 ①②（HEAD+CL、部分读复用）直接对应两个高危回归；L-40 补 CORS 全路径与 examples CI。
