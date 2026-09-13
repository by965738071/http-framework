# examples 后端接口契约（/api/v1）

> 前端开发的唯一依据。本文以 `examples/src/app/` 的**实际代码**为准：路由表来自 `app/app.zig` 的 `mount()`，字段来自 `app/model/*.zig` 与 `app/model/dto.zig`，业务规则来自 `app/service/*.zig`，错误码来自 `app/core/errors.zig`，响应封装来自 `app/core/respond.zig`。
>
> 后端状态：**79/79 测试通过、零内存泄漏**。
>
> 最近一轮改造：唯一性约束下沉到 ORM（`orm.ModelWith` 的 `unique`），service 层的"先查再插"已删除；冲突在 `insert`/`update` 时抛 `error.UniqueViolation`，由 service 还原成业务错误码。这一改动**改变了部分接口的错误优先级**，见 §4.7。

- **Base URL**：`http://127.0.0.1:9000/api/v1`（下文所有路径均省略该前缀，写作 `/users` 即 `/api/v1/users`）
- **静态前端**：生产构建产物由后端在 `http://127.0.0.1:9000/app` 提供（`public/app/`）；Vite 开发服务器把 `/api`、`/admin` 代理到 9000，对浏览器来说是同源。
- **数据来源**：JSON 文件 ORM，目录 `examples/data/app/`。启动时执行**幂等 seed**（按唯一键查不到才插，已存在的不改动）。

---

## 1. 总览

### 1.1 鉴权方式

会话 Cookie，Cookie 名 **`sid`**。

| 项 | 值 |
| --- | --- |
| Cookie 名 | `sid`（`main.zig:148` 配置 `cookie_name = "sid"`） |
| 建立方式 | `POST /auth/login` 成功时由后端 `Set-Cookie` 下发 |
| 属性 | `Path=/`、`HttpOnly`、`SameSite=Lax`、`Secure=false`（明文 HTTP 本机开发） |
| 有效期 | 服务端会话 3600 秒 |
| 失效方式 | `POST /auth/logout`（服务端销毁 + 下发 `sid=deleted; Max-Age=0`） |

会话里只存 `uid` 与 `username`。**每次请求都会重新查库**解析出当前用户及其权限点（`auth_service.resolve`），因此角色/权限变更、用户被禁用或删除会**立即生效**（已登录会话下一次请求就被踢掉）。

`GET /api/v1/health` 与 `POST /api/v1/auth/login` 是仅有的两个**无需登录**接口。

### 1.2 统一响应格式

**成功**：HTTP 200/201，body 恒为

```json
{ "code": "OK", "data": <对象 | 数组> }
```

- `code` 恒为字符串 `"OK"`
- `data` 绝不会是 `null`；无业务数据时是空对象 `{}`
- 写操作（DELETE、重置密码）返回 `{"code":"OK","data":{}}`
- 新建类接口（POST /users、POST /orgs、POST /roles、POST /approvals）返回 **201 Created**，body 仍是上面的结构

**分页**：`data` 固定为

```json
{
  "code": "OK",
  "data": { "items": [ ... ], "total": 42, "page": 1, "page_size": 20 }
}
```

**失败**：HTTP 4xx/5xx，body 为

```json
{ "code": "PERMISSION_DENIED", "message": "缺少权限：user:create", "details": { "required": "user:create" } }
```

- `code`：机器可读的错误码（见 §7 总表）
- `message`：中文人话，可直接展示给用户
- `details`：**可选**，仅在部分错误中出现（403 权限、409 冲突计数、423 锁定信息等）。前端必须容忍其缺失。

**判断成功与否的推荐写法**：`if (body.code === "OK")`，或 `if (!res.ok)` 后读 `body.code`。

### 1.3 通用请求约定

- 请求体必须是 JSON；**空 body / JSON 语法错误 / 缺必填字段** 一律 `400 INVALID_JSON`
- 未知字段会被忽略（`ignore_unknown_fields = true`），**不会**报错
- 请求体上限 1 MiB，超限返回 `400 INVALID_JSON`（`message` = `请求体过大`，并关闭 keep-alive）
- 路径参数 `:id` 必须是非负整数，否则 `400 VALIDATION_ERROR`（`path param must be an integer`）
- 分页参数非法（非数字）时静默取默认值，不报错
- 分页参数 `page` 从 **1** 开始，缺省 1；`page_size` 缺省 **20**，取值范围被后端夹到 **[1, 200]**
- 时间字段一律 **epoch 毫秒**（UTC），未设置时为 `0`
- query 参数**不做 URL 解码**（见 §6.9 与 §8.3 #1）

### 1.4 全局限流（前端必读）

`main.zig:251` 挂了一个全局限流中间件，**对 `/api/v1` 生效**：

| 项 | 值 |
| --- | --- |
| 窗口 | 60 秒 |
| 阈值 | 120 次（全局共享，不是按 IP：`per_ip = false`、`identifier_header = null`） |
| 豁免路径 | 仅 `/static`、`/app`；**`/api/v1` 与 `/admin` 都不豁免** |
| 超限响应 | HTTP **429 + 纯文本** `Rate limit exceeded`，带 `Retry-After` 与 `X-RateLimit-*` 头 |

也就是说：一个浏览器页面刷新一次打十几个 `/api/v1` 请求都在计数内，多开几个页面或写个轮询很容易 1 分钟内打满 120 次。**前端不要做高频轮询**；`GET /ws` 的长连接不消耗额外配额（一次升级请求只计一次）。429 是**纯文本**，不是 JSON，`res.json()` 会抛错（见 §6.7 的防御写法）。

---

## 2. 权限点清单（23 个 + 通配符）

后端**只按权限点鉴权**，不看角色名（`model/rbac.zig` 的 `hasPermission`）。角色只是权限点的集合。持有通配符 `*` 即通过一切权限校验（超管角色 `super_admin` 持有 `*`）。

清单来自 `model/rbac.zig:82` 的 `ALL_PERMISSIONS`，顺序即 `GET /permissions` 的返回顺序：

| # | 权限点 | 模块 | 名称 |
| --- | --- | --- | --- |
| 1 | `user:view` | user | 查看用户 |
| 2 | `user:create` | user | 新建用户 |
| 3 | `user:update` | user | 修改用户 |
| 4 | `user:delete` | user | 删除用户 |
| 5 | `user:reset-password` | user | 重置密码 |
| 6 | `user:assign-role` | user | 分配角色 |
| 7 | `user:unlock` | user | 解除锁定 |
| 8 | `org:view` | org | 查看组织 |
| 9 | `org:create` | org | 新建组织 |
| 10 | `org:update` | org | 修改组织 |
| 11 | `org:delete` | org | 删除组织 |
| 12 | `org:move` | org | 移动组织 |
| 13 | `role:view` | role | 查看角色 |
| 14 | `role:create` | role | 新建角色 |
| 15 | `role:update` | role | 修改角色 |
| 16 | `role:delete` | role | 删除角色 |
| 17 | `role:assign` | role | 配置角色权限 |
| 18 | `log:view` | log | 查看审计日志 |
| 19 | `log:export` | log | 导出审计日志 |
| 20 | `log:purge` | log | 清理审计日志 |
| 21 | `approval:view` | approval | 查看审批 |
| 22 | `approval:create` | approval | 发起审批 |
| 23 | `approval:review` | approval | 审批 |
| — | `*`（通配符） | — | 超管，放行所有权限点。**不在** `GET /permissions` 返回列表里（该接口只读 permissions 表，表里没有 `*` 这一行） |

### 每个权限点多对应的接口（从 `app.zig:mount()` 提取）

| 权限点 | 接口 |
| --- | --- |
| `user:view` | `GET /users`、`GET /users/:id` |
| `user:create` | `POST /users` |
| `user:update` | `PUT /users/:id`、`PUT /users/:id/status` |
| `user:delete` | `DELETE /users/:id` |
| `user:reset-password` | `POST /users/:id/reset-password` |
| `user:assign-role` | `PUT /users/:id/roles` |
| `user:unlock` | `POST /users/:id/unlock` |
| `org:view` | `GET /orgs/tree`、`GET /orgs`、`GET /orgs/:id`、`GET /orgs/:id/members` |
| `org:create` | `POST /orgs` |
| `org:update` | `PUT /orgs/:id` |
| `org:delete` | `DELETE /orgs/:id` |
| `org:move` | `POST /orgs/:id/move` |
| `role:view` | `GET /roles`、`GET /permissions`、`GET /permissions/groups` |
| `role:create` | `POST /roles` |
| `role:update` | `PUT /roles/:id` |
| `role:delete` | `DELETE /roles/:id` |
| `role:assign` | `PUT /roles/:id/permissions` |
| `log:view` | `GET /logs` |
| `log:export` | `GET /logs/export` |
| `log:purge` | `POST /logs/purge` |
| `approval:view` | `GET /approvals`、`GET /approvals/:id` |
| `approval:create` | `POST /approvals` |
| `approval:review` | `POST /approvals/:id/review` |

仅需登录、不需要任何权限点的接口：`POST /auth/logout`、`GET /auth/me`、`GET /auth/permissions`、`GET /dashboard/stats`、`GET /ws`。

### Seed 内置角色（`service/seed.zig:65`）

| 角色 code | 名称 | 内置 | 权限点 |
| --- | --- | --- | --- |
| `super_admin` | 超级管理员 | ✅ | `*` |
| `org_admin` | 组织管理员 | ✅ | `user:view`、`user:create`、`user:update`、`user:reset-password`、`user:assign-role`、`user:unlock`、`org:view`、`org:create`、`org:update`、`org:move`、`role:view`、`role:assign`、`log:view`、`approval:view`、`approval:create`、`approval:review` |
| `auditor` | 审计员 | ✅ | `user:view`、`org:view`、`role:view`、`log:view`、`log:export`、`approval:view` |
| `operator` | 运营 | ❌（可删） | `user:view`、`user:create`、`user:update`、`org:view` |

### Seed 账号（`service/seed.zig:176`）

| 用户名 | 密码 | 显示名 | 组织 | 状态 | 角色 |
| --- | --- | --- | --- | --- | --- |
| `admin` | `admin123` | 系统管理员 | 总公司 | active | super_admin |
| `manager` | `manager123` | 张管理 | 技术中心 | active | org_admin |
| `auditor` | `auditor123` | 李审计 | 市场部 | active | auditor |
| `operator` | `operator123` | 王运营 | 技术中心 | active | operator |
| `alice` | `alice123` | 爱丽丝 | 后端组 | active | 无 |
| `bob` | `bob123` | 鲍勃（已禁用） | 后端组 | **disabled** | 无 |
| `carol` | `carol123` | 卡罗尔（已锁定） | 前端组 | **locked**（`locked_until = seed 时间 + 15 分钟`） | 无 |

组织树：总公司(hq) → 技术中心(tech) → {后端组(backend)、前端组(frontend)}，以及 市场部(market)。

> ID 由插入顺序决定：组织 `hq=1 / tech=2 / market=3 / backend=4 / frontend=5`；用户 `admin=1 … carol=7`；角色 `super_admin=1 / org_admin=2 / auditor=3 / operator=4`。**前端不要硬编码 ID**，请以接口返回为准。

---

## 3. 接口清单

图例：`🔓` 无需登录 · `🔑` 只需登录（无权限点要求）· `⚡` 需要指定权限点

### 3.1 认证

#### `POST /auth/login` 🔓

建立会话。请求体：

```json
{ "username": "admin", "password": "admin123" }
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `username` | string | ✅ | 用户名 |
| `password` | string | ✅ | 明文密码（走 HTTPS 或本机） |

成功 `200`，同时下发 `Set-Cookie: sid=...`：

```json
{
  "code": "OK",
  "data": {
    "id": 1,
    "username": "admin",
    "display_name": "系统管理员",
    "org_id": 1,
    "permissions": ["*"]
  }
}
```

> 登录响应**不含** `status` 与 `is_super_admin`（与 `GET /auth/me` 不同）。判断超管用 `permissions.includes("*")`。

常见错误：

| HTTP | code | 触发条件 | details |
| --- | --- | --- | --- |
| 400 | `INVALID_JSON` | body 空 / 非法 JSON / 缺 `username` 或 `password` | — |
| 401 | `INVALID_CREDENTIALS` | 用户名不存在，或密码错误（未达锁定阈值） | 密码错误时 `{"remaining_attempts": N}`；用户名不存在时无 details |
| 403 | `ACCOUNT_DISABLED` | 账号状态为 `disabled` | — |
| 423 | `ACCOUNT_LOCKED` | 账号处于锁定期内 | `{"locked_until": 1754000000000, "remaining_ms": 871000}` |
| 423 | `ACCOUNT_LOCKED` | 本次是第 5 次连续失败，账号刚被锁定 | `{"locked_until":…, "remaining_ms": 900000, "failed_attempts": 5}` |
| 500 | `INTERNAL_ERROR` | 会话服务不可用（`会话服务不可用`） | — |

**锁定流程**（详见 §4.1）：第 1~4 次失败返回 401 并带剩余次数；第 5 次失败直接锁定 15 分钟并返回 423。

#### `POST /auth/logout` 🔑

无请求体。销毁服务端会话并清除 Cookie。

```json
{ "code": "OK", "data": {} }
```

> 服务端会写一条 `logout` 审计日志；未登录时（理论上被 SessionAuth 拦在前面）也能正常返回。

#### `GET /auth/me` 🔑

```json
{
  "code": "OK",
  "data": {
    "id": 1,
    "username": "admin",
    "display_name": "系统管理员",
    "org_id": 1,
    "status": "active",
    "permissions": ["*"],
    "is_super_admin": true
  }
}
```

#### `GET /auth/permissions` 🔑

```json
{ "code": "OK", "data": { "permissions": ["*"], "is_super_admin": true } }
```

> 权限变更后（例如管理员改了自己的角色）重新拉一次即可生效——后端每次请求都重新查库。

#### 认证类通用错误

| HTTP | code | 触发条件 |
| --- | --- | --- |
| 401 | `SESSION_EXPIRED` | 无 `sid` Cookie / 会话过期 / 用户被删除 / 用户状态不是 `active` |
| 401 | `UNAUTHORIZED` | 权限守卫或 handler 未取到登录主体（理论上被 `SESSION_EXPIRED` 覆盖） |
| 429 | （纯文本） | 触发全局限流（见 §1.4） |

### 3.2 其他（仪表盘 / 健康检查 / WebSocket / 404 兜底）

#### `GET /health` 🔓

```json
{
  "code": "OK",
  "data": {
    "status": "ok",
    "service": "admin-api",
    "version": "v1",
    "counts": {
      "users": 7,
      "orgs": 5,
      "roles": 4,
      "permissions": 23,
      "audit_logs": 3,
      "pending_approvals": 1
    }
  }
}
```

> 全 0 说明 `data/app` 或 seed 有问题，可作为自检信号。

#### `GET /dashboard/stats` 🔑

```json
{
  "code": "OK",
  "data": {
    "users": { "total": 7, "active": 5, "disabled": 1, "locked": 1 },
    "orgs": 5,
    "roles": 4,
    "permissions": 23,
    "pending_approvals": 1,
    "audit_logs": 3,
    "online_connections": 0
  }
}
```

> `orgs` 是组织总数（不是树节点数）；`online_connections` 是 `GET /ws` 的当前在线连接数。

#### `GET /ws` 🔑

WebSocket（RFC 6455）实时通知通道。**只需登录，不校验任何权限点**。

- 连接地址：`ws://127.0.0.1:9000/api/v1/ws`
- 连接成功后服务端立即推一条：

```json
{ "type": "connected", "data": { "online": 2 }, "ts": 1754000000000 }
```

- 并向**所有**连接广播在线状态：

```json
{ "type": "presence", "data": { "online": 2 }, "ts": 1754000000000 }
```

- 业务事件（服务端单向推送，客户端发的消息只用于保活，会被忽略）：

| type | data | 触发 |
| --- | --- | --- |
| `user.created` / `user.updated` / `user.deleted` | `{"id":5,"username":"alice"}` | 用户写操作 |
| `user.status_changed` | `{"id":5,"username":"alice"}` | 改状态 |
| `user.password_reset` | `{"id":5,"username":"alice"}` | 重置密码 |
| `user.roles_changed` | `{"id":5,"username":"alice"}` | 分配角色 |
| `org.created` / `org.updated` / `org.moved` / `org.deleted` | `{"id":2,"name":"技术中心"}` | 组织写操作 |
| `approval.created` | `{"id":1,"status":"pending"}` | 发起审批 |
| `approval.reviewed` | `{"id":1,"status":"approved"}` | 审批完成 |

统一外壳：`{"type":"<事件>","data":{...},"ts":<epoch ms>}`

> 注意：`approval` 通过落地角色时会额外走一遍 `setUserRoles`，但**不会**广播 `user.roles_changed`（只广播 `approval.reviewed`）。

- 若不是 WebSocket 升级请求，返回 **400 纯文本** `expected a WebSocket upgrade request`（非 JSON，见 §8.2）。

#### `GET /*`（catch-all）🔓

`/api/v1` 下未命中的 **GET** 路径，返回 `404` JSON：

```json
{ "code": "NOT_FOUND", "message": "接口不存在" }
```

其余方法的未命中路径不走这里，见 §8.2。

---

### 3.3 用户

用户对外视图（`UserView`，`model/user.zig:58`）字段，**永不包含 `password_hash`**：

```json
{
  "id": 5,
  "username": "alice",
  "display_name": "爱丽丝",
  "email": "alice@example.com",
  "org_id": 4,
  "org_name": "后端组",
  "status": "active",
  "failed_attempts": 0,
  "locked_until": 0,
  "last_login_at": 0,
  "created_at": 1754000000000,
  "updated_at": 1754000000000,
  "roles": [ { "id": 4, "code": "operator", "name": "运营" } ]
}
```

- `status`：`active` / `disabled` / `locked`（字符串枚举）
- `locked_until`：锁定到期时间（epoch ms），`0` 表示未锁定
- `org_name`：`org_id` 为 0 或组织不存在时为空串 `""`
- `roles`：用户持有的角色引用数组，无角色时为 `[]`

#### `GET /users` ⚡ `user:view`

查询参数：

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `page` | int | 1 | 页码，从 1 开始 |
| `page_size` | int | 20 | 每页条数，后端夹到 [1, 200] |
| `keyword` | string | `""` | 关键字，对 **username / display_name / email** 做大小写不敏感子串匹配 |
| `status` | string | （不限） | 精确匹配 `active` / `disabled` / `locked`；传空串等于不限 |
| `org_id` | int | （不限） | 只返回该组织的**直属**成员 |
| `include_sub` | string | — | 仅当同时传了 `org_id` 时有效；值为**字面量** `"true"` 时改为返回该组织及其全部子孙组织的成员 |

```json
{
  "code": "OK",
  "data": {
    "items": [
      {
        "id": 1,
        "username": "admin",
        "display_name": "系统管理员",
        "email": "admin@example.com",
        "org_id": 1,
        "org_name": "总公司",
        "status": "active",
        "failed_attempts": 0,
        "locked_until": 0,
        "last_login_at": 1754000000000,
        "created_at": 1754000000000,
        "updated_at": 1754000000000,
        "roles": [{ "id": 1, "code": "super_admin", "name": "超级管理员" }]
      }
    ],
    "total": 7,
    "page": 1,
    "page_size": 20
  }
}
```

错误：`400 VALIDATION_ERROR`（`org_id` 非整数，`message` = `org_id 必须是整数`）、`403 PERMISSION_DENIED`（`details.required` = `"user:view"`）。

#### `POST /users` ⚡ `user:create`

**201 Created**。请求体：

```json
{
  "username": "dave",
  "password": "dave12345",
  "display_name": "戴夫",
  "email": "dave@example.com",
  "org_id": 4,
  "status": "active",
  "role_ids": [4]
}
```

| 字段 | 类型 | 必填 | 默认 | 校验规则 |
| --- | --- | --- | --- | --- |
| `username` | string | ✅ | — | 3~32 字符；只允许字母、数字、`_`、`-`、`.` |
| `password` | string | ✅ | — | 6~128 字符（不做复杂度要求） |
| `display_name` | string | ✅ | — | 非空 ≤64 字符，不含控制字符 |
| `email` | string | ✅ | — | 非空 ≤128 字符；有且仅有一个 `@`，`@` 后域名 ≥3 字符且含 `.`，不含空白 |
| `org_id` | int | ❌ | `0` | 非 0 时组织必须存在 |
| `status` | string | ❌ | `"active"` | `active` / `disabled` / `locked` |
| `role_ids` | int[] | ❌ | `[]` | 每个角色 ID 必须存在 |

成功返回完整 `UserView`（含后端生成的 `id`）。

| HTTP | code | 触发条件 |
| --- | --- | --- |
| 400 | `VALIDATION_ERROR` | username / display_name / email / status 不合规 |
| 400 | `WEAK_PASSWORD` | 密码长度不在 6~128 |
| 400 | `ORG_NOT_FOUND` | `org_id` 非 0 但组织不存在（`所属组织不存在`） |
| **400** | `ROLE_NOT_FOUND` | `role_ids` 含不存在的角色（`角色 N 不存在`）——**但此时用户行已经写进去了**，见 §8.3 #1 |
| 409 | `USERNAME_TAKEN` | 用户名已被占用 |
| 409 | `EMAIL_TAKEN` | 邮箱已被占用 |

**校验顺序**（`user_service.create` → `validateCreate` → `insert`）：
1. username 格式 → 2. password 长度 → 3. display_name → 4. email → 5. status 取值 → 6. **org_id 存在性（400 ORG_NOT_FOUND）** → 7. 插入（唯一冲突 → 409 USERNAME_TAKEN / EMAIL_TAKEN） → 8. role_ids 存在性。

> 即 **`ORG_NOT_FOUND`（400）一定先于 `USERNAME_TAKEN` / `EMAIL_TAKEN`（409）报出**；这条是最近一轮"唯一性下沉 ORM"改造后的确定行为，前端不要假设 409 会先出现。
>
> 创建时 `status` **不走状态机校验**，可以直接建出 `disabled` / `locked` 用户（见 §8.3 #2）。

#### `GET /users/:id` ⚡ `user:view`

返回单个 `UserView`。`404 NOT_FOUND`（`用户不存在`）；`:id` 非整数 → `400 VALIDATION_ERROR`。

#### `PUT /users/:id` ⚡ `user:update`

请求体全部字段可选，**`null` 或缺省 = 不修改该字段**：

```json
{ "display_name": "爱丽丝·王", "email": "alice2@example.com", "org_id": 4, "status": "disabled" }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `display_name` | string? | 同创建校验 |
| `email` | string? | 同创建校验；改为他人已用邮箱 → 409 |
| `org_id` | int? | 非 0 时组织必须存在；`0` 表示"无组织" |
| `status` | string? | 走状态机校验（见 §4.2） |

> `username` 与 `password` **不可**通过本接口修改（密码用 `POST /users/:id/reset-password`）。

成功返回更新后的 `UserView`。

| HTTP | code | 触发条件 | details |
| --- | --- | --- | --- |
| 404 | `NOT_FOUND` | 用户不存在 | — |
| 400 | `VALIDATION_ERROR` | display_name / email 不合规，或 status 取值非法（`状态取值必须是 active/disabled/locked`） | — |
| 400 | `ORG_NOT_FOUND` | `org_id` 指向不存在的组织（先于唯一性报错） | — |
| 409 | `EMAIL_TAKEN` | 邮箱被其他用户占用 | — |
| 409 | `ILLEGAL_STATUS_TRANSITION` | 非法状态流转，如 `disabled → locked` | `{"from":"disabled","to":"locked"}` |

> 改为 `active` 时会自动清零 `failed_attempts` 与 `locked_until`。改为 `locked` 时**只改 `status`，不设 `locked_until`**（见 §8.3 #3）。

#### `DELETE /users/:id` ⚡ `user:delete`

```json
{ "code": "OK", "data": {} }
```

| HTTP | code | 触发条件 |
| --- | --- | --- |
| 404 | `NOT_FOUND` | 用户不存在 |
| 409 | `CANNOT_DELETE_SELF` | 删除当前登录用户（`不能删除当前登录的用户`） |

> 删除会同时清空该用户的角色关联（`setUserRoles(id, [])`）。

#### `PUT /users/:id/status` ⚡ `user:update`

请求体：

```json
{ "status": "disabled", "reason": "离职" }
```

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `status` | string | ✅ | — | `active` / `disabled` / `locked` |
| `reason` | string | ❌ | `""` | 变更说明，写入审计日志；≤500 字符 |

成功返回更新后的 `UserView`。

| HTTP | code | 触发条件 | details |
| --- | --- | --- | --- |
| 400 | `VALIDATION_ERROR` | status 取值非法，或 reason > 500 字符（`说明最多 500 个字符`） | — |
| 404 | `NOT_FOUND` | 用户不存在 | — |
| 409 | `ILLEGAL_STATUS_TRANSITION` | 非法流转（如 `disabled → locked`） | `{"from":"disabled","to":"locked"}` |
| 409 | `CANNOT_DEMOTE_SELF` | 禁用或锁定**自己**（`不能禁用或锁定自己`） | — |

副作用：
- 目标为 `active`：`failed_attempts = 0`、`locked_until = 0`
- 目标为 `locked`：`locked_until = 当前时间 + 15 分钟`（本接口是**唯一**会写入 `locked_until` 的入口）

#### `POST /users/:id/unlock` ⚡ `user:unlock`

**不需要请求体**（传了也会被忽略）。等价于 `changeStatus(id, "active", "管理员解除锁定")`。

成功返回更新后的 `UserView`。

| HTTP | code | 触发条件 |
| --- | --- | --- |
| 404 | `NOT_FOUND` | 用户不存在 |
| 409 | `ILLEGAL_STATUS_TRANSITION` | 用户当前已是 `active`（`非法状态流转：active → active`） |

> 因为底层复用了状态机，`unlock` 对 `disabled` 用户同样有效（会一并启用）。前端"解锁"按钮应对 `locked` 用户开放；对 `active` 用户调用会得到 409。

#### `POST /users/:id/reset-password` ⚡ `user:reset-password`

```json
{ "password": "newpass123" }
```

| 字段 | 类型 | 必填 | 校验 |
| --- | --- | --- | --- |
| `password` | string | ✅ | 6~128 字符 |

成功：

```json
{ "code": "OK", "data": {} }
```

副作用：清零 `failed_attempts` 与 `locked_until`，但**不改变 `status`**（锁定用户仍需单独解锁）。

错误：`400 WEAK_PASSWORD`、`404 NOT_FOUND`。

#### `PUT /users/:id/roles` ⚡ `user:assign-role`

**全量替换**用户的角色集合。

```json
{ "role_ids": [2, 3] }
```

| 字段 | 类型 | 必填 | 默认 |
| --- | --- | --- | --- |
| `role_ids` | int[] | ❌ | `[]`（传空数组 = 清空所有角色） |

成功返回更新后的 `UserView`（`roles` 已是新集合）。

错误：`404 NOT_FOUND`（用户不存在）、`400 ROLE_NOT_FOUND`（`角色 N 不存在`）。

> 无自我保护：管理员可以把自己的角色清空把自己锁死（对比 `changeStatus` 有 `CANNOT_DEMOTE_SELF`）。见 §8.3 #9。

---

### 3.4 组织

组织对外视图（`OrgView`，`model/org.zig:25`）：

```json
{
  "id": 2,
  "name": "技术中心",
  "code": "tech",
  "parent_id": 1,
  "leader": "manager",
  "sort_order": 1,
  "member_count": 2,
  "created_at": 1754000000000,
  "updated_at": 1754000000000
}
```

- `parent_id`：`0` 表示根组织
- `member_count`：**直属**成员数（不含子孙组织）
- `code` 唯一；`name` **不唯一**

#### `GET /orgs/tree` ⚡ `org:view`

无参数、不分页，直接返回**森林**（数组，每个元素是一棵树的根）。正常情况下 seed 数据是单根。

```json
{
  "code": "OK",
  "data": [
    {
      "id": 1, "name": "总公司", "code": "hq", "parent_id": 0,
      "leader": "admin", "sort_order": 0, "member_count": 1,
      "children": [
        { "id": 2, "name": "技术中心", "code": "tech", "parent_id": 1, "leader": "manager",
          "sort_order": 1, "member_count": 2,
          "children": [
            { "id": 4, "name": "后端组", "code": "backend", "parent_id": 2, "leader": "manager",
              "sort_order": 3, "member_count": 2, "children": [] },
            { "id": 5, "name": "前端组", "code": "frontend", "parent_id": 2, "leader": "",
              "sort_order": 4, "member_count": 1, "children": [] }
          ] },
        { "id": 3, "name": "市场部", "code": "market", "parent_id": 1, "leader": "auditor",
          "sort_order": 2, "member_count": 1, "children": [] }
      ]
    }
  ]
}
```

树节点字段（`TreeNode`）= `OrgView` 去掉 `created_at` / `updated_at`，加上 `children: TreeNode[]`（无子节点时为 `[]`）。

> 父节点缺失的脏数据会被提升为根；前端应容忍多根。

#### `GET /orgs` ⚡ `org:view`

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `keyword` | string | `""` | 对 **name / code** 做大小写不敏感子串匹配；空串返回全部 |

返回**扁平数组**（不分页、不排序成树）：

```json
{ "code": "OK", "data": [ { "id": 1, "name": "总公司", "code": "hq", "parent_id": 0, "leader": "admin", "sort_order": 0, "member_count": 1, "created_at": 1754000000000, "updated_at": 1754000000000 } ] }
```

#### `POST /orgs` ⚡ `org:create`

**201 Created**。

```json
{ "name": "测试部", "code": "qa", "parent_id": 1, "leader": "manager", "sort_order": 10 }
```

| 字段 | 类型 | 必填 | 默认 | 校验 |
| --- | --- | --- | --- | --- |
| `name` | string | ✅ | — | 非空 ≤64 字符，不含控制字符 |
| `code` | string | ✅ | — | 1~64 字符；只允许字母、数字、`_`、`-`（**不允许 `.`**，与用户名规则不同） |
| `parent_id` | int | ❌ | `0` | 非 0 时父组织必须存在 |
| `leader` | string | ❌ | `""` | 负责人，无长度校验 |
| `sort_order` | int | ❌ | `0` | 排序值 |

| HTTP | code | 触发条件 |
| --- | --- | --- |
| 400 | `VALIDATION_ERROR` | name / code 不合规 |
| 400 | `ORG_NOT_FOUND` | 父组织不存在（`父组织不存在`） |
| 409 | `ORG_CODE_TAKEN` | 组织编码已被占用 |

> 顺序：**先查父组织（400）再插入（409）**，即 `ORG_NOT_FOUND` 先于 `ORG_CODE_TAKEN`。

#### `GET /orgs/:id` ⚡ `org:view`

返回 `OrgView`。`404 ORG_NOT_FOUND`（`组织不存在`）。

#### `PUT /orgs/:id` ⚡ `org:update`

```json
{ "name": "技术中心（改名）", "leader": "manager", "sort_order": 1 }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `name` | string? | 同创建校验 |
| `leader` | string? | ≤64 字符（`负责人最多 64 个字符`） |
| `sort_order` | int? | 排序值 |

> `code` 与 `parent_id` **不可**通过本接口修改（改父节点用 `POST /orgs/:id/move`）。

成功返回更新后的 `OrgView`。错误：`404 ORG_NOT_FOUND`、`400 VALIDATION_ERROR`。

#### `DELETE /orgs/:id` ⚡ `org:delete`

```json
{ "code": "OK", "data": {} }
```

删除前有两道前置校验（见 §4.3）：

| HTTP | code | 触发条件 | details |
| --- | --- | --- | --- |
| 404 | `ORG_NOT_FOUND` | 组织不存在 | — |
| 409 | `ORG_HAS_CHILDREN` | 还有子组织：`组织「技术中心」下还有 2 个子组织，不能删除` | `{"children": 2}` |
| 409 | `ORG_HAS_MEMBERS` | 还有直属成员：`组织「技术中心」下还有 2 名成员，请先转移成员` | `{"members": 2}` |

> 先查子组织、再查成员；两者同时存在时只报 `ORG_HAS_CHILDREN`。

#### `POST /orgs/:id/move` ⚡ `org:move`

```json
{ "parent_id": 3 }
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `parent_id` | int | ✅ | 新父组织 ID；`0` 表示提升为根组织 |

| HTTP | code | 触发条件 | details |
| --- | --- | --- | --- |
| 404 | `ORG_NOT_FOUND` | 被移动的组织不存在 | — |
| 409 | `ORG_CYCLE` | `parent_id == :id`（`不能把组织挂到自己下面`） | — |
| 400 | `ORG_NOT_FOUND` | 目标父组织不存在（`目标父组织不存在`） | — |
| 409 | `ORG_CYCLE` | 目标父组织是自己的子孙（`不能把组织移动到自己的子组织下（会形成环）`） | — |

成功返回更新后的 `OrgView`。若 `parent_id` 与当前父节点相同，**直接返回当前视图**（不写审计日志、不改 `updated_at`）。

#### `GET /orgs/:id/members` ⚡ `org:view`

返回该组织**及其全部子孙组织**下的成员（恒含子树，无 `include_sub` 开关）。

| 参数 | 类型 | 默认 |
| --- | --- | --- |
| `page` | int | 1 |
| `page_size` | int | 20 |

返回分页的 `UserView[]`，结构与 `GET /users` 一致。

> 组织不存在时**不报 404**，而是返回空页 `{items: [], total: 0, page, page_size}`（见 §8.3 #10）。

---

### 3.5 角色与权限点

角色对外视图（`RoleView`，`model/rbac.zig:56`）：

```json
{
  "id": 1,
  "code": "super_admin",
  "name": "超级管理员",
  "description": "持有全部权限，不可删除",
  "is_builtin": true,
  "permissions": ["*"],
  "user_count": 1,
  "created_at": 1754000000000,
  "updated_at": 1754000000000
}
```

- `is_builtin`：`true` 的内置角色**不可删除**，但可改名、可改权限点（见 §8.3 #7）
- `user_count`：持有该角色的用户数（`> 0` 时禁止删除）
- `permissions`：角色持有的权限点编码数组（`super_admin` 为 `["*"]`）

#### `GET /roles` ⚡ `role:view`

无参数、不分页，返回 `RoleView[]`：

```json
{ "code": "OK", "data": [ { "id": 1, "code": "super_admin", "...": "…" } ] }
```

#### `POST /roles` ⚡ `role:create`

**201 Created**。

```json
{ "code": "support", "name": "客服", "description": "工单处理" }
```

| 字段 | 类型 | 必填 | 默认 | 校验 |
| --- | --- | --- | --- | --- |
| `code` | string | ✅ | — | 1~64 字符；只允许字母、数字、`_`、`-` |
| `name` | string | ✅ | — | 非空 ≤64 字符，不含控制字符 |
| `description` | string | ❌ | `""` | 无长度校验 |

> 新建时**不能**直接带权限点，返回的角色 `permissions: []`；随后用 `PUT /roles/:id/permissions` 配置。

错误：`400 VALIDATION_ERROR`（code / name 不合规）、`409 ROLE_CODE_TAKEN`（`角色编码已被占用`）。

#### `PUT /roles/:id` ⚡ `role:update`

```json
{ "name": "客服组", "description": "一线工单处理" }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `name` | string? | 同创建校验 |
| `description` | string? | 无长度校验 |

> `code` 不可修改。返回更新后的 `RoleView`（`updated_at` 为新值）。

错误：`404 ROLE_NOT_FOUND`（`角色不存在`）、`400 VALIDATION_ERROR`。

#### `DELETE /roles/:id` ⚡ `role:delete`

```json
{ "code": "OK", "data": {} }
```

| HTTP | code | 触发条件 | details |
| --- | --- | --- | --- |
| 404 | `ROLE_NOT_FOUND` | 角色不存在 | — |
| 409 | `ROLE_IS_BUILTIN` | 内置角色（`内置角色不可删除`） | — |
| 409 | `ROLE_IN_USE` | 还被用户持有：`角色「运营」还被 2 名用户持有，不能删除` | `{"users": 2}` |

> 删除会级联清理该角色的权限点关联与用户-角色关联。

#### `PUT /roles/:id/permissions` ⚡ `role:assign`

**全量替换**角色的权限点。

```json
{ "permissions": ["user:view", "user:create", "org:view"] }
```

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `permissions` | string[] | ❌ | `[]` | 权限点编码数组；传 `["*"]` 等价于超管；传 `[]` 清空 |

| HTTP | code | 触发条件 | details |
| --- | --- | --- | --- |
| 404 | `ROLE_NOT_FOUND` | 角色不存在 | — |
| 400 | `UNKNOWN_PERMISSION` | 含未知权限点（`未知权限点：user:nope`） | `{"permission": "user:nope"}` |

成功返回更新后的 `RoleView`。注意本接口**不更新 `updated_at`**（见 §8.3 #11）。

#### `GET /permissions` ⚡ `role:view`

无参数、不分页，返回全部 23 个权限点（**不含**通配符 `*`），顺序同 §2：

```json
{
  "code": "OK",
  "data": [
    { "code": "user:view", "module": "user", "name": "查看用户", "description": "查看用户" },
    { "code": "user:create", "module": "user", "name": "新建用户", "description": "新建用户" }
  ]
}
```

> seed 写入 permissions 表时 `description = name`（`seed.zig:50`），所以两字段值相同。

#### `GET /permissions/groups` ⚡ `role:view`

按模块分组，供前端渲染权限勾选树：

```json
{
  "code": "OK",
  "data": [
    {
      "module": "user",
      "permissions": [
        { "code": "user:view", "module": "user", "name": "查看用户", "description": "查看用户" },
        { "code": "user:create", "module": "user", "name": "新建用户", "description": "新建用户" }
      ]
    },
    { "module": "org", "permissions": [ "…" ] },
    { "module": "role", "permissions": [ "…" ] },
    { "module": "log", "permissions": [ "…" ] },
    { "module": "approval", "permissions": [ "…" ] }
  ]
}
```

> 该接口走的是编译期常量 `ALL_PERMISSIONS`（不读库），`description` 恒等于 `name`（`rbac_service.zig:72`）。模块顺序固定为 `user`、`org`、`role`、`log`、`approval`。

---

### 3.6 审计日志

审计日志条目（`model/audit.zig:12` 的完整行，含 `request_id`）：

```json
{
  "id": 12,
  "actor_id": 1,
  "actor_name": "admin",
  "module": "user",
  "action": "user.update",
  "target_type": "user",
  "target_id": 5,
  "target_label": "alice",
  "result": "success",
  "message": "更新用户 爱丽丝",
  "changes": "[{\"field\":\"email\",\"before\":\"alice@example.com\",\"after\":\"alice2@example.com\"}]",
  "ip": "127.0.0.1",
  "request_id": "a1b2c3d4",
  "created_at": 1754000000000
}
```

- `changes`：**JSON 字符串**（不是对象），需 `JSON.parse()`；无变更时为 `"[]"`
- `result`：`success` / `failure`
- `module`：`auth`、`user`、`org`、`role`、`approval`、`log`

#### `GET /logs` ⚡ `log:view`

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `page` | int | 1 | 页码 |
| `page_size` | int | 20 | 每页条数 |
| `module` | string | `""` | 精确匹配模块（如 `user`） |
| `action` | string | `""` | 精确匹配动作（如 `user.create`） |
| `result` | string | `""` | 精确匹配 `success` / `failure` |
| `keyword` | string | `""` | 大小写不敏感子串，匹配 **actor_name / target_label / module / action / message** |
| `from` | int | `0` | 起始时间（epoch ms，**闭区间**）；`0` = 不限 |
| `to` | int | `0` | 结束时间（epoch ms，**闭区间**）；`0` = 不限 |
| `actor_id` | int | （不限） | 按操作人 ID 精确匹配 |

结果按 **id 倒序（最新在前）**。

```json
{
  "code": "OK",
  "data": { "items": [ { "id": 12, "...": "…" } ], "total": 42, "page": 1, "page_size": 20 }
}
```

错误：`400 VALIDATION_ERROR`（`actor_id` 非整数，`message` = `actor_id 必须是整数`）。

#### `GET /logs/export` ⚡ `log:export`

查询参数与 `GET /logs` 相同（**忽略 `page` / `page_size`**），返回 **CSV 文件**而非 JSON：

- `Content-Type: text/csv; charset=utf-8`
- `Content-Disposition: attachment; filename="audit-logs.csv"`
- UTF-8 **带 BOM**，Excel 直接打开不乱码
- 表头：`id,actor_id,actor_name,module,action,target_type,target_id,target_label,result,message,changes,ip,created_at`
- `created_at` 格式化为 `YYYY-MM-DD HH:MM:SS`（UTC），`0` 时为空串
- 含 `,` `"` 换行 的字段用引号包裹，字段内 `"` 转义为 `""`

前端下载示例：

```js
const res = await fetch('/api/v1/logs/export?module=user', { credentials: 'same-origin' });
const blob = await res.blob();               // 不要 res.json()
const url = URL.createObjectURL(blob);
// <a href={url} download="audit-logs.csv">
```

> 副作用：导出本身会写一条审计日志（`module=log`、`action=log.export`、`message=导出 N 条审计日志`，`actor` 正确记录）。

#### `POST /logs/purge` ⚡ `log:purge`

清理 N 天前的日志。**无请求体**，天数通过 query 传：

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `days` | int | `90` | 清理 `created_at < now - days*86400000` 的日志（严格小于） |

```json
{ "code": "OK", "data": { "deleted": 128 } }
```

> `days=0` 会清空**全部**日志（无下限保护），前端务必限制输入范围。
> 副作用：清理会写一条审计日志（`module=log`、`action=log.purge`），但 `actor_id=0`、`actor_name="system"`——**查不到是谁清理的**（见 §8.3 #8）。

### 3.7 审批流

目前只有一种审批类型：`role_change`（用户角色变更申请）。

审批单字段（`model/approval.zig:40`）：

```json
{
  "id": 1,
  "kind": "role_change",
  "applicant_id": 2,
  "applicant_name": "manager",
  "target_user_id": 5,
  "target_user_name": "爱丽丝",
  "role_id": 4,
  "role_name": "运营",
  "reason": "爱丽丝需要运营后台权限",
  "status": "pending",
  "reviewer_id": 0,
  "reviewer_name": "",
  "review_comment": "",
  "created_at": 1754000000000,
  "updated_at": 1754000000000
}
```

- `status`：`pending` / `approved` / `rejected` / `cancelled`
- `reviewer_id` / `reviewer_name` / `review_comment`：审批后才有值；未审批时为 `0` / `""` / `""`。`reviewer_name` 存的是**用户名**
- `applicant_name`：新建接口写入的是**用户名**（`username`），而 seed 数据写入的是**显示名**——两者不一致（见 §8.3 #6）
- `target_user_name` 存的是目标用户的**显示名**

#### `GET /approvals` ⚡ `approval:view`

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `page` | int | 1 | 页码 |
| `page_size` | int | 20 | 每页条数 |
| `status` | string | `""` | 精确匹配 `pending` / `approved` / `rejected` / `cancelled` |
| `keyword` | string | `""` | 大小写不敏感子串，匹配 **applicant_name / target_user_name / role_name / reason** |

结果按 **id 倒序（最新在前）**：

```json
{ "code": "OK", "data": { "items": [ { "id": 1, "...": "…" } ], "total": 1, "page": 1, "page_size": 20 } }
```

#### `POST /approvals` ⚡ `approval:create`

**201 Created**。申请人 = 当前登录用户（后端自动填，不可指定）。

```json
{ "target_user_id": 5, "role_id": 4, "reason": "需要运营后台权限" }
```

| 字段 | 类型 | 必填 | 默认 | 校验 |
| --- | --- | --- | --- | --- |
| `target_user_id` | int | ✅ | — | 目标用户必须存在 |
| `role_id` | int | ✅ | — | 角色必须存在 |
| `reason` | string | ❌ | `""` | ≤500 字符 |

| HTTP | code | 触发条件 |
| --- | --- | --- |
| 400 | `VALIDATION_ERROR` | `reason` > 500 字符 |
| 404 | `NOT_FOUND` | 目标用户不存在（`目标用户不存在`） |
| 404 | `ROLE_NOT_FOUND` | 角色不存在（`角色不存在`） |
| **409** | `VALIDATION_ERROR` | 该用户已有一份针对此角色的 **pending** 单（`该用户已有一份针对此角色的待审批申请`） |

> ⚠️ 最后一条**用了 409 状态码但错误码是 `VALIDATION_ERROR`**，前端按 HTTP 状态分支即可（见 §8.3 #4）。

成功返回新建的审批单（`status = "pending"`、`kind = "role_change"`）。

#### `GET /approvals/:id` ⚡ `approval:view`

返回单个审批单。`404 NOT_FOUND`（`审批单不存在`）。

#### `POST /approvals/:id/review` ⚡ `approval:review`

```json
{ "action": "approve", "comment": "同意" }
```

| 字段 | 类型 | 必填 | 默认 | 取值 |
| --- | --- | --- | --- | --- |
| `action` | string | ✅ | — | `approve` / `reject` / `cancel` |
| `comment` | string | ❌ | `""` | 审批意见，≤500 字符 |

| HTTP | code | 触发条件 | details |
| --- | --- | --- | --- |
| 400 | `VALIDATION_ERROR` | action 取值非法（`动作必须是 approve/reject/cancel`）或 comment > 500 | — |
| 404 | `NOT_FOUND` | 审批单不存在 | — |
| 409 | `ILLEGAL_APPROVAL_TRANSITION` | 非 `pending` 单再流转（`非法流转：approved 单不能执行 approve`） | `{"from":"approved","action":"approve"}` |
| 403 | `PERMISSION_DENIED` | `cancel` 且既非申请人也非超管（`只能撤回自己发起的申请`） | — |
| 403 | `PERMISSION_DENIED` | `approve` / `reject` 且当前用户就是申请人（`不能审批自己发起的申请`，**超管也不例外**） | — |

成功返回更新后的审批单（`reviewer_id` / `reviewer_name` / `review_comment` / `updated_at` 已更新）。

**`approve` 的副作用**：把 `role_id` **追加**进目标用户的角色集合（已存在则不重复），并额外写一条审计日志（`module=user`、`action=user.assign_roles`、`message=审批通过，授予角色 运营`）。

---

## 4. 业务规则说明

### 4.1 登录失败与锁定策略

- 连续失败阈值 **`MAX_FAILED_ATTEMPTS = 5`**，锁定时长 **`LOCK_DURATION_MS = 15 分钟`**（`auth_service.zig:21`）
- 计数存在用户行的 `failed_attempts`（**累计不清零**，只在成功登录或改回 `active` 时清零）
- 计数**不区分来源**、不按时间窗口衰减

| 第 N 次失败 | HTTP | code | message | details |
| --- | --- | --- | --- | --- |
| 1 | 401 | `INVALID_CREDENTIALS` | `用户名或密码错误，还可尝试 4 次` | `{"remaining_attempts":4}` |
| 2 | 401 | `INVALID_CREDENTIALS` | `用户名或密码错误，还可尝试 3 次` | `{"remaining_attempts":3}` |
| 3 | 401 | `INVALID_CREDENTIALS` | `用户名或密码错误，还可尝试 2 次` | `{"remaining_attempts":2}` |
| 4 | 401 | `INVALID_CREDENTIALS` | `用户名或密码错误，还可尝试 1 次` | `{"remaining_attempts":1}` |
| **5** | **423** | `ACCOUNT_LOCKED` | `连续5次密码错误，账号已锁定，请在15 分钟后重试` | `{"locked_until":…,"remaining_ms":900000,"failed_attempts":5}` |

锁定期间再登录（状态 `locked` 且 `locked_until > now`）：

```json
{
  "code": "ACCOUNT_LOCKED",
  "message": "账号已锁定，请在14 分 30 秒后重试",
  "details": { "locked_until": 1754000900000, "remaining_ms": 870000 }
}
```

HTTP 状态为 **423 Locked**（不是 403）。剩余时间文案由后端生成，向上取整到秒：`"45 秒"` / `"1 分钟"` / `"15 分钟"` / `"14 分 30 秒"`。

**自动解锁**：若 `locked_until` 已过期，登录时会放行；口令校验通过后 status 被置回 `active`、`failed_attempts` 与 `locked_until` 清零。

**用户名不存在**与**密码错误**返回同样的 `401 INVALID_CREDENTIALS`（`用户名或密码错误`，**无 details**），不泄露用户是否存在。但会写一条审计日志（`action=login.failure`、`actor_id=0`、`actor_name` 为输入的用户名）。

**账号被禁用**（`disabled`）：`403 ACCOUNT_DISABLED`，`账号已被禁用，请联系管理员`，**不受失败计数影响、不写审计日志**。

**会话固定防护**：登录前会作废旧的 `sid` cookie 对应的会话，再创建新会话。

**已登录会话被踢**：`auth_service.resolve` 要求用户 `status == active`；用户被禁用/锁定/删除后，其既有会话下一次请求即返回 `401 SESSION_EXPIRED`。

### 4.2 用户状态机

```
        ┌──────────── 启用（active）◄────────────┐
        │                                        │
   active ──禁用──► disabled                locked ──解锁──► active
        │                                        ▲
        └──────────── 锁定（locked）─────────────┘
```

合法流转（`model/user.zig:20` 的 `transitionAllowed`）：

| 从 ↓ \ 到 → | active | disabled | locked |
| --- | --- | --- | --- |
| **active** | ❌ | ✅ | ✅ |
| **disabled** | ✅ | ❌ | ❌ |
| **locked** | ✅ | ❌ | ❌ |

- `disabled` 与 `locked` 之间**不可直接互转**，必须先回到 `active`
- 任何"原地不动"的流转（如 `active → active`）都非法
- 非法流转 → `409 ILLEGAL_STATUS_TRANSITION`，`message` = `非法状态流转：disabled → locked`，`details` = `{"from":"disabled","to":"locked"}`

各入口的行为差异：

| 入口 | 权限点 | 走状态机? | 到 active | 到 locked | 自我保护 |
| --- | --- | --- | --- | --- | --- |
| `POST /users`（创建） | `user:create` | ❌ | 直接建 | 直接建（`locked_until=0`，**不会真正锁住**，见 §8.3 #2） | — |
| `PUT /users/:id` | `user:update` | ✅ | 清 `failed_attempts`、`locked_until` | 只改 status，**不设 `locked_until`**（见 §8.3 #3） | ❌ 可禁用别人以外的任何合法流转 |
| `PUT /users/:id/status` | `user:update` | ✅ | 清 `failed_attempts`、`locked_until` | 设 `locked_until = now + 15min` | ✅ 不能禁用/锁定自己（`CANNOT_DEMOTE_SELF`） |
| `POST /users/:id/unlock` | `user:unlock` | ✅ | 同上（reason 固定 `管理员解除锁定`） | — | ❌（对已是 active 的用户会得到 409） |
| `DELETE /users/:id` | `user:delete` | — | — | — | ✅ 不能删自己（`CANNOT_DELETE_SELF`） |

### 4.3 组织删除的前置校验

按顺序执行两步，**任一不满足即 409**：

1. **有子组织** → `409 ORG_HAS_CHILDREN`
   `message`：`组织「技术中心」下还有 2 个子组织，不能删除`
   `details`：`{"children": 2}`
2. **有直属成员** → `409 ORG_HAS_MEMBERS`
   `message`：`组织「技术中心」下还有 2 名成员，请先转移成员`
   `details`：`{"members": 2}`

前端交互建议：删除前先读 `member_count` 与 `children.length`，两者都为 0 才启用删除按钮；仍要处理 409（并发场景）。

### 4.4 组织移动的防环

`POST /orgs/:id/move` 用 `model/org.zig:113` 的 `isAncestor(rows, id, new_parent_id)`（判断 `id` 是否是 `new_parent_id` 的祖先，**含自身**）拦截：

1. 被移动组织不存在 → `404 ORG_NOT_FOUND`
2. `new_parent_id == id` → `409 ORG_CYCLE`，`不能把组织挂到自己下面`
3. `new_parent_id != 0` 但父组织不存在 → `400 ORG_NOT_FOUND`，`目标父组织不存在`
4. `id` 是 `new_parent_id` 的祖先（即把父节点挂到自己的子孙下）→ `409 ORG_CYCLE`，`不能把组织移动到自己的子组织下（会形成环）`
5. 目标父节点与当前相同 → 200 直接返回当前视图（幂等，无副作用、不改 `updated_at`、不写审计日志）

前端交互建议：拖拽前在树上判断"目标节点是否在被拖动节点的子树内"（含自身），直接禁用该落点。

### 4.5 审批流状态机

```
                  ┌── approve  ──► approved  (终态)
   pending ───────┼── reject   ──► rejected  (终态)
                  └── cancel   ──► cancelled (终态)
```

- 只有 `pending` 单可以流转；三个终态之间**互不可转**，也**不能回到 pending**
- 非法流转 → `409 ILLEGAL_APPROVAL_TRANSITION`，`message` = `非法流转：approved 单不能执行 approve`，`details` = `{"from":"approved","action":"approve"}`
- `action` 取值非法 → `400 VALIDATION_ERROR`，`动作必须是 approve/reject/cancel`
- **申请人不能审批自己发起的单**（`approve` / `reject`）→ `403 PERMISSION_DENIED`，`不能审批自己发起的申请`。**超管也不例外**
- **撤回（`cancel`）只能是申请人本人或超管** → 否则 `403 PERMISSION_DENIED`，`只能撤回自己发起的申请`
- 重复提交拦截：同一 `target_user_id` + 同一 `role_id` 已存在 `pending` 单 → `409`（错误码却是 `VALIDATION_ERROR`）
- `approve` 才真正落地角色变更（**追加**，不覆盖已有角色）；`reject` / `cancelled` 不产生任何权限变更
- 判定顺序：`comment` 长度 → `action` 取值 → 审批单存在 → 状态流转 → cancel 权限 → 自审权限

### 4.6 审计日志记录了什么

**记录范围**：登录（成功/失败/锁定）、登出，以及用户、组织、角色、审批的全部写操作，还有日志导出与清理。

字段含义：

| 字段 | 说明 |
| --- | --- |
| `actor_id` / `actor_name` | 操作人。系统内部动作为 `0` / `"system"`；登录失败（用户不存在）时 `actor_id=0`、`actor_name` 是输入的用户名 |
| `module` | `auth` / `user` / `org` / `role` / `approval` / `log` |
| `action` | 见下表 |
| `target_type` / `target_id` / `target_label` | 操作对象（`user` / `org` / `role` / `approval` / `audit_log`） |
| `result` | `success` / `failure`（只有登录失败/锁定会写 `failure`） |
| `message` | 人话摘要 |
| `changes` | **JSON 字符串**，字段级 diff |
| `ip` / `request_id` | 来源 IP、请求 ID（`X-Request-Id`） |

`action` 取值（22 个；前 20 个在 `model/audit.zig:50` 的常量表里，后 2 个是运行时硬编码、不在常量表里）：

| action | module | 触发 |
| --- | --- | --- |
| `login.success` | auth | 登录成功 |
| `login.failure` | auth | 登录失败（含用户名不存在） |
| `login.locked` | auth | 登录时命中锁定 / 刚被锁定 |
| `logout` | auth | 登出 |
| `user.create` | user | 新建用户 |
| `user.update` | user | 修改用户 |
| `user.delete` | user | 删除用户 |
| `user.status.change` | user | 状态流转 / 解锁 |
| `user.reset_password` | user | 重置密码 |
| `user.assign_roles` | user | 分配角色；**审批通过落地角色时也会记一条** |
| `org.create` | org | 新建组织 |
| `org.update` | org | 修改组织 |
| `org.delete` | org | 删除组织 |
| `org.move` | org | 移动组织 |
| `role.create` | role | 新建角色 |
| `role.update` | role | 修改角色 |
| `role.delete` | role | 删除角色 |
| `role.assign_permissions` | role | 配置角色权限 |
| `approval.create` | approval | 发起审批 |
| `approval.review` | approval | 审批（approve/reject/cancel） |
| `log.export` | log | 导出审计日志（硬编码） |
| `log.purge` | log | 清理审计日志（硬编码，`actor_id=0`、`actor_name="system"`） |

#### `changes` 的 diff 结构

`changes` 是**字符串**，内容是 JSON 数组，需 `JSON.parse()`：

```json
[
  { "field": "email",  "before": "alice@example.com", "after": "alice2@example.com" },
  { "field": "status", "before": "active",            "after": "disabled" }
]
```

- 三个字段恒为**字符串**（数字、布尔也被格式化成字符串，如 `"4"`、`"true"`）
- 无变更时为 `"[]"`（不是 `null`，也不是 `{}`）
- 前端渲染示例：`changes.map(c => \`${c.field}: ${c.before} → ${c.after}\`)`

参与 diff 的字段（其余被 `diff_ignore` 排除）：

| 实体 | 参与 diff 的字段 |
| --- | --- |
| user | `username`、`display_name`、`email`、`org_id`、`status`（`id`/`password_hash`/`failed_attempts`/`locked_until`/三个时间戳不参与） |
| org | `name`、`code`、`parent_id`、`leader`、`sort_order` |
| role | `code`、`name`、`description`、`is_builtin` |

非 diff 类的专用记录（`changes` 是手工构造的单元素数组）：

- 用户状态流转：`[{"field":"status","before":"active","after":"disabled"}]`
- 分配角色：`[{"field":"roles","before":"2,3","after":"2"}]`（逗号连接的角色 ID；空集合为 `-`）
- 角色权限：`[{"field":"permissions","before":"user:view,org:view","after":"user:view"}]`（空集合为 `-`）
- 组织移动：`[{"field":"parent_id","before":"1","after":"3"}]`
- 审批：`[{"field":"status","before":"pending","after":"approved"}]`

### 4.7 唯一性约束与校验顺序

**落点**（ORM 层 `unique` 约束，见 `model/user.zig:52`、`model/org.zig:20`、`model/rbac.zig:42`）：

| 实体 | 唯一字段 | 冲突时 |
| --- | --- | --- |
| 用户 | `users.username` | `409 USERNAME_TAKEN`，`用户名已被占用` |
| 用户 | `users.email` | `409 EMAIL_TAKEN`，`邮箱已被占用` |
| 组织 | `orgs.code` | `409 ORG_CODE_TAKEN`，`组织编码已被占用` |
| 角色 | `roles.code` | `409 ROLE_CODE_TAKEN`，`角色编码已被占用` |
| 权限点 | `permissions.code` | seed 保证唯一，无对外创建接口 |

> 组织 `name`、角色 `name` **不唯一**。用户 `username` **不可修改**，因此创建后不会冲突；`PUT /users/:id` 改 `email` 时才可能触发 `EMAIL_TAKEN`。
> 用户删除是物理删除，删除后其 `username` / `email` 可被重新使用。

**唯一性冲突 vs 外键存在性校验，谁先报？**

最近一轮把唯一性下沉到 ORM 后，service 层不再"先查再插"，但**入参外键的存在性检查仍在插入之前**（`validateCreate` / `create` 里的 `findById`），因此顺序是确定的：

| 接口 | 顺序 | 结论 |
| --- | --- | --- |
| `POST /users` | 格式校验 → **`org_id` 存在性（400 `ORG_NOT_FOUND`）** → insert（409 `USERNAME_TAKEN` / `EMAIL_TAKEN`）→ `role_ids` 存在性（400 `ROLE_NOT_FOUND`） | **`ORG_NOT_FOUND` 先于 `USERNAME_TAKEN` / `EMAIL_TAKEN`**；`ROLE_NOT_FOUND` 最后，且发生时用户已落库（§8.3 #1） |
| `PUT /users/:id` | 用户存在（404）→ 格式校验 → **`org_id` 存在性（400 `ORG_NOT_FOUND`）** → update（409 `EMAIL_TAKEN`） | **`ORG_NOT_FOUND` 先于 `EMAIL_TAKEN`** |
| `POST /orgs` | 格式校验 → **`parent_id` 存在性（400 `ORG_NOT_FOUND`，`父组织不存在`）** → insert（409 `ORG_CODE_TAKEN`） | **`ORG_NOT_FOUND` 先于 `ORG_CODE_TAKEN`** |
| `POST /roles` | 格式校验 → insert（409 `ROLE_CODE_TAKEN`） | 无外键，只有唯一冲突 |
| `POST /approvals` | `reason` 长度 → 目标用户（404 `NOT_FOUND`）→ 角色（404 `ROLE_NOT_FOUND`）→ 重复 pending（409） | 外键类 404 先于业务冲突 |

> 前端提示文案应按 **HTTP 状态 → `code`** 二级分支，不要只按"是不是重名"猜。同一个表单里 `org_id` 填错 + 用户名重名时，后端只会报 `400 ORG_NOT_FOUND`。

**冲突码如何区分**：ORM 只抛一个不带字段名的 `error.UniqueViolation`，service 事后重查还原：
- `users` 表只有 `username` / `email` 两条唯一约束 → 重查 `username` 命中就报 `USERNAME_TAKEN`，否则报 `EMAIL_TAKEN`（`user_service.zig:90`）
- `orgs` / `roles` 只有一条 → 直接报对应 code

---

## 5. 完整路由表速查

| # | 方法 | 路径 | 鉴权 |
| --- | --- | --- | --- |
| 1 | GET | `/health` | 🔓 |
| 2 | POST | `/auth/login` | 🔓 |
| 3 | POST | `/auth/logout` | 🔑 |
| 4 | GET | `/auth/me` | 🔑 |
| 5 | GET | `/auth/permissions` | 🔑 |
| 6 | GET | `/dashboard/stats` | 🔑 |
| 7 | GET | `/ws` | 🔑（WebSocket） |
| 8 | GET | `/users` | `user:view` |
| 9 | POST | `/users` | `user:create` |
| 10 | GET | `/users/:id` | `user:view` |
| 11 | PUT | `/users/:id` | `user:update` |
| 12 | DELETE | `/users/:id` | `user:delete` |
| 13 | PUT | `/users/:id/status` | `user:update` |
| 14 | POST | `/users/:id/unlock` | `user:unlock` |
| 15 | POST | `/users/:id/reset-password` | `user:reset-password` |
| 16 | PUT | `/users/:id/roles` | `user:assign-role` |
| 17 | GET | `/orgs/tree` | `org:view` |
| 18 | GET | `/orgs` | `org:view` |
| 19 | POST | `/orgs` | `org:create` |
| 20 | GET | `/orgs/:id` | `org:view` |
| 21 | PUT | `/orgs/:id` | `org:update` |
| 22 | DELETE | `/orgs/:id` | `org:delete` |
| 23 | POST | `/orgs/:id/move` | `org:move` |
| 24 | GET | `/orgs/:id/members` | `org:view` |
| 25 | GET | `/roles` | `role:view` |
| 26 | POST | `/roles` | `role:create` |
| 27 | PUT | `/roles/:id` | `role:update` |
| 28 | DELETE | `/roles/:id` | `role:delete` |
| 29 | PUT | `/roles/:id/permissions` | `role:assign` |
| 30 | GET | `/permissions` | `role:view` |
| 31 | GET | `/permissions/groups` | `role:view` |
| 32 | GET | `/logs` | `log:view` |
| 33 | GET | `/logs/export` | `log:export` |
| 34 | POST | `/logs/purge?days=90` | `log:purge` |
| 35 | GET | `/approvals` | `approval:view` |
| 36 | POST | `/approvals` | `approval:create` |
| 37 | GET | `/approvals/:id` | `approval:view` |
| 38 | POST | `/approvals/:id/review` | `approval:review` |
| — | GET | `/*` | 🔓 catch-all，返回 404 JSON |

**合计 38 个业务接口 + 1 条 catch-all。**

---

## 6. 前端对接注意事项

1. **必须带 credentials**。会话走 Cookie，所有 `fetch` 都要带：
   ```js
   fetch('/api/v1/users', { credentials: 'same-origin' })   // 同源（127.0.0.1:9000 或 Vite 代理）
   ```
   若前端跑在别的端口且**没有**代理，需要用 `credentials: 'include'`，但后端 CORS 是默认配置（`allow_credentials=false` + 通配 origin），**跨域带 Cookie 会被浏览器拒绝**。
   → 结论：开发期必须用 Vite 代理（已配好 `/api`、`/admin`），生产构建产物放到 `public/app/` 由 9000 端口同源提供。**不要直连 9000 做跨域调用。**

2. **WebSocket 需要单独配置代理**。Vite 的 `server.proxy` 默认不转发 WebSocket 升级请求；`/api/v1/ws` 在开发期需要给 proxy 加 `ws: true`，否则连接失败。非升级请求访问 `/api/v1/ws` 会返回 **400 纯文本**。

3. **分页参数**统一是 `page`（1 起）与 `page_size`（默认 20，上限 200）。`GET /orgs`、`GET /orgs/tree`、`GET /roles`、`GET /permissions`、`GET /permissions/groups`、`GET /logs/export` **不支持分页**，直接返回数组。

4. **时间字段全是 epoch 毫秒（UTC）**，`0` 表示未设置。渲染前自行格式化：`new Date(created_at).toLocaleString()`。CSV 导出里的时间是 `YYYY-MM-DD HH:MM:SS`（UTC，无时区标记），`0` 时为空串。

5. **枚举一律用字符串**（不是数字、不是下划线大写）：

   | 字段 | 取值 |
   | --- | --- |
   | `user.status` | `active`、`disabled`、`locked` |
   | `approval.status` | `pending`、`approved`、`rejected`、`cancelled` |
   | `approval.kind` | `role_change` |
   | review `action`（入参） | `approve`、`reject`、`cancel` |
   | `audit.result` | `success`、`failure` |
   | `audit.module` | `auth`、`user`、`org`、`role`、`approval`、`log` |
   | `org.parent_id` | 数字，`0` = 根 |
   | `role.is_builtin` | 布尔 `true` / `false` |
   | 权限点 | 见 §2（小写 `模块:动作`，如 `user:create`）；超管为 `["*"]` |

6. **状态码语义**：
   - `200` 成功；`201` 仅出现在 4 个创建接口（`/users`、`/orgs`、`/roles`、`/approvals`）
   - `400` 参数/校验问题（含 JSON 解析失败、外键不存在、`UNKNOWN_PERMISSION`）
   - `401` 未登录或会话失效 → 前端应跳登录页
   - `403` 登录了但缺权限点（`details.required` 告诉你是哪个）或业务级禁止（禁用账号、审批人身份不合规）
   - `404` 资源不存在（或 `/api/v1` 下未命中的 GET 路径）
   - `409` 业务冲突（唯一键冲突、非法状态流转、删除前置校验失败、删自己）
   - `423` **仅**账号锁定（HTTP 423 Locked，前端容易漏判，务必单独处理）
   - `429` 全局限流（**纯文本**，见 §1.4）
   - `500` 服务器内部错误

7. **统一的响应处理范式**（必须先判 Content-Type，否则 405/429/WS 的纯文本会让 `res.json()` 抛 `SyntaxError`）：

   ```js
   async function api(path, init = {}) {
     const res = await fetch('/api/v1' + path, {
       ...init,
       credentials: 'same-origin',
       headers: { 'Content-Type': 'application/json', ...init.headers },
     });
     const ct = res.headers.get('content-type') ?? '';
     if (!ct.includes('application/json')) {
       throw new Error(`非 JSON 响应（${res.status}）——可能命中了 405 / 429 / WS 纯文本分支`);
     }
     const body = await res.json();
     if (!res.ok) {
       const err = new Error(body.message ?? '请求失败');
       err.code = body.code;
       err.details = body.details;   // 可能 undefined
       err.status = res.status;
       throw err;
     }
     return body.data;
   }
   ```

8. **`changes` 是 JSON 字符串**，解析前先判空：`const diff = log.changes ? JSON.parse(log.changes) : []`。

9. **查询参数不会做 URL 解码**（`core/util.zig:18` 的 `queryStr` 直接用 `ctx.query()` 的原始值）。`keyword` 传中文或空格时（`%E7%88%B1`）匹配不到任何记录。**建议 `keyword` 只用 ASCII**（用户名、邮箱、角色 code 等）；中文检索目前不可用（见 §8.3 #1）。

10. **权限驱动 UI**：登录后用 `GET /auth/permissions` 拿 `permissions` 数组，配合 §2 的权限点→接口映射决定菜单/按钮显隐。后端也会校验，前端隐藏只是体验优化。持有 `"*"` 时放行一切。

11. **写操作后刷新**：后端通过 `GET /ws` 广播事件（§3.2），可用于列表自动刷新；不做实时也可以操作后重拉。注意审批通过**不会**广播 `user.roles_changed`。

12. **别高频轮询**：全局 120 次/分钟的限流罩着 `/api/v1`（§1.4），多标签页 + 定时刷新很容易打满 → 429。

13. **不要硬编码 ID**：组织/用户/角色的 ID 由插入顺序决定，`data/app` 被清空重跑 seed 或用不同顺序插入都会变。一律以接口返回为准，用 `code`（`hq`/`tech`/…、`super_admin`/…）做业务判断更稳。

---

## 7. 错误码总表

共 **27** 个错误码（`core/errors.zig:58` 的 `codes`），另有成功码 `OK`。

| code | HTTP | 含义 | 常见触发 | details |
| --- | --- | --- | --- | --- |
| `INVALID_JSON` | 400 | 请求体非法 | body 为空 / JSON 语法错误 / 缺必填字段 / body > 1 MiB | — |
| `VALIDATION_ERROR` | 400 | 参数校验失败 | 用户名/邮箱/名称/编码/状态取值不合规、路径参数非整数、`org_id`/`actor_id` 非整数 | — |
| `WEAK_PASSWORD` | 400 | 密码强度不足 | 密码不在 6~128 字符 | — |
| `UNKNOWN_PERMISSION` | 400 | 未知权限点 | 配置角色权限时传入清单外的编码 | `{"permission":"…"}` |
| `ORG_NOT_FOUND` | 400 | 组织不存在（作为**入参**时） | `POST /users`、`PUT /users/:id` 的 `org_id` 非法；`POST /orgs` 的 `parent_id` 非法；move 的目标父组织非法 | — |
| `ROLE_NOT_FOUND` | 400 | 角色不存在 | `role_ids` 含不存在的角色（创建用户 / 分配角色） | — |
| `UNAUTHORIZED` | 401 | 未登录 | 权限守卫或 handler 未取到登录主体 | — |
| `SESSION_EXPIRED` | 401 | 会话失效 | 无 `sid` / 会话过期 / 用户被删 / 用户状态非 `active` | — |
| `INVALID_CREDENTIALS` | 401 | 用户名或密码错误 | 登录失败（未锁定） | 密码错误时 `{"remaining_attempts":N}`；用户不存在时无 |
| `PERMISSION_DENIED` | 403 | 权限不足或业务禁止 | 缺权限点；账号被禁用；审批人身份不合规 | 缺权限时 `{"required":"user:create"}` |
| `ACCOUNT_DISABLED` | 403 | 账号已禁用 | 登录 `disabled` 账号 | — |
| `ACCOUNT_LOCKED` | 423 | 账号已锁定 | 锁定期内登录 / 第 5 次失败 | `{"locked_until":…,"remaining_ms":…}`（刚锁定时额外带 `failed_attempts`） |
| `NOT_FOUND` | 404 | 资源不存在 | 用户 / 审批单 / 目标用户不存在 | — |
| `ORG_NOT_FOUND` | 404 | 组织不存在（作为**路径资源**时） | `GET/PUT/DELETE /orgs/:id`、move 的 `:id` | — |
| `ROLE_NOT_FOUND` | 404 | 角色不存在 | `PUT/DELETE /roles/:id`、`PUT /roles/:id/permissions`、`POST /approvals` 的 `role_id` | — |
| `USERNAME_TAKEN` | 409 | 用户名已被占用 | 创建用户 | — |
| `EMAIL_TAKEN` | 409 | 邮箱已被占用 | 创建/修改用户 | — |
| `ORG_CODE_TAKEN` | 409 | 组织编码已被占用 | 创建组织 | — |
| `ROLE_CODE_TAKEN` | 409 | 角色编码已被占用 | 创建角色 | — |
| `ORG_HAS_CHILDREN` | 409 | 组织下仍有子组织 | 删除组织 | `{"children":N}` |
| `ORG_HAS_MEMBERS` | 409 | 组织下仍有成员 | 删除组织 | `{"members":N}` |
| `ORG_CYCLE` | 409 | 会形成环 | 组织移动到自己/子孙下 | — |
| `ROLE_IN_USE` | 409 | 角色仍被用户持有 | 删除角色 | `{"users":N}` |
| `ROLE_IS_BUILTIN` | 409 | 内置角色不可删 | 删除内置角色 | — |
| `ILLEGAL_STATUS_TRANSITION` | 409 | 非法用户状态流转 | `PUT /users/:id`、`PUT /users/:id/status`、unlock | `{"from":"…","to":"…"}` |
| `ILLEGAL_APPROVAL_TRANSITION` | 409 | 非法审批流转 | 终态单再次审批 | `{"from":"…","action":"…"}` |
| `CANNOT_DELETE_SELF` | 409 | 不能删除自己 | 删除当前登录用户 | — |
| `CANNOT_DEMOTE_SELF` | 409 | 不能禁用/锁定自己 | 改自己状态为 disabled/locked | — |
| `VALIDATION_ERROR` | **409** | 重复提交审批 | 同用户+同角色已有 pending 单 | — |
| `INTERNAL_ERROR` | 500 | 服务器内部错误 | 未捕获异常 / 会话服务不可用 / 框架 `AppError` | — |

> - `ORG_NOT_FOUND` / `ROLE_NOT_FOUND` / `VALIDATION_ERROR` 在不同接口会落到不同 HTTP 状态，前端请**先按 HTTP 状态分流，再按 `code` 细化**。
> - 429（限流）、405（方法不允许）、`/api/v1` 之外的 404 都是**纯文本**，没有 `code`，见 §8.2。
> - 框架的 `AppError` 会被 `error_json` 中间件统一翻成 `{"code":"INTERNAL_ERROR","message":<原文>}`，保留原 HTTP 状态。

---

## 8. 已知缺口 / 已知不一致

### 8.1 `examples/API.md` 的引用确认 ✅

`examples/src/main.zig` 的注释里引用了本文档：`src/main.zig:19`（分层业务后端说明）与 `src/main.zig:402`（`// 契约见 examples/API.md，踩坑清单见 examples/FRICTION.md。`）。两处指向的文件都真实存在，无需改动代码。

### 8.2 非 JSON 响应的坑（前端必踩）⚠️

| 请求 | 实际返回 |
| --- | --- |
| `GET /api/v1/拼错的URL` | ✅ `404` JSON `{"code":"NOT_FOUND","message":"接口不存在"}`（group catch-all 兜底） |
| `PUT /api/v1/拼错的URL`（catch-all 只注册了 GET，`app.zig:201`） | ❌ `405` **纯文本** `Method Not Allowed`（带 `Allow: GET` 头） |
| `POST /api/v1/users/1`（`/users/:id` 只注册了 GET/PUT/DELETE） | ❌ `405` **纯文本** `Method Not Allowed` |
| `DELETE /api/v1/logs`（只注册了 GET/POST） | ❌ `405` **纯文本** `Method Not Allowed` |
| 任意 `/api/v1/*` 触发限流 | ❌ `429` **纯文本** `Rate limit exceeded`（带 `Retry-After`） |
| `GET /api/v1/ws` 但没带 Upgrade 头 | ❌ `400` **纯文本** `expected a WebSocket upgrade request` |
| `/api/v1` 之外的路径（如 `/xxx`） | ❌ `404` **纯文本** `Not Found`（框架全局 `notFoundHandler`） |

**前端必须防御**：`res.json()` 之前先检查 `Content-Type` 是否为 `application/json`（见 §6.7 的 `api()` 范式），否则会抛 `SyntaxError: Unexpected token 'M'`。

> 为什么 catch-all 不能删：删掉后 `GET /api/v1/nope` 会落到框架全局 handler，返回 `{"error_code":"not_found",…}`，字段名是 `error_code` 而不是契约里的 `code`；405 依旧是纯文本。详见 `examples/FRICTION.md` F-12 与 `app.zig:188` 的注释。

### 8.3 阅读代码时发现的接口不一致 / 疑似后端缺陷（**未修改任何代码**，供后端决策）

| # | 位置 | 现象 | 影响 |
| --- | --- | --- | --- |
| 1 | `service/user_service.zig:104-107`（create） | 用户行先 `insert`（并落盘 flush），**之后**才 `validateRoleIds`；`role_ids` 含不存在角色时返回 `400 ROLE_NOT_FOUND`，但用户已经建出来了，且没写审计日志、没发通知 | **失败响应却产生了副作用**：前端看到 400 会以为没建成，重试则撞 `USERNAME_TAKEN`。建议把角色校验提到 insert 之前（或整体包事务） |
| 2 | `service/user_service.zig:77-89`（create） | 以 `status: "locked"` 创建用户时 `locked_until = 0` | 登录时 `remainingLockMs(now, 0) == 0` 放行，**新建的"锁定"用户实际能正常登录**，且成功后状态被改成 `active` |
| 3 | `service/user_service.zig:150-168`（update） | `PUT /users/:id` 改 `status` 为 `locked` 时**不设 `locked_until`** | 同上：通过改状态"锁定"的用户仍可登录。只有 `PUT /users/:id/status` 会写 `locked_until`——三个入口对"锁定"的语义不一致 |
| 4 | `service/approval_service.zig:59` | 重复提交用 `409` 状态码 + `VALIDATION_ERROR` 错误码 | 错误码与 HTTP 状态语义不匹配，前端按 `code` 分支会误判成 400 |
| 5 | `service/approval_service.zig:68` vs `service/seed.zig:296` | 新建审批写 `applicant_name = actor.username`；seed 写的是 `display_name` | 同一字段两种语义，`GET /approvals` 的列表展示与 `keyword` 检索不一致（seed 的单用中文搜得到，新建的只能用用户名搜） |
| 6 | `service/rbac_service.zig:72` | `permissionModules` 把 `description` 填成 `name`（`.description = q.name`） | `GET /permissions/groups` 的 `description` 无信息量（虽然 `GET /permissions` 在 seed 下也相同，但两者来源不同，改 seed 后行为会分叉） |
| 7 | `service/rbac_service.zig:124-150`、`180-209` | 内置角色（`is_builtin=true`）的 `name`/`description` 可改，`super_admin` 的权限点也可被全量覆盖（只有 `DELETE` 有内置保护） | 可以把 `super_admin` 的 `*` 抹掉把自己锁死 |
| 8 | `handler/audit_handler.zig:54-58` | `purge` 取了 `actor` 却 `_ = actor;` 丢弃，审计日志记为 `0 / "system"` | 清理操作无法追溯操作人（`exportCsv` 则正确记录了 actor） |
| 9 | `service/user_service.zig:304-330` | `PUT /users/:id/roles` 无自我保护，可清空自己的角色 | 管理员能把自己变成无权限用户（对比 `changeStatus` 有 `CANNOT_DEMOTE_SELF`） |
| 10 | `handler/org_handler.zig:56-62` | `GET /orgs/:id/members` 对不存在的组织返回空页而非 404（`subtreeIds` 恒包含自身 id） | 前端无法区分"组织为空"与"组织不存在" |
| 11 | `service/rbac_service.zig:208` | `assignPermissions` 返回 `toRoleView(role)`，`role` 是**更新前**的行，且本接口不更新 `updated_at` | 响应的 `updated_at` 是旧值（权限点数组是新值），前端按 `updated_at` 判断新鲜度会出错 |
| 12 | `model/audit.zig:50-71` | `log.export` 与 `log.purge` 是硬编码字符串，不在 `actions` 常量表里 | 前端按常量表生成筛选下拉会漏这两个 action |
| 13 | `service/approval_service.zig:118-121` | 超管也不能审批自己发起的单（无 `isSuperAdmin` 例外） | 单人部署场景下审批流会卡死（只能 `cancel`）；可能是有意为之，请确认 |
| 14 | `handler/mod.zig:45-52` + `core/util.zig:12` | `page_size` 非法值静默取默认 20，`page=abc` 也静默取 1 | 前端拼写错误不会被发现，表现为"一直是第一页" |
| 15 | `core/util.zig:18` `queryStr` | 用 `ctx.query()` 取**未解码**的原始值；`GET /users?keyword=爱丽丝` 实际拿到 `%E7%88%B1%E4%B8%BD%E4%B8%9D` | 中文/空格关键字检索失效（用户、组织、日志、审批全都受影响）。框架有 `getQueryDecoded`（`util.zig:23` 的 `queryStrDecoded` 已有封装）却没用 |
| 16 | `app.zig:41` / `middleware/auth.zig:36` | `OptionalAuth` 中间件定义了但 `mount()` 里从未使用（死代码） | 无功能影响，但会误导后来者以为某些路由是"可选登录" |
| 17 | `service/user_service.zig:197-201` | `remove` 先判 `CANNOT_DELETE_SELF` 再查用户是否存在 | 删一个不存在但恰好等于自己 id 的用户（不可能场景）顺序异常；更重要的是：删**不存在**的用户返回 404，但删**自己**返回 409——前端要注意这个优先级差异 |
| 18 | `GET /ws` 无权限守卫 | 只需登录即可连入广播通道，能看到全部用户/组织/审批事件 | 无权限点隔离（任何登录用户都能收到所有业务事件），视需求可能是有意的 |
| 19 | 全局 | `POST /logs/purge`、`POST /users/:id/unlock` 不需要请求体，但客户端若带 `Content-Type: application/json` 且不发 body 也没问题；反之 `PUT /users/:id/roles` 允许空 body（`role_ids` 有默认值） | 请求体要求不统一，前端 `fetch` 封装要注意别对空 body 接口强塞 `{}`（无害） |

> 以上均未改动任何 `.zig` 代码，仅作为契约文档的备注，等待后端确认后再处理。





