# FRICTION — 用真实业务压测 http_framework 的踩坑清单

> 阶段：第一阶段（分层骨架 + 数据层 + 幂等 seed）。
> 代码位置：`examples/src/app/**`（model / repo / service / handler / middleware / core）。
> 数据目录：`examples/data/app`（8 张 JSON 表，`.gitignore` 已忽略 `data/`）。
>
> **规则**：只记录、不修改 `src/`（框架）。每条 = 现象 / 位置 / 分类 / 建议改法 / 我的绕过方式。
> 行号基于当前工作树（2026-09-11）。

## 统计

| 分类 | 条数 | 编号 |
|---|---|---|
| 缺失能力 | 10 | F-01 ~ F-10 |
| 设计缺陷 | 8 | F-11 ~ F-18 |
| API 不顺手 | 4 | F-19 ~ F-22 |
| 文档不一致 | 2 | F-23 ~ F-24 |
| bug（含潜在） | 1 | F-25 |
| 新发现（2026-09-11 追加） | 8 | F-NEW-1 ~ F-NEW-8 |

体感排序（最耽误事的在前）：**F-01 / F-11 / F-06 / F-04 / F-13 / F-15**。

### 已解决（框架已修，examples 已跟进）

| 编号 | 状态 | 见 |
|---|---|---|
| F-01 | ✅ 已解决 | 唯一约束 → `orm.ModelWith`，service 层 TOCTOU 写法已删 |
| F-11 | ✅ 已解决 | 组级 `use` 顺序无关；但 examples 的 `group("")` 写法**保留**（原因见该条） |
| F-12 | ⚠️ 部分解决 | 中间件链修好了，**响应体**没修 → 剩余部分记在 F-NEW-6 |
| F-13 | ✅ 已解决 | `RateLimitConfig.exclude_paths`，阈值 600 → 120 |
| F-25 | ✅ 已解决 | `modelSchema` 改用容器级静态存储 |

---

## 缺失能力

### F-01 ORM 无法声明唯一约束（用户名唯一只能业务层自己查）  ✅ 已解决

> **2026-09-11 已解决。**
> - **框架怎么修的**：新增 `orm.ModelWith(T, table, .{ .unique = &.{ &.{"a"}, &.{ "b", "c" } } })`
>   （`src/http_orm/model.zig`）。单字段组落到 `FieldConstraints.unique`，多字段组落到
>   `IndexDef{ .unique = true }`；冲突时 `insert` / `update` 返回 `error.UniqueViolation`，
>   且校验发生在锁内、`insert` 失败不写入任何行。字段名拼错是 `@compileError`。
> - **examples 侧怎么跟进的**：`model/user.zig`（username + email）、`model/org.zig`（code）、
>   `model/rbac.zig`（role code + permission code）改用 `ModelWith` 声明唯一；
>   `user_service / org_service / rbac_service` 里「先查一遍再插入」的预查全部删掉，
>   改成 `catch error.UniqueViolation` 并还原成**原来的**业务错误码
>   （`USERNAME_TAKEN` / `EMAIL_TAKEN` / `ORG_CODE_TAKEN` / `ROLE_CODE_TAKEN`，HTTP 仍是 409，
>   响应结构仍是 `{"code","message"}`）。实测四条路径的 `error_code` 一字未变。
>   唯一性判定细节：ORM 只回一个不带字段名的 `UniqueViolation`，`users` 表只有两条约束，
>   所以 `create` 里重查一次 username 即可区分（insert 失败 = 没写进去，重查不会查到自己）。
> - **没改的**：`seed` 的「按唯一键查不到才插」保留——它在启动时单线程执行，那不是防并发，
>   是幂等。

- **分类**：缺失能力
- **现象**：想让 `users.username` 唯一，插重名用户应该失败。`Model()` 编译期反射出来的
  schema 只给 `id` 标了 `primary_key/auto_increment/not_null`，**其余字段 constraints 全为
  默认值**（`unique = false`），而引擎的唯一性校验 `checkUnique` 只遍历
  `f.constraints.unique` 为真的字段 —— 于是唯一校验循环体一次都不执行，重名用户直接插得进去。
- **位置**：`src/http_orm/model.zig:74-95`（尤其 `:78-88` 的 `is_id` 分支）、
  `src/http_orm/engine.zig:643-654`（`checkUnique`）、`src/http_orm/schema.zig:44-58`
  （`FieldConstraints.unique` 字段本身是有的，只是没有入口能设它）
- **建议改法**：给 `Model` 加编译期参数，例如
  `Model(Row, "users", .{ .unique = &.{"username"} })`，或支持字段级声明（`@Unique` 包装类型 /
  结构体字段上的 decl）。最省事的折中：提供 `uniqueSchema(T, name, unique_fields)` 辅助函数。
- **我的绕过**：`repo` 只提供 `findByUsername / findByEmail / findByCode` 预查，判重逻辑放在
  `service` 层并返回业务错误码 `USERNAME_TAKEN / EMAIL_TAKEN / ORG_CODE_TAKEN / ROLE_CODE_TAKEN`；
  seed 用「按唯一键查不到才插」实现幂等。
  另外确认了一条**可行但极繁琐**的路：手搓 schema +
  `framework.orm.Engine.JsonStore(Row, schema)`（`src/root.zig:143` 导出了 `JsonStore`，
  `src/root.zig:146-148` 导出了 `TableSchema / FieldDef / FieldType`），逐个字段手写 `FieldDef`
  并把 `constraints.unique = true`。8 张表全手写不现实，故未采用。

### F-02 没有 `findAllBy` / `countAll`

- **分类**：缺失能力
- **现象**：只想「按 org_id 取该组织下的用户」或「数一下有多少条」，框架只给了
  `findBy`（**只返回第一条**）和 `count(query)`（**必须构造一个 QueryBuilder**）。
  结果：所有列表/计数都退化成 `all()` 全表深拷贝后在内存里过滤、取 `.len`。
- **位置**：`src/http_orm/engine.zig:573`（`findBy`）、`:511`（`count`）、`:525`（`all`）
- **建议改法**：`findAllBy(gpa, field, value) ![]T`、`countAll() !usize`（后者 O(1)，
  现在为了数行数要深拷贝整张表）。
- **我的绕过**：`repo` 层统一 `all()` + 内存过滤（`user_repo.listByOrgIds / search`、
  `org_repo.countMembers / countChildren`、`rbac_repo.countRoleUsers`），
  count 类方法用 `db.allocator` + `freeRows` 精确释放。数据量是 demo 级，能忍。

### F-03 `In` / `NotIn` 是死操作符

- **分类**：缺失能力
- **现象**：`Operator` 枚举里有 `In / NotIn`，`symbol()` 也实现了，但 `FieldValue` 联合
  根本没有「列表」变体，比较函数对这两个操作符恒返回 false；框架选择在构建期置
  `build_error = error.UnsupportedOperator`。所以「按 id 列表批量取用户/组织」无法表达。
  （构建期报错而不是静默返回空，这点做得对。）
- **位置**：`src/http_orm/query.zig:176-181`（`appendCondition` 里直接判死）、
  `src/http_orm/query.zig:26`（枚举定义）
- **建议改法**：`FieldValue` 增加 `.list` 变体（或 `.integers / .strings`），并让
  `evaluateCondition` 支持成员判定。
- **我的绕过**：`user_repo.listByOrgIds(org_ids)` 拿全表后逐个 `contains`；
  组织子树用 `model.org.subtreeIds` 先算 id 集合，再同法过滤。

### F-04 没有事务

- **分类**：缺失能力
- **现象**：`setRolePermissions` = 先删该角色全部权限、再逐条插入。两步之间进程崩溃
  → 该角色权限被清空且无法恢复。跨表（用户-角色 / 角色-权限）也没有原子性。
- **位置**：`src/http_orm/` 全目录无 transaction / batch API
- **建议改法**：至少提供 `store.batch(fn)`：在锁内执行、只在结束时 `dirty = true`，
  并记录 undo log 或先写临时文件再 rename（现在 `flush` 已经是 tmp+rename 了，
  复用它做单表原子提交成本不高）。
- **我的绕过**：把「先删后插」压在一个函数里、中间不做任何可能提前 return 的事；
  FRICTION 记录风险，等框架补事务再改。

### F-05 定义了 `Migration` / `MigrationOp`，但没有任何执行器

- **分类**：缺失能力（半成品）
- **现象**：schema 模块里定义了 `MigrationOp`（加列/删列/改类型等）与 `Migration`，
  并且被 `http_orm/root.zig` 导出；但 engine 里**一个 apply 函数都没有**，全仓库
  grep `migrat` 除了定义与导出零命中。改 `Row` 结构体后，旧 JSON 文件没有迁移路径。
- **位置**：`src/http_orm/schema.zig:97-142`（类型定义）、`src/http_orm/root.zig:67-68`（导出）、
  `src/http_orm/engine.zig`（无 apply）
- **建议改法**：补 `store.migrate(&ops)`，或最低限度提供「加载时按当前 schema 补齐缺字段 /
  丢弃多余字段并记录 warn」的能力。
- **我的绕过**：靠 `engine` 的 `applyDefaults` + `getDefaultForType`
  （`src/http_orm/engine.zig` 内 `getDefaultForType`）兜底：新增字段读出来是 `""`/`0`。
  阶段一不改表结构，真要改就删掉 `data/app` 重跑 seed。

### F-06 没有测试 harness：`Context` 不可在测试里构造

- **分类**：缺失能力（对本阶段影响最大）
- **现象**：业务层抛结构化错误的唯一途径是 `ctx.failWith` / 往 `ctx.state` 的 user_data
  槽里写东西，而 `framework.Context` 没有公开的、可在单测里构造的入口。
  结果：**service 层所有错误分支（校验失败、状态机拒绝、权限不足）都无法单元测试**，
  只能测纯函数，或起真实端口做 HTTP 冒烟。
- **位置**：`src/http_app/context.zig:193`（`Context` 定义）、全仓库无 `testing` 辅助模块
- **建议改法**：提供 `framework.testing.Context.init(allocator)` / `mockRequest(method, path)`，
  或至少把 `AppError` 的渲染与 `ctx` 解耦，让 service 能直接返回 `ApiError` 而不必经过 ctx。
- **我的绕过**：
  1. 把可测逻辑抽成纯函数（状态机、树算法、口令哈希、过滤匹配），单测覆盖；
  2. 仓储层用**真实临时 data 目录**跑集成测试（`service/integration_test.zig`）；
  3. 错误路径靠 `zig build run` + curl 手工冒烟（已验证 401/403/404/口令错误计数）。

### F-07 没有密码哈希工具

- **分类**：缺失能力
- **现象**：框架不提供 bcrypt/argon2/PBKDF2，`examples/src/admin.zig` 的既有做法是
  **把明文口令原样存进 `password_hash` 字段再字符串相等比较**。
- **位置**：API.md §15「密码哈希工具 ❌ 不存在」；`examples/src/admin.zig`（明文比较，未改）
- **建议改法**：`framework.crypto.password.hash/verify`（带随机盐 + 恒定时间比较），
  顺带把 admin.zig 的演示改掉，避免用户照抄。
- **我的绕过**：`examples/src/app/core/password.zig` 自实现 PBKDF2-HMAC-SHA256
  （PHC 风格 `pbkdf2-sha256$<rounds>$<salt_hex>$<hash_hex>`），比较用
  `std.crypto.timing_safe.eql`。注意本 Zig 版本路径是 **`std.crypto.pwhash.pbkdf2`**
  （不是 `std.crypto.pbkdf2`）。Debug 下 std 无向量化，rounds 取 10_000 以免登录卡秒级。

### F-08 没有配置文件加载器

- **分类**：缺失能力
- **现象**：data 目录、端口、seed 账号/口令全是编译期字面量；换目录、换端口要重编译。
- **位置**：API.md §15；`src/http_app/config.zig`
- **建议改法**：最小可用是 `framework.config.load(Env, .{ .prefix = "APP_" })`，
  或允许 `Config` 从 JSON 反序列化。
- **我的绕过**：常量集中在 `AppServices.init(allocator, io, data_dir)` 的调用点
  （`main.zig` 传 `"data/app"`）与 `seed.zig` 的 `DEFAULT_ADMIN_*`。

### F-09 路由没有元数据：`route_pattern` 只有 pattern，没有 method，更没有 attrs

- **分类**：缺失能力
- **现象**：想在中间件里做「这条路由需要什么权限点」，只能拿到
  `ctx.state.route_pattern`（形如 `/api/v1/users/:id`），**拿不到 HTTP method**，
  也没有 `route(.GET, path, h, .{ .permission = "user:create" })` 这类元数据机制。
  于是权限声明和路由表被迫割裂成两份。
- **位置**：`src/http_router/router.zig:241`（`ctx.state.route_pattern = result.pattern`，
  在中间件管道执行前已填好，这点可用）、`src/http_app/context.zig:109`（字段定义）
- **建议改法**：`route()` 接受一个 metadata 参数并随 trie 节点存储；中间件可
  `ctx.routeMeta(T)` 取回。或者干脆给 `RouteGroup.route` 增加 per-route middleware 参数
  （能顺带解决 F-11）。
- **我的绕过**：`App.route(...)` 里给每条需要鉴权的路由建 `group("")` 子组 +
  一个持有 permission 的 `PermissionGuard` 实例（`app.zig:121-140`）。

### F-10 会话无持久化，且只能存字符串

- **分类**：缺失能力
- **现象**：`SessionManager` 是纯内存的，**进程重启即全体掉线**（冒烟时重启后
  `/api/v1/orgs/tree` 立刻 401）；值只能是字符串，存 `user_id` 要手写 itoa/atoi，
  读一次还得传一个 allocator。
- **位置**：`src/http_session/session.zig:176`（`getValue(sid, key, allocator)`）、
  API.md §8
- **建议改法**：可选持久化后端（复用 JsonStore 即可）；`setInt/getInt` 或泛型 value。
- **我的绕过**：只存一个 `"uid"`，`auth_service.resolve` 里 `parseInt`；
  每次请求从库里重读用户与权限（也顺带保证改权限即时生效）。

---

## 设计缺陷

### F-11 组级 `use` 只对它**之后**注册的路由生效  ✅ 已解决（但绕法保留）

> **2026-09-11 已解决。**
> - **框架怎么修的**：trie 里只存分组 id，中间件链推迟到 dispatch 时按「祖先链」解析
>   （`src/http_router/router.zig` 的 `groupChain`）。`use` 对整个组生效，与 `route` 的
>   先后无关，对父组 `use` 也会影响已创建的子组。
> - **examples 侧怎么跟进的**：**`App.route()` 里「每条鉴权路由建 `group("")` + 一个守卫
>   实例」的写法保留**，因为顺序无关并不等于「能按路由挂中间件」——一个组的中间件仍然会
>   作用于组内**所有**路由，想换中间件集还是只能开同前缀子组。真正缺的是 F-09 的
>   per-route metadata（或 per-route middleware 参数）；有了它这 40 个子组和 40 个守卫实例
>   才能塌成一个中间件。
> - **顺带确认**：顺序无关没让既有挂载顺序失效（本仓库的 `use` 本来就都写在 `route` 之前），
>   全量测试仍绿。

- **分类**：设计缺陷
- **现象**：想给不同路由配不同权限点，因为组级中间件是在 `route()` 时**快照**的，
  必须先 `use` 再 `route`；同一个组里想换中间件集就得再开一个同前缀子组。
  30 多条业务路由 → 30 多个子组 + 30 多个守卫实例。
- **位置**：`src/http_router/router.zig:42-55`（`RouteGroup.use` 重建切片）、
  `:57-61`（`route` 插入 trie 时快照 `self.middleware`）
- **建议改法**：`route()` 支持 per-route middleware 参数，或让 `use` 对全组生效
  （注册期收集、dispatch 时按「注册序号 ≤ 路由序号」过滤）。
- **我的绕过**：`App.route()` 统一封装「有 permission 就建 `group("")` 子组 + 建守卫实例」，
  实例登记进 `App.owned / App.guards`，`App.deinit` 统一释放（框架不释放 singleton handler）。

### F-12 404/405 不走组级中间件  ⚠️ 部分解决

> **2026-09-11 部分解决。**
> - **框架怎么修的**：404/405 现在按 `/` 段对齐的**最长前缀**选出组（`groupForPath`），
>   并执行该组 + 祖先链的中间件（`groupChain`），平局时取最先注册的组。
> - **剩下一半没修**：**响应体**。框架的两个默认 handler（`methodNotAllowedHandler` /
>   `defaultNotFoundHandler`）各自直接写纯文本，组里的 `ErrorJson` 只在**有 error 抛出**时
>   才介入，拦不住它们。详见 F-NEW-6。
> - **examples 侧怎么跟进的**：`/api/v1` 组内那条 `GET /*` catch-all **保留**。实测
>   （2026-09-11，两种都跑过）：
>   - 保留：`GET /api/v1/nope` → 404 `{"code":"NOT_FOUND","message":"接口不存在"}`
>   - 删掉：`GET /api/v1/nope` → 404 `{"error_code":"not_found","message":"no route matched"}`
>     （全局 `notFoundHandler` 的格式，字段名是 `error_code` 不是契约里的 `code`，
>     前端读 `data.code` 会拿到 undefined）
>   - 两种情况下 `DELETE /api/v1/health` 都是 405 + 纯文本 `Method Not Allowed`
>
>   也就是说：删掉它既没修好 405，又把 404 的字段名从 `code` 换成了 `error_code`。
>   等框架补上「按组定制 404/405 响应体」再删（F-NEW-6）。

- **分类**：设计缺陷
- **现象**：`/api/v1` 下拼错 URL，返回的是**全局纯文本** `Not Found`，前端
  `res.json()` 直接炸；挂在组上的 JSON 错误渲染中间件完全不参与。
- **位置**：`src/http_router/router.zig:206-239`（404/405 handler 只走
  `self.global_middleware`）、`:281-282`（`defaultNotFoundHandler` 写纯文本）
- **建议改法**：允许为 `RouteGroup` 注册 not-found handler，或让 404/405 继承
  路径前缀最长匹配的组级中间件。
- **我的绕过**：在 `/api/v1` 组内**最后**注册一条 `GET /*` catch-all，
  由 `handler.misc_handler.notFound` 输出统一 JSON 错误体（catch-all 必须是最后一段，
  所以它天然不会抢走已有路由）。405 仍走框架默认，暂未覆盖。

### F-13 限流只能全局挂，不能按路由/前缀豁免  ✅ 已解决

> **2026-09-11 已解决。**
> - **框架怎么修的**：`RateLimitConfig.exclude_paths: []const []const u8`，按 `/` 段对齐前缀
>   匹配；命中的请求**既不计数也不写 `X-RateLimit-*` 头**。
> - **examples 侧怎么跟进的**：`main.zig` 的全局阈值从被迫抬高的 **600 改回 120**，
>   并豁免 `/static` 与 `/app`（静态资源 / 前端 SPA）。
>   **刻意不豁免** `/api/v1/auth/login`（登录必须有闸），同理也不豁免 `/admin`
>   ——它的子树里就有 `/admin/login`。实测：130 次 `/static/hello.txt` 全部 200 且无
>   `X-RateLimit-*` 头；`/rate-limit` 打满 120 后开始 429。

- **分类**：设计缺陷
- **现象**：`RateLimiter` 只能 `router.use(...)` 全局生效，没有 include/exclude 前缀，
  也没有按组挂载的能力。挂上 `/api/v1` 业务 API 后，后台前端一次页面访问就是十几个请求，
  原来演示用的 30 次/分钟会把正常业务一起 429。
- **位置**：`src/http_rate_limit/rate_limiter.zig:57`（`init`）、`:21-22`（config）、
  `src/http_router/router.zig:145`（全局 `use`）
- **建议改法**：`RateLimitConfig` 增加 `include_prefixes / exclude_prefixes`，
  或让 `RouteGroup.use` 支持限流器实例（按组窗口）。
- **我的绕过**：把全局阈值从 30 抬到 600（`main.zig` 已注释原因），
  代价是 `/rate-limit` 演示路由的触发门槛同步变高。

### F-14 持久化时机完全交给调用方：不 flush 就丢，每步 flush 就写放大

- **分类**：设计缺陷
- **现象**：`insert/update/delete` 只改内存并置 `dirty`；崩溃即丢数据。
  而 `flush()` 一旦 dirty 就是**整表 JSON 全量重写**（tmp 文件 + fsync + rename，
  成本 O(表大小)）。于是「安全」和「性能」二选一：每个写操作后 flush = seed 一次
  触发 30+ 次全表重写。
- **位置**：`src/http_orm/engine.zig:189-215`（`flush` / `flushUnlocked` 全量重写）、
  `:252`（`insert` 只置 dirty）、`src/http_orm/root.zig:16-25`（文档建议批量后 flush）
- **建议改法**：`store.setAutoFlush(interval_ms)` 或「dirty 后 N 毫秒/每 N 次写」自动 checkpoint；
  或者 append-only 日志文件 + 定期 compact。
- **我的绕过**：`repo` 层每个写操作后立刻 `flush()`（安全优先，接受写放大）；
  seed 只在启动时跑一次，可以接受。

### F-15 查询结果是深拷贝，一旦再切片就无法正确释放

- **分类**：设计缺陷（所有权模型）
- **现象**：`all()/findAll()` 返回的行内字符串由传入的 gpa 拥有，必须
  `freeRows(gpa, rows)`，且 `free` 要求长度与分配时一致。可一旦在 repo 里做了分页
  （`matched.items[start..end]`），外层拿到的只是子切片，**原缓冲区再也没法按正确长度释放**。
- **位置**：`src/http_orm/engine.zig:525`（`all`，`gpa.alloc(T, len)` 精确长度）、
  `:543`（`freeRows` 里 `gpa.free(rows)`）
- **建议改法**：提供官方 `Page(T){ items, total }`（items 为**精确长度的新分配**），
  或提供「借用视图」模式（只借、不拷，要求调用方在锁/请求生命周期内用完）。
- **我的绕过**：**所有读查询一律传请求 arena**（`ctx.arena`），测试里传
  `ArenaAllocator`；repo 注释里写死这条约定，谁都不许拿 `db.allocator` 去接 `search()`。

### F-16 一条坏数据就让整张表打不开（进程起不来）

- **分类**：设计缺陷
- **现象**：`load()` 遇到 `id == 0` 或重复 id 直接 `return error.CorruptData`，
  JSON 语法错误同理；`open()` 失败 = 进程起不来。没有「跳过坏行 + 备份原文件」的降级模式，
  也没有自带备份/回滚。
- **位置**：`src/http_orm/engine.zig:173-174`（`CorruptData`）、
  `:146`（`parseFromSlice` 失败即上抛）
- **建议改法**：`open` 增加 `.{ .on_corrupt = .quarantine }`：把坏文件改名备份后以空表启动，
  或跳过坏行并 `log.err`。（顺带：`appendEscapedJson` 已把 0x08/0x0c 补进转义表，
  说明这类「用户提交特殊字符 → 表永久打不开」的事故真实发生过。）
- **我的绕过**：无（只能靠别写坏数据）。审计日志的 `purge` 接口能清掉旧数据，
  但修不了损坏文件。

### F-17 handler 与 middleware 的生命周期规则不一致

- **分类**：设计缺陷
- **现象**：`Handler.initSingleton` 的实例**框架永不销毁**（`Handler.deinit` 对 singleton
  是 no-op）；而 `Middleware.init` 会检测 `T.deinit`，有 deinit 的中间件实例由
  `Router.deinit()` 销毁（并按值去重）。同一进程两套规则，写装配代码时必须自己
  记住「哪些该我释放」。
- **位置**：`src/http_app/handler.zig:138`（singleton no-op）、
  `src/http_app/middleware.zig:73-93`（`init` 里的 `destroyFn`）、
  `src/http_router/router.zig:129`（`Middleware.deinitAll`）
- **建议改法**：统一为「注册即托管」（Router 全权释放）或「注册即借用」（全部调用方释放），
  并在文档里一句话说清。
- **我的绕过**：`App` 自己维护 `owned: []Owned`（含类型擦除的 destroy 回调）与
  `guards: []*PermissionGuard`，`App.deinit` 统一释放；`PermissionGuard` **故意不写
  `deinit`**，避免被 Router 二次释放。

### F-18 ORM 字段只支持 int / float / bool / string（+ optional）

- **分类**：设计缺陷
- **现象**：枚举、时间、嵌套结构一律 `@compileError`。于是 `User.status`、`Approval.status`、
  `AuditLog.result` 全存字符串，业务层到处 `parseStatus / @tagName`；
  `AuditLog.changes`（字段级 diff JSON）也只能存文本。
- **位置**：`src/http_orm/model.zig:13-25`（`fieldTypeOf`）
- **建议改法**：`fieldTypeOf` 增加 `.@"enum"`（存 `@tagName`，读回 `stringToEnum`）、
  `.@"struct"`（存 JSON 文本，标注为 `.json_text` —— `FieldType` 里其实已经有
  `json_text` 变体了，只是反射不认）。
- **我的绕过**：模型层每个枚举配 `parseXxx` + `@tagName`；对外 `View` 结构里仍是字符串，
  由前端（或下一阶段的 DTO 层）负责呈现。

---

## API 不顺手

### F-19 用一次 QueryBuilder 要 5 行样板

- **分类**：API 不顺手
- **现象**：`var qb = Query(T).init(allocator); defer qb.deinit();` +
  `.where(.Eq, "f", .{ .string = v })`（字段名是字符串、值要手拼联合字面量，
  写错字段名**不报错、静默不匹配**）。做个最简单的等值查询也要这么多行，
  结果就是大家宁可 `all()` 回来手过滤（见 F-02）。
- **位置**：`src/http_orm/query.zig:84`（`QueryBuilder`）、`:114`（`init`）、`:175`（`where`）、
  `:247`（`matches`，未知字段视为不匹配）
- **建议改法**：`store.where(gpa, "field", value)` 一行式封装；
  字段名做成编译期校验（`comptime` 检查 `T` 是否有该字段，写错直接编译失败）。
- **我的绕过**：repo 层把「全表 + 内存过滤」做成统一套路，只在 `deleteXxxByXxx`
  这类必须走 ORM 的地方才手写 QueryBuilder（`rbac_repo.zig:101-141`）。

### F-20 `wsUpgrade` 的 `hijack_ctx` 是 `*anyopaque`

- **分类**：API 不顺手（易致 UAF）
- **现象**：回调在 handler 返回之后才执行，参数却是裸 `*anyopaque`，
  天然诱导人传栈上地址 —— `examples/src/main.zig` 原来就写着
  `@ptrCast(res)`，是教科书级 use-after-free（API.md §14-14 自己也点名了）。
- **位置**：API.md §9.1 / §14-14；`src/http_websocket/`
- **建议改法**：改成泛型
  `wsUpgrade(comptime T: type, ctx, res, ptr: *T, cb: fn(*WebSocket, *T) anyerror!void)`，
  让编译器保证类型，至少也要在文档里禁止栈地址。
- **我的绕过**：业务侧传 `&services`（`appMain` 栈上的长期对象）；
  顺手把 `main.zig` 里 `/ws` 的反例改成传模块级 `ws_echo_conns` 的地址。

### F-21 `paginate` 不能带过滤、不能换排序

- **分类**：API 不顺手
- **现象**：`paginate(page, per_page)` 固定按 `id` 升序，不能带 where、不能 orderBy。
  而真实列表接口都是「过滤 + 关键字 + 排序 + 分页」，于是这个方法在业务层一次都用不上。
- **位置**：`src/http_orm/engine.zig:602`
- **建议改法**：`paginate(gpa, page, per_page, query)`，让分页复用 QueryBuilder 的
  where/orderBy。
- **我的绕过**：repo 自己实现内存分页，统一返回 `SearchResult(T){ items, total }`
  （`repo/mod.zig:59-64`）。

### F-22 没有框架级的时间助手

- **分类**：API 不顺手
- **现象**：取当前时间要 `std.Io.Timestamp.now(io, .real).nanoseconds / ns_per_ms`，
  且 `io` 必须来自 zio 运行时；业务代码里到处是 `@intCast(@divTrunc(...))` 这一串。
- **位置**：`examples/src/app/service/container.zig:63`（`nowMs`）、
  `examples/src/app/core/util.zig:7`
- **建议改法**：`framework.nowMs(io)` / `ctx.nowMs()`。
- **我的绕过**：`AppServices.nowMs()` + `core.util.nowMs(io)` 两处封装。

---

## 文档不一致

### F-23 「唯一约束」相关描述会让人误以为 ORM 支持声明式唯一

- **分类**：文档不一致
- **现象**：API.md §10 写「`insert` 唯一约束冲突返回 `error.UniqueViolation`——但只有
  schema 里标了 `unique` 的字段才会触发……要『用户名唯一』得在业务层自己查」。
  这半句是对的，但文档**没有告诉读者：`Model()` 根本没有声明 unique 的入口**，
  唯一可行的路是手搓 `TableSchema` + `Engine.JsonStore`（`src/root.zig:143/146`）——
  这条路径文档里一次都没出现。读者很容易理解成「ORM 支持，只是我这个字段没开」。
- **位置**：`docs/API.md` §10 ORM 段落；对照 `src/http_orm/model.zig:74-95`
- **建议改法**：在 §10 补一段「如何声明 unique（手搓 schema 示例）」，并明确
  `Model()` 的局限；或直接把 F-01 的能力补上。
- **我的绕过**：按文档说的「业务层自己查」实现（F-01）。

### F-24 「必须显式 flush」与「批量后 flush」两种引导并存

- **分类**：文档不一致
- **现象**：API.md §14-11 把「改动后必须显式 `store.flush()`」列为硬约束，
  而 `src/http_orm/root.zig:16-25` 的模块文档恰恰相反，强调「批量操作成本是 O(N) 而不是
  O(K\*N)，持久化时机由调用方控制」。两份文档都没说清：**按 §14 的写法（每步 flush）
  会得到 O(K\*N) 写放大**，与 root.zig 的性能承诺冲突。
- **位置**：`docs/API.md` §14-11；`src/http_orm/root.zig:16-25`
- **建议改法**：统一口径 —— 写操作后「尽快 flush」= 安全；批量导入时「一批之后 flush」= 性能；
  并给出崩溃丢失窗口的说明（现在没有 auto-flush，见 F-14）。
- **我的绕过**：repo 每个写操作后 flush（选安全），代价记在 F-14。

---

## bug（含潜在）

### F-25 `modelSchema()` 运行期调用会返回指向已销毁栈帧的切片（UAF）  ✅ 已解决

> **2026-09-11 已解决。**
> - **框架怎么修的**：schema 静态数据搬进容器级 `const`（`SchemaStorage` 里的
>   `pub const fields / indexes`），容器级 const 天然是静态存储，`&fields` 的生命周期
>   等于程序生命周期；`modelSchema()` 不再返回栈数组地址。加了 `clobberStack(64)` 的
>   回归测试（不加 `comptime` 的运行期调用 + 两次调用必须指向同一块内存）。
> - **examples 侧怎么跟进的**：本来就没碰 `modelSchema()`；现在 4 张表改用 `ModelWith`，
>   走的也是同一份静态存储，无额外动作。

- **分类**：bug（潜在；目前对外不可达）
- **现象**：`modelSchema()` 用 `comptime blk:` 生成 `fields` 数组后返回
  `&fields`（局部栈数组）。源码注释自己写明：「实测 `fields.ptr` 落在栈上，
  clobber 栈帧后 `fields[0].name` 变成垃圾」「文件内所有测试都写了
  `comptime modelSchema(...)`，恰好掩盖了这个 bug」。同文件的 `Model()` 用的是
  容器级 `const _fields`（天然 comptime），所以走 `Model()` 的业务代码没事。
- **位置**：`src/http_orm/model.zig:28-62`（注释见 `:35-40`）
- **为什么没炸到我们**：`http_orm/root.zig:59` 只导出了 `Model`，`modelSchema` 目前
  拿不到（要直接 import `model.zig` 才行）。但这是个一改导出就爆的地雷。
- **建议改法**：删掉这个公开函数，或改成 `pub comptime fn` / 强制调用方用
  `comptime` 接收（Zig 目前没有 `comptime fn` 约束，最稳的是删掉，只留 `Model()`）。
- **我的绕过**：只使用 `Model(Row, "table")`，不碰 `modelSchema()`。

---

## 新发现（2026-09-11 追加）

> 这一批是 F-01 / F-12 / F-13 修完之后**新暴露**出来的问题：一半是修复本身带来的
> （F-NEW-1/2/3 都出自 404/405 改走组中间件），一半是新能力的边界。格式沿用上面：
> 现象 / 位置 / 分类 / 建议改法 / 绕过方式。

### F-NEW-1 `groupForPath` 是 O(组数) 线性扫描，且只在 404/405 路径上跑

- **分类**：性能 / DoS 面
- **现象**：404/405 时要找「最长前缀匹配的组」，`groupForPath` 是遍历 `self.groups`
  逐个比前缀的线性扫描。而 `group("")` 这个为单条路由挂守卫的写法会让组数随路由数
  线性增长（本仓库 `/api/v1` 下就有 40+ 个同前缀子组），几百个组很轻松。
  更要命的是**404 是攻击者可以免费制造的**：随便打一个不存在的 URL 就换来几百次
  字符串比较，而且这条路径完全在鉴权之前。
- **位置**：`src/http_router/router.zig:367`（`groupForPath`），调用点在 `:296`
- **建议改法**：组按前缀排序后二分（注册期只排一次），或直接复用 trie——trie 本来
  就能按段找最长前缀，没必要再维护一份平行结构。
- **绕过方式**：本仓库只能少建组（见 F-11 的跟进说明：等 per-route metadata 落地后，
  40 个 `group("")` 子组可以塌成一个中间件）。

### F-NEW-2 「Router 注册期构建、运行期只读」的隐含前提不再严格成立

- **分类**：设计缺陷（语义变更）
- **现象**：中间件链改为 dispatch 时解析之后，注册完成**之后**再 `use` 也会影响后续
  请求。好处是修好了 F-11，代价是「注册完就冻结」这个之前可以依赖的隐含前提没了：
  运行期（比如热加载、按需挂载模块）再 `use` 会改变已在处理中的请求的行为，
  而且 `groups[i].middleware` 是 `ArrayList`，并发 `use` + dispatch 有数据竞争。
- **位置**：`src/http_router/router.zig:334`（`groupChain`，dispatch 时按 parent 链现解析）
- **建议改法**：在文档里明确「注册期 = 服务启动前，之后 `use` 是未定义行为」，
  或加一个 `router.seal()`（像 `Services.seal()` 那样）在 `server.run()` 前封箱，
  封箱后再 `use` 直接失败。
- **绕过方式**：本仓库只在 `appMain` 里挂载路由，之后不再 `use`，暂时不受影响。

### F-NEW-3 404/405 时拿不到任何路由信息（埋点/日志很难写）

- **分类**：缺失能力
- **现象**：`ctx.state.route_pattern` 在 404/405 时是空串（命中路由时是
  `/api/v1/users/:id` 这种 pattern），中间件里想知道「请求落在哪个 URL 空间」只能
  回头读原始的 `ctx.request.path`。结果是：按路由聚合的埋点/日志在 404 上全部退化为
  高基数原始路径（还容易被打爆），而 404 恰恰是排查时最想知道的一类。
- **位置**：`src/http_router/router.zig:299`（`ctx.state.route_pattern = result.pattern`，
  404/405 时 `result.pattern` 为 null）
- **建议改法**：404/405 时把 `route_pattern` 填成**最长匹配的组前缀**（`groupForPath`
  已经算出来了，顺手填即可），让埋点至少能聚到 `/api/v1` 这一层。
- **绕过方式**：中间件里读 `ctx.request.path` 自己截断，各写各的，容易不一致。

### F-NEW-4 成功路径渲染 AppError 失败被静默吞掉

- **分类**：bug（不对称）
- **现象**：`connection.zig` 的**错误**路径渲染失败会退化成 500，而**成功**路径
  （handler 没抛错、但通过 `failWith` 存了 AppError）里
  `app_err.toResponse(&res) catch {};` 把渲染失败静默吞掉——然后照常 `res.flush()`。
  结果是一个「状态码对、body 空」的响应，日志里什么都没有。
- **位置**：`src/http_server/connection.zig:243`（对比错误路径的 `:184`）
- **状态**：已有 worker 在修，这里只如实记录。
- **建议改法**：与错误路径对齐——渲染失败记 `log.err` 并退 500，至少别静默。
- **绕过方式**：无（业务侧够不着这一层）。

### F-NEW-5 ORM 唯一约束的局限性

- **分类**：缺失能力（新功能的边界）
- **现象**：`ModelWith` 的唯一约束能用，但有三类需求做不到：
  1. `open()` **不校验存量数据**——已有的重复行照常加载，只有之后的
     `insert` / `update` 才会撞上。存量脏数据的后果是「改 A 用户时报
     `UniqueViolation`，但看起来 A 并没有重复」，极难定位。
  2. 没有**部分唯一索引**（带 `WHERE` 条件的那种，比如「只对未删除的行唯一」）。
  3. 没有**大小写不敏感**唯一——`Admin` 和 `admin` 算两个不同的值，而登录名
     几乎都需要大小写不敏感。
- **位置**：`src/http_orm/engine.zig:53`（`open`）、`:675`（`checkUnique` 只做
  `FieldValue` 相等比较）
- **建议改法**：`open` 增加 `.{ .on_unique_violation = .quarantine | .warn }`；
  `ModelOptions.unique` 支持 `IndexDef` 级别的 `where` 与 `collation`（至少加一个
  `.ci_string` 字段类型）。
- **绕过方式**：本仓库在 service 层保证「用户名/邮箱写入前已通过 `validate` 小写化」；
  存量数据靠 seed 保证干净（已实测 4 张表无重复）。

### F-NEW-6 404/405 的**响应体**无法按组定制（F-12 的剩余一半）

- **分类**：设计缺陷
- **现象**：F-12 只把「中间件链」接上了，没把「响应体」接上。框架的
  `methodNotAllowedHandler` / `defaultNotFoundHandler` 是两个写死的内部函数，
  直接 `res.text(...)`，不走任何组级约定。组里的错误渲染中间件（本仓库的
  `middleware.ErrorJson`）只在 `next.call()` **返回 error** 时才介入，对
  「handler 正常返回、只是写了纯文本」这种情况无能为力。
  于是 405 永远是 `text/plain` 的 `Method Not Allowed`，跟同组业务接口的 JSON
  契约对不上。
- **位置**：`src/http_router/router.zig:392`（`methodNotAllowedHandler`）、
  `:400`（`defaultNotFoundHandler`）；`RouteGroup` 没有对应的 setter
- **建议改法**：给 `RouteGroup` 加 `setNotFound(handler)` / `setMethodNotAllowed(handler)`，
  或者把这两个默认 handler 改成**抛 `error.AppError`**，让组级错误渲染中间件统一接管
  （后者复用现有机制，改动更小）。
- **绕过方式**：保留 `/api/v1` 下的 `GET /*` catch-all（见 F-12 的实测数据）；
  405 暂无解，前端只能按状态码而不是 content-type 分支。

### F-NEW-7 组内 `GET /*` catch-all 会让未知路径的非 GET 请求返回 405 而不是 404

- **分类**：设计缺陷（与 catch-all 的交互）
- **现象**：trie 判定 405 的依据是「pattern 匹配到了、但该 method 没有 handler」。
  一旦组里注册了 `GET /*`，**任何**路径都算 pattern 匹配成功，于是
  `POST /api/v1/这个路径根本不存在` 返回的是 405 而不是 404。语义上说不通：
  路径都不存在，谈不上方法不允许。
- **位置**：`src/http_router/router.zig:263`（`result.pattern_matched` 分支），
  判定不考虑 catch-all 是「兜底节点」还是真实路由
- **建议改法**：让 trie 区分「命中真实路由」与「只命中 catch-all/兜底节点」，
  后者在非通配符 method 下应继续走 404；或给 catch-all 节点打个标记。
- **绕过方式**：实测确认影响面很小——前端只会 GET 不存在的路径（那正是 catch-all
  要接的），POST/PUT/DELETE 打到不存在的 URL 属于手工/扫描流量，405 与 404 一样
  都是 4xx。本仓库保留 catch-all（F-12），接受这个副作用。

### F-NEW-8 唯一校验是每次 `insert` / `update` 的全表线性扫描

- **分类**：性能
- **现象**：`checkUnique` 对每个唯一字段（含每条唯一索引）都 `for (self.rows.items)`
  扫一遍，即 O(唯一约束数 × 行数)。开了唯一约束之后，**每一次写**都要付这个成本——
  包括登录时更新 `last_login_at` / `failed_attempts` 这种高频 `update`。
  demo 规模（8 行）无所谓，几千行就开始有感觉了。
- **位置**：`src/http_orm/engine.zig:675`（`checkUnique`），调用点 `:262`（`insert`）、
  `:466`（`update`，整行替换路径）
- **建议改法**：维护 `StringHashMap(unique_key → id)` 增量索引（insert/update/delete
  时同步维护），把 O(N) 降到 O(1)；`open` 时构建一次。
- **绕过方式**：无。本仓库的表都在百行量级，先记着。

---

## 附：本阶段已验证可用的能力（正面记录）

- ORM：8 张表 `open/insert/findById/findBy/updateById/deleteById/all/flush` 全部正常；
  `flush` 有 dirty 短路，无改动时免费；`close()` 会补一次 flush。
- 路由：`group("")` 同前缀子组、catch-all、`/users/:id` 参数、405 带 `Allow` 头均正常。
- 会话 + 权限守卫：未登录 401、缺权限 403（带 `required` 详情）、口令错误计数与锁定提示正常。
- 幂等 seed：fresh clone 启动 `users=7 orgs=5 roles=4 permissions=23 approvals=1`，
  重启后全部为 0（不重复插入）。
