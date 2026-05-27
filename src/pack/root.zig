const std = @import("std");

pub const zerocopy = @import("zerocopy.zig");

test {
    std.testing.refAllDecls(@This());
}
