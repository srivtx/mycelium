#!/usr/bin/env node
// Vault v2 exerciser — same lifecycle as test_vault.mjs but the initialize
// instruction now carries the bump in its payload.
//
// Usage: node scripts/test_vault_v2.mjs <PROGRAM_ID>

import {
  Connection, Keypair, PublicKey, SystemProgram, Transaction,
  TransactionInstruction, sendAndConfirmTransaction, LAMPORTS_PER_SOL,
} from "@solana/web3.js";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const programId = new PublicKey(process.argv[2]);
const conn = new Connection("http://127.0.0.1:8899", "confirmed");
const payer = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(
  readFileSync(`${homedir()}/.config/solana/id.json`, "utf8"))));

// State size unchanged: 32 + 1 + 1 + 6 = 40 bytes.
const STATE_SIZE = 40;

const [vaultPda, bump] = PublicKey.findProgramAddressSync(
  [Buffer.from("vault"), payer.publicKey.toBuffer()],
  programId,
);
console.log(`program:   ${programId.toBase58()}`);
console.log(`payer:     ${payer.publicKey.toBase58()}`);
console.log(`vault PDA: ${vaultPda.toBase58()} (bump=${bump})`);

function u64LE(n) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(n), 0);
  return b;
}

async function sendIx(label, keys, data) {
  const ix = new TransactionInstruction({ programId, keys, data });
  const tx = new Transaction().add(ix);
  const sig = await sendAndConfirmTransaction(conn, tx, [payer], { commitment: "confirmed" });
  const meta = await conn.getTransaction(sig, {
    commitment: "confirmed",
    maxSupportedTransactionVersion: 0,
  });
  const cuLine = meta.meta.logMessages.find(l => /consumed (\d+)/.test(l));
  const cu = cuLine ? cuLine.match(/consumed (\d+)/)[1] : "?";
  const failed = meta.meta.err !== null;
  console.log(`${label.padEnd(20)} CU=${cu.padStart(5)}  sig=${sig.slice(0, 8)}…  ${failed ? "FAILED" : "ok"}`);
  if (failed) console.log("logs:", meta.meta.logMessages);
  return meta;
}

async function vaultBalance() {
  const info = await conn.getAccountInfo(vaultPda, "confirmed");
  return info ? info.lamports : 0;
}

const rentLamports = await conn.getMinimumBalanceForRentExemption(STATE_SIZE);

// initialize: tag=0 + u64 rent + u8 bump + 7 bytes pad (matches extern struct layout).
const initData = Buffer.concat([
  Buffer.from([0]),
  u64LE(rentLamports),
  Buffer.from([bump]),
  Buffer.alloc(7),
]);
await sendIx("initialize", [
  { pubkey: payer.publicKey,         isSigner: true,  isWritable: true },
  { pubkey: vaultPda,                isSigner: false, isWritable: true },
  { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
], initData);
console.log(`  vault lamports: ${await vaultBalance()}\n`);

const depositAmount = Math.floor(0.1 * LAMPORTS_PER_SOL);
await sendIx("deposit(0.1)", [
  { pubkey: payer.publicKey,         isSigner: true,  isWritable: true },
  { pubkey: vaultPda,                isSigner: false, isWritable: true },
  { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
], Buffer.concat([Buffer.from([1]), u64LE(depositAmount)]));
console.log(`  vault lamports: ${await vaultBalance()}\n`);

await sendIx("deposit(0.1)", [
  { pubkey: payer.publicKey,         isSigner: true,  isWritable: true },
  { pubkey: vaultPda,                isSigner: false, isWritable: true },
  { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
], Buffer.concat([Buffer.from([1]), u64LE(depositAmount)]));
console.log(`  vault lamports: ${await vaultBalance()}\n`);

const recipient = Keypair.generate();
const recipientRent = await conn.getMinimumBalanceForRentExemption(0);
{
  const tx = new Transaction().add(SystemProgram.transfer({
    fromPubkey: payer.publicKey,
    toPubkey: recipient.publicKey,
    lamports: recipientRent,
  }));
  await sendAndConfirmTransaction(conn, tx, [payer], { commitment: "confirmed" });
}

const withdrawAmount = Math.floor(0.05 * LAMPORTS_PER_SOL);
await sendIx("withdraw(0.05)", [
  { pubkey: payer.publicKey,        isSigner: true,  isWritable: false },
  { pubkey: vaultPda,               isSigner: false, isWritable: true },
  { pubkey: recipient.publicKey,    isSigner: false, isWritable: true },
], Buffer.concat([Buffer.from([2]), u64LE(withdrawAmount)]));
console.log(`  vault lamports:     ${await vaultBalance()}`);
const r = await conn.getAccountInfo(recipient.publicKey, "confirmed");
console.log(`  recipient lamports: ${r?.lamports ?? 0}`);
