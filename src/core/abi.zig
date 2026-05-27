//! Wire-format constants and types for the Solana loader's input buffer.
//!
//! The loader hands the program a single pointer to a serialized buffer. Its
//! layout (from `agave/sdk/program/src/entrypoint.rs` and the C SDK
//! `deserialize.h`) is:
//!
//!   [num_accounts: u64 LE]
//!   for each account:
//!     [dup_byte: u8]                         // 0xFF = unique, else = index of prior dup
//!     if unique:
//!       [is_signer: u8]
//!       [is_writable: u8]
//!       [executable: u8]
//!       [originally_data_len: u32 LE]        // padding/legacy field, treat as alignment
//!       [pubkey: 32 bytes]
//!       [owner: 32 bytes]
//!       [lamports: u64 LE]
//!       [data_len: u64 LE]
//!       [data: data_len bytes]
//!       [realloc_padding: MAX_PERMITTED_DATA_INCREASE bytes]
//!       [alignment padding to 8B]
//!       [rent_epoch: u64 LE]
//!     else:
//!       [7 padding bytes]
//!   [instruction_data_len: u64 LE]
//!   [instruction_data: ... bytes]
//!   [program_id: 32 bytes]
//!
//! NOTE: Solana's runtime aligns the **whole input buffer** to 8 bytes, so we
//! can take `*u64` references into it safely as long as our parser doesn't
//! introduce odd offsets. The `account header up to lamports` is laid out so
//! that `lamports` lands on an 8-byte boundary.

/// The runtime over-allocates this many bytes after each account's data so
/// programs can realloc up to this amount without copying.
pub const MAX_PERMITTED_DATA_INCREASE: usize = 10 * 1024;

/// The duplicate-account sentinel: 0xFF means "this account is new", any other
/// value is the index into the already-seen accounts list (account dedup).
pub const NON_DUP_MARKER: u8 = 0xff;

/// Maximum number of accounts in one instruction (per current consensus).
/// We can keep the parser stack-allocated up to this bound.
pub const MAX_TX_ACCOUNTS: usize = 128;
