#!/usr/bin/env node
// Exercises the counter program: initialize -> increment x2 -> add_amount(100) -> reset.
// Prints CU consumed for each instruction and the final state.
//
// Usage:  node scripts/test_counter.mjs <PROGRAM_ID>

import {
  Connection, Keypair, PublicKey, SystemProgram, Transaction,
  TransactionInstruction, sendAndConfirmTransaction,
} from "@solana/web3.js";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const programId = new PublicKey(process.argv[2]);
const conn = new Connection("http://127.0.0.1:8899", "confirmed");
const payer = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(
  readFileSync(`${homedir()}/.config/solana/id.json`, "utf8"))));

// State layout: 32 (authority) + 8 (value) + 1 (init) + 7 (pad) = 48
const STATE_SIZE = 48;
const counter = Keypair.generate();

async function send(tag, payload, label) {
  const data = payload
    ? Buffer.concat([Buffer.from([tag]), payload])
    : Buffer.from([tag]);

  const ix = new TransactionInstruction({
    programId,
    keys: [
      { pubkey: counter.publicKey, isSigner: tag === 0, isWritable: true },
      { pubkey: payer.publicKey,   isSigner: true,      isWritable: false },
    ],
    data,
  });

  const tx = new Transaction();
  if (tag === 0) {
    // Initialize: create the counter account first.
    const rent = await conn.getMinimumBalanceForRentExemption(STATE_SIZE);
    tx.add(SystemProgram.createAccount({
      fromPubkey: payer.publicKey,
      newAccountPubkey: counter.publicKey,
      lamports: rent,
      space: STATE_SIZE,
      programId,
    }));
  }
  tx.add(ix);

  const signers = tag === 0 ? [payer, counter] : [payer];
  const sig = await sendAndConfirmTransaction(conn, tx, signers, { commitment: "confirmed" });
  const meta = await conn.getTransaction(sig, { commitment: "confirmed", maxSupportedTransactionVersion: 0 });
  const programLog = meta.meta.logMessages.find(l => /consumed (\d+)/.test(l));
  const cu = programLog ? programLog.match(/consumed (\d+)/)[1] : "?";
  console.log(`${label.padEnd(20)} CU=${cu.padStart(5)}  sig=${sig.slice(0, 8)}…`);
  return meta;
}

async function readState() {
  const info = await conn.getAccountInfo(counter.publicKey, "confirmed");
  if (!info) return null;
  const value = info.data.readBigUInt64LE(32);
  const initialized = info.data[40];
  return { value: Number(value), initialized: !!initialized };
}

console.log(`program: ${programId.toBase58()}`);
console.log(`counter: ${counter.publicKey.toBase58()}`);

await send(0, null, "initialize");
console.log(`  state: ${JSON.stringify(await readState())}`);

await send(1, null, "increment");
console.log(`  state: ${JSON.stringify(await readState())}`);

await send(1, null, "increment");
console.log(`  state: ${JSON.stringify(await readState())}`);

const amount = Buffer.alloc(8);
amount.writeBigUInt64LE(100n, 0);
await send(2, amount, "add_amount(100)");
console.log(`  state: ${JSON.stringify(await readState())}`);

await send(3, null, "reset");
console.log(`  state: ${JSON.stringify(await readState())}`);
