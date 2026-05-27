#!/usr/bin/env node
// Minimal client that invokes the deployed `hello` program once and prints
// the compute units consumed plus the program log lines.
//
// Usage:  node scripts/invoke_hello.mjs <PROGRAM_ID>
//
// Requires:  npm i -g @solana/web3.js  (or run from a dir with it installed)

import {
  Connection, Keypair, PublicKey, Transaction, TransactionInstruction,
  sendAndConfirmTransaction,
} from "@solana/web3.js";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const programId = new PublicKey(process.argv[2]);
const conn = new Connection("http://127.0.0.1:8899", "confirmed");

const secret = JSON.parse(readFileSync(`${homedir()}/.config/solana/id.json`, "utf8"));
const payer = Keypair.fromSecretKey(Uint8Array.from(secret));

const ix = new TransactionInstruction({
  programId,
  keys: [],
  data: Buffer.alloc(0),
});

const tx = new Transaction().add(ix);
const sig = await sendAndConfirmTransaction(conn, tx, [payer], { commitment: "confirmed" });
console.log("signature:", sig);

const meta = await conn.getTransaction(sig, { commitment: "confirmed", maxSupportedTransactionVersion: 0 });
console.log("compute units consumed:", meta?.meta?.computeUnitsConsumed);
console.log("logs:");
for (const line of meta?.meta?.logMessages ?? []) console.log("  " + line);
