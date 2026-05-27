//! Minimal mycelium program. Logs once, returns success.
//!
//! Build:   zig build hello
//! Output:  zig-out/lib/hello.so
//! Deploy:  solana program deploy zig-out/lib/hello.so

const mycelium = @import("mycelium");
const syscalls = mycelium.core.syscalls;

fn process(_: *const mycelium.core.entrypoint.ExecutionContext) mycelium.ProgramResult {
    const msg = "Hello from mycelium!";
    syscalls.sol_log_(msg.ptr, msg.len);
    return;
}

comptime {
    mycelium.core.entrypoint.declareEntrypoint(process);
}
