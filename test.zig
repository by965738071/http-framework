const std = @import("std");

const ClosestPair = struct {
    a: i32,
    b: i32,
    sum: i64,
    diff: i64,
};

/// 在 nums 中找出两个数，使它们的和与 target 最接近。
/// 如果数组元素少于 2 个，返回 null。
fn closestTwoSum(nums: []const i32, target: i32) ?ClosestPair {
    if (nums.len < 2) return null;

    const t: i64 = target;
    var best: ClosestPair = undefined;
    var min_diff: i64 = std.math.maxInt(i64);
    var found = false;

    for (nums, 0..) |x, i| {
        // 只遍历 i 之后的元素，避免重复组合
        for (nums[i + 1 ..]) |y| {
            const sum: i64 = @as(i64, x) + @as(i64, y);
            const diff: i64 = if (sum >= t) sum - t else t - sum;

            if (!found or diff < min_diff) {
                min_diff = diff;
                best = .{ .a = x, .b = y, .sum = sum, .diff = diff };
                found = true;
            }
        }
    }

    return if (found) best else null;
}

pub fn main() void {
    const nums = [_]i32{ 1, 5, 3, 9, 7, 2 };
    const target: i32 = 8;

    if (closestTwoSum(&nums, target)) |res| {
        std.debug.print("最接近的一对: {} + {} = {}，与目标值 {} 的差值为 {}\n", .{
            res.a, res.b, res.sum, target, res.diff,
        });
    } else {
        std.debug.print("数组元素不足两个\n", .{});
    }
}