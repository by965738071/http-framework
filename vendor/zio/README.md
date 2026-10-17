# vendor/zio —— zio 0.19.0 的移植补丁副本

上游：<https://github.com/lalinsky/zio>（main 分支，v0.19.0，2026-10-16）。

## 为什么要 vendor

上游 zio 0.19.0 只适配到 zig 0.17 的 `std.Io`。本机/CI 使用的 zig
`0.18.0-dev.253+16d31ceed` 中，`std.Io` 对 accept 做了两处 **break change**：

1. `Io.VTable` 删除了 `netAccept` 条目：accept 改经
   `operate(Operation.net_accept)` 通用路径分发
   （`std.Server.accept` 现在就是这么调的）。
2. `Io.Operation` 联合新增 `net_accept` 成员（位于 `net_send` 与
   `net_read` 之间；tagged union 字段顺序必须与 enum 一致）。
   其 `Result` 错误集没有 `WouldBlock`。

上游没有跟进（无 zig-0.18 分支），`build.zig.zon` 引用 git URL 无法打
patch，因此 vendor 一份最小副本，改动全部标注 `[vendor-patch]`。

## 全部改动（仅 `src/io.zig`，其余与上游 0.19.0 逐字节一致）

| 位置 | 改动 |
| --- | --- |
| `VTable` 初始化 | 删除 `.netAccept = netAcceptImpl` 条目 |
| `operateInner` | 新增 `.net_accept` 分支：复用 `netAcceptImpl` 同步实现；`Canceled` 作为操作级错误上抛，其余错误嵌入 `Operation.Result` |
| `BatchCompletionData` | 新增 `net_accept` payload（`op/addr_storage/addr_len`），字段顺序对齐 enum |
| `getCompletion` / `initBatchOperation` / `extractBatchResult` | 补 `.net_accept` 分支；`WouldBlock/FileDescriptorNotASocket/OperationNotSupported` 归入 `Unexpected`；`ConnectionAborted` 作为合法结果由调用方重试 |
| `netAcceptImpl` | `WouldBlock` 改为循环重试（新 `AcceptError` 不含此错误） |

## 升级/同步

- 上游出现适配 0.18 的版本后：删掉本目录，把 `build.zig.zon` 的
  `.zio` 依赖换回 `git+https://github.com/lalinsky/zio#<ref>` + hash。
- 同步上游新快照时：重新解包覆盖，再按上表重放补丁
  （`grep -rn "\[vendor-patch\]" vendor/zio/src` 可定位全部改动点）。
- 换 zig 快照后务必先跑 `zig build -p /tmp/httpfw-probe install`：zio 与
  `std.Io.VTable` 是隐式契约，错误可能延迟到真正实例化时才暴露。
</content>
</invoke>
