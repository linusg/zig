const std = @import("std");
const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .keep_sigpipe = build_options.keep_sigpipe,
};

pub fn main() !void {
    const pipe = try std.posix.pipe();
    std.posix.close(pipe[0]);
    _ = std.posix.write(pipe[1], "a") catch |err| switch (err) {
        error.BrokenPipe => {
            try std.fs.File.stdout().writeAll("BrokenPipe\n");
            std.posix.exit(123);
        },
        else => |e| return e,
    };
    unreachable;
}
