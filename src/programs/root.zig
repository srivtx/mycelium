//! Typed wrappers for the on-chain "system" programs we frequently CPI to.
//!
//! Each submodule exposes builder functions that produce a `cpi.Instruction`
//! from Zig-native parameters and a caller-owned data/accounts buffer pair.
//! Invoke them via `cpi.invoke` / `cpi.invokeSigned`.

const std = @import("std");

pub const system = @import("system.zig");

test {
    std.testing.refAllDecls(@This());
}
