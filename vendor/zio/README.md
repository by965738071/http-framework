# zio vendor 补丁说明

- 基线：`lalinsky/zio` main @ `b0efa2bdb4cda8c9ddc6d592c52aec873a10d3a4`（0.20.1，2026-11-15）。
- 原因：本机 zig 0.18.0-dev.1124 引入语言变更（packed 关键字、运算符优先级），
  dev.1240 又改了 std.Io 布局/类型，上游尚未跟进，直接 url/hash 依赖会编译失败。
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

3. zig 0.18.0-dev.1240 的 std.Io 布局/类型变更（`src/io.zig`、`src/os/fs.zig`、
   `src/os/base.zig`、`src/fs.zig`、`src/net.zig`）：
   - `Io.Operation.Result` 增大到 56 字节，不再放得进
     `Operation.Storage.Pending.Userdata`（[7]usize，扣掉指针槽只剩 48 字节）：
     并发批处理的结果改存进池项 `BatchItem = struct { data, result }`，
     `pending.userdata[0]` 只存池项指针 + 标志位；comptime 断言同步改写。
     同步序不变：回调线程写 `item.result` 后以 release 置 ready 标志，
     await 线程以 acquire 读标志后取 result，再归还池项。
   - `std.posix` 在 Windows 上直接 `@compileError`：`zioIpToStdIo`/`sockAddrLen`
     的地址族判断改用 zio 自己的跨平台 `os_net.AF`（与旧 dev738 补丁同改法）。
   - `Io.File.Uid/Gid` 在 Windows 上变成 `void`：新增 `uidToZio/gidToZio`
     转换（Windows 恒 null，POSIX 直通 u32），用于 DirSetOwner / DirSetFileOwner /
     FileSetOwner 三处调用点。
   - Windows 下 `std.Io.File.INode` 是 `LARGE_INTEGER`（i64），而 `c.ino_t`
     是 16 位 `c_ushort`，装不下 64 位 NTFS FileIndex：`src/os/fs.zig` 的
     `ino_t` 在 Windows 改用 `std.os.windows.LARGE_INTEGER` 与 std 对齐，
     目录项 u32→i64 隐式加宽、fstat u64→i64 `@bitCast`，无精度损失。
   - Linux 的 posix 层是 `std.os.linux`（纯 Zig），readv/writev/preadv/pwritev/
     recvmsg/msghdr/io_uring SQE 一律要 `std.os.linux.iovec` 类型：
     `src/os/base.zig` 的 `iovec`/`iovec_const` 别名加 `.linux` 分支（其余平台
     保持 `std.c.iovec` 不变）。`std.c.iovec` 与 `std.os.linux.iovec` 在 1240
     布局与字段名（base/len）完全相同，仅类型身份不同，指针不能互转。
   - `std.Io.Reader.writableVectorPosix` 签名固定为 `[]std.posix.iovec`：
     `src/fs.zig`（FileReader.readVec）与 `src/net.zig`（Reader.readVecImpl）
     的 iovec 存储保持 zio 类型（下游 `ev.ReadBuf` 需要），调用前用
     `@ptrCast(&storage[0])` 按位重解释成 `[*]std.posix.iovec` 再切片传入
     （布局相同，仅类型身份不同；Windows 分支走 writableVectorWsa 不受影响）。
