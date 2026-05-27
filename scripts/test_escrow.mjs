#!/usr/bin/env node
// Drives the escrow program through three flows:
//
//   1. Maker initializes escrow #1 (locks 0.1 SOL, asks 0.05 SOL)
//   2. Taker takes escrow #1 (pays 0.05, receives 0.1 + rent rebate)
//   3. Maker initializes escrow #2 and cancels it
//
// Verifies balances and prints CU consumed per step.
//
// Usage:  node scripts/test_escrow.mjs <PROGRAM_ID>

import {
  Connection, Keypair, PublicKey, SystemProgram, Transaction,
  TransactionInstruction, sendAndConfirmTransaction, LAMPORTS_PER_SOL,
} from "@solana/web3.js";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const programId = new PublicKey(process.argv[2]);
const conn = new Connection("http://127.0.0.1:8899", "confirmed");
const maker = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(
  readFileSync(`${homedir()}/.config/solana/id.json`, "utf8"))));
const taker = Keypair.generate();

const STATE_SIZE = 64;

function u64LE(n) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(n), 0);
  return b;
}

function escrowPda(id) {
  const idBuf = u64LE(id);
  return PublicKey.findProgramAddressSync(
    [Buffer.from("escrow"), maker.publicKey.toBuffer(), idBuf],
    programId,
  );
}

async function send(label, signers, keys, data) {
  const ix = new TransactionInstruction({ programId, keys, data });
  const tx = new Transaction().add(ix);
  const sig = await sendAndConfirmTransaction(conn, tx, signers, { commitment: "confirmed" });
  const meta = await conn.getTransaction(sig, {
    commitment: "confirmed",
    maxSupportedTransactionVersion: 0,
  });
  const cuLine = meta.meta.logMessages.find(l => /consumed (\d+)/.test(l));
  const cu = cuLine ? cuLine.match(/consumed (\d+)/)[1] : "?";
  console.log(`${label.padEnd(24)} CU=${cu.padStart(5)}  sig=${sig.slice(0, 8)}…  ${meta.meta.err ? "FAILED" : "ok"}`);
  if (meta.meta.err) console.log("logs:", meta.meta.logMessages);
  return meta;
}

async function bal(pk) {
  const info = await conn.getAccountInfo(pk, "confirmed");
  return info ? info.lamports : 0;
}

console.log(`program: ${programId.toBase58()}`);
console.log(`maker:   ${maker.publicKey.toBase58()}`);
console.log(`taker:   ${taker.publicKey.toBase58()}\n`);

// Fund taker so they can pay tx fees + the asking price.
{
  const tx = new Transaction().add(SystemProgram.transfer({
    fromPubkey: maker.publicKey,
    toPubkey: taker.publicKey,
    lamports: LAMPORTS_PER_SOL,
  }));
  await sendAndConfirmTransaction(conn, tx, [maker], { commitment: "confirmed" });
}

const rent = await conn.getMinimumBalanceForRentExemption(STATE_SIZE);
const amount = Math.floor(0.10 * LAMPORTS_PER_SOL);
const price  = Math.floor(0.05 * LAMPORTS_PER_SOL);

// ===== Flow 1: initialize escrow #1 ==================================
const [escrow1] = escrowPda(1);
console.log(`escrow#1 PDA: ${escrow1.toBase58()}`);
const initData = Buffer.concat([
  Buffer.from([0]),         // tag = initialize
  u64LE(amount),
  u64LE(price),
  u64LE(1),                 // id
  u64LE(rent),
]);

const makerBefore = await bal(maker.publicKey);
await send("initialize #1", [maker], [
  { pubkey: maker.publicKey,         isSigner: true,  isWritable: true },
  { pubkey: escrow1,                 isSigner: false, isWritable: true },
  { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
], initData);
console.log(`  escrow lamports: ${await bal(escrow1)}  (rent ${rent} + amount ${amount})`);
console.log(`  maker delta:     ${(await bal(maker.publicKey)) - makerBefore}\n`);

// ===== Flow 2: taker takes escrow #1 =================================
const takerBefore = await bal(taker.publicKey);
const makerBefore2 = await bal(maker.publicKey);
await send("take #1", [taker], [
  { pubkey: taker.publicKey,         isSigner: true,  isWritable: true },
  { pubkey: maker.publicKey,         isSigner: false, isWritable: true },
  { pubkey: escrow1,                 isSigner: false, isWritable: true },
  { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
], Buffer.from([1]));

const escrowAfter = await conn.getAccountInfo(escrow1, "confirmed");
console.log(`  escrow exists?    ${escrowAfter !== null}`);
console.log(`  taker delta:      ${(await bal(taker.publicKey)) - takerBefore}  (expected ≈ +${amount + rent - price} minus tx fee)`);
console.log(`  maker delta:      ${(await bal(maker.publicKey)) - makerBefore2}  (expected +${price})\n`);

// ===== Flow 3: initialize escrow #2 and cancel =======================
const [escrow2] = escrowPda(2);
const initData2 = Buffer.concat([
  Buffer.from([0]),
  u64LE(amount),
  u64LE(price),
  u64LE(2),
  u64LE(rent),
]);
console.log(`escrow#2 PDA: ${escrow2.toBase58()}`);
await send("initialize #2", [maker], [
  { pubkey: maker.publicKey,         isSigner: true,  isWritable: true },
  { pubkey: escrow2,                 isSigner: false, isWritable: true },
  { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
], initData2);

const makerBefore3 = await bal(maker.publicKey);
await send("cancel #2", [maker], [
  { pubkey: maker.publicKey, isSigner: true,  isWritable: true },
  { pubkey: escrow2,         isSigner: false, isWritable: true },
], Buffer.from([2]));

const escrow2After = await conn.getAccountInfo(escrow2, "confirmed");
console.log(`  escrow exists?  ${escrow2After !== null}`);
console.log(`  maker delta:    ${(await bal(maker.publicKey)) - makerBefore3}  (expected ≈ +${amount + rent} minus tx fee)`);
