const builtin = @import("builtin");
const common = @import("./common.zig");
const intFromFloat = @import("./int_from_float.zig").intFromFloat;

pub const panic = common.panic;

comptime {
    if (common.want_windows_v2u64_abi) {
        @export(&__fixunssfti_windows_x86_64, .{ .name = "__fixunssfti", .linkage = common.linkage, .visibility = common.visibility });
    } else {
        @export(&__fixunssfti, .{ .name = "__fixunssfti", .linkage = common.linkage, .visibility = common.visibility });
    }
}

pub fn __fixunssfti(a: f32) callconv(.c) u128 {
    return intFromFloat(u128, a);
}

const v2u64 = @Vector(2, u64);

fn __fixunssfti_windows_x86_64(a: f32) callconv(.c) v2u64 {
    return @bitCast(intFromFloat(u128, a));
}
