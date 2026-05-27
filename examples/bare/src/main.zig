//! Bare entrypoint — no parseInput, no accounts_buf, just log + return.
//! Used to isolate compute-unit cost of our framework's input parser.

const mycelium = @import("mycelium");
const syscalls = mycelium.core.syscalls;

export fn entrypoint(_: [*]u8) callconv(.c) u64 {
    const msg = "Hello from bare!";
    syscalls.sol_log_(msg.ptr, msg.len);
    return 0;
}
