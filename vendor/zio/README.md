# zio vendor 补丁说明

- 基线：`lalinsky/zio` main @ `b0efa2bdb4cda8c9ddc6d592c52aec873a10d3a4`（0.20.1，2026-11-15）。
- 原因：本机 zig 0.18.0-dev.1124 引入两处语言变更，上游尚未跟进，直接 url/hash
  依赖会报 13 个编译错误。
- 上游跟进后请删掉本目录，把 `build.zig.zon` 的 `.zio` 换回 url/hash 依赖。

## 补丁清单（均为语义等价的最小改动）

1. `packed struct(uN)` → `bitpack struct(uN)`（`packed union` → `bitpack union`）。
   zig 0.18.0-dev.1124 更名了 packed 容器关键字。涉及文件：
   `src/task.zig`、`src/ev/completion.zig`、`src/autocancel.zig`、
   `src/os/{darwin,net,posix,thread,windows}.zig`、`src/os/system/linux.zig`。

2. 新优先级规则要求显式括号（行为保持 0.17 的求值顺序不变）：
   - `src/completion_queue.zig`：`round % 7 * 100` → `(round % 7) * 100`
   - `src/ev/backends/iocp.zig`：`OffsetHigh) << 32 |` → `OffsetHigh) << 32) |`
   - `src/net.zig`：`ip4[0]) << 8 |` → `ip4[0]) << 8) |`
   - `src/os/net.zig`：`WSAStartup(2 << 8 | 2,` → `WSAStartup((2 << 8) | 2,`
   - `src/os/time.zig`：`dwHighDateTime) << 32 |` → `dwHighDateTime) << 32) |`
     （kernel/user 两处）
