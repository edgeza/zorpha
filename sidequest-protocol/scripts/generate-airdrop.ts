#!/usr/bin/env node
/**
 * Season 1 airdrop Merkle generator.
 *
 * Reads a snapshot CSV, builds the OpenZeppelin standard Merkle tree, and writes
 * one proof file per recipient plus a root manifest.
 *
 *   npx tsx sidequest-protocol/scripts/generate-airdrop.ts \
 *     --snapshot ./snapshot.csv \
 *     --out ../../zorpha-web/data/airdrop
 *
 * Snapshot CSV: `address,amount` where amount is a WHOLE number of ZOR.
 * Comments (#) and blank lines are ignored, and a header row is detected.
 *
 * Leaf encoding matches `MerkleDistributor.claim` exactly:
 *
 *     keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))
 *
 * The double hash is the OpenZeppelin standard-tree convention and is what
 * makes second-preimage attacks against internal nodes infeasible. Sibling
 * pairs are sorted before hashing, matching `MerkleProof.verify`.
 *
 * The generated proofs are PUBLIC data — a proof only ever lets the committed
 * recipient claim the committed amount — so serving them from a static
 * directory is safe.
 */

import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { keccak256, encodeAbiParameters, parseAbiParameters, getAddress } from 'viem';

// ─── CLI ────────────────────────────────────────────────────────────────────

function arg(name: string, fallback?: string): string {
  const i = process.argv.indexOf(`--${name}`);
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  if (fallback !== undefined) return fallback;
  throw new Error(`missing required --${name}`);
}

const SNAPSHOT = arg('snapshot');
const OUT_DIR = arg('out', path.join(__dirname, '..', '..', 'zorpha-web', 'data', 'airdrop'));
const DECIMALS = 18n;

// ─── Snapshot parsing ───────────────────────────────────────────────────────

type Entry = { index: number; address: `0x${string}`; amount: bigint };

async function readSnapshot(file: string): Promise<Entry[]> {
  const raw = await fs.readFile(file, 'utf-8');
  const seen = new Map<string, number>();
  const entries: Entry[] = [];

  const lines = raw.split(/\r?\n/);
  for (let lineNo = 0; lineNo < lines.length; lineNo++) {
    const line = lines[lineNo].trim();
    if (!line || line.startsWith('#')) continue;

    const [rawAddr, rawAmount] = line.split(',').map((c) => c?.trim());
    if (!rawAddr || !rawAmount) {
      throw new Error(`line ${lineNo + 1}: expected "address,amount", got "${line}"`);
    }
    // Skip a header row.
    if (!/^0x[0-9a-fA-F]{40}$/.test(rawAddr)) {
      if (lineNo === 0 || rawAddr.toLowerCase() === 'address') continue;
      throw new Error(`line ${lineNo + 1}: "${rawAddr}" is not an address`);
    }
    if (!/^\d+(\.\d+)?$/.test(rawAmount)) {
      throw new Error(`line ${lineNo + 1}: "${rawAmount}" is not a number`);
    }

    // Checksum the address so the leaf encoding is canonical, but dedupe on the
    // lowercase form — the same wallet in two cases is still the same wallet,
    // and a duplicate would silently create two claimable entries.
    const address = getAddress(rawAddr);
    const key = address.toLowerCase();
    const prior = seen.get(key);
    if (prior !== undefined) {
      throw new Error(
        `line ${lineNo + 1}: ${address} already appears at line ${prior}. ` +
          'Merge duplicate rows before generating — two entries for one wallet ' +
          'means two claims.',
      );
    }
    seen.set(key, lineNo + 1);

    const [whole, frac = ''] = rawAmount.split('.');
    if (frac.length > Number(DECIMALS)) {
      throw new Error(`line ${lineNo + 1}: more than ${DECIMALS} decimal places`);
    }
    const amount =
      BigInt(whole) * 10n ** DECIMALS + BigInt(frac.padEnd(Number(DECIMALS), '0') || '0');

    if (amount === 0n) {
      throw new Error(`line ${lineNo + 1}: zero allocation for ${address}`);
    }

    entries.push({ index: entries.length, address, amount });
  }

  if (entries.length === 0) throw new Error('snapshot contained no entries');
  return entries;
}

// ─── Merkle tree ────────────────────────────────────────────────────────────

function leafOf(e: Entry): `0x${string}` {
  const encoded = encodeAbiParameters(parseAbiParameters('uint256, address, uint256'), [
    BigInt(e.index),
    e.address,
    e.amount,
  ]);
  // Double hash, matching the contract.
  return keccak256(keccak256(encoded));
}

function hashPair(a: `0x${string}`, b: `0x${string}`): `0x${string}` {
  // MerkleProof.verify sorts each pair, so the builder must too.
  const [lo, hi] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
  return keccak256(`0x${lo.slice(2)}${hi.slice(2)}`);
}

/** Returns every level, leaves first, root last. */
function buildLevels(leaves: `0x${string}`[]): `0x${string}`[][] {
  const levels: `0x${string}`[][] = [leaves];
  let current = leaves;

  while (current.length > 1) {
    const next: `0x${string}`[] = [];
    for (let i = 0; i < current.length; i += 2) {
      // An odd node is promoted unchanged rather than duplicated. Duplicating
      // it is the classic source of forgeable proofs in hand-rolled trees.
      next.push(i + 1 < current.length ? hashPair(current[i], current[i + 1]) : current[i]);
    }
    levels.push(next);
    current = next;
  }
  return levels;
}

function proofFor(levels: `0x${string}`[][], index: number): `0x${string}`[] {
  const proof: `0x${string}`[] = [];
  let idx = index;

  for (let level = 0; level < levels.length - 1; level++) {
    const nodes = levels[level];
    const pairIdx = idx % 2 === 0 ? idx + 1 : idx - 1;
    if (pairIdx < nodes.length) proof.push(nodes[pairIdx]);
    idx = Math.floor(idx / 2);
  }
  return proof;
}

/** Independent re-verification, mirroring MerkleProof.verify. */
function verify(leaf: `0x${string}`, proof: `0x${string}`[], root: `0x${string}`): boolean {
  let computed = leaf;
  for (const sibling of proof) computed = hashPair(computed, sibling);
  return computed.toLowerCase() === root.toLowerCase();
}

// ─── Main ───────────────────────────────────────────────────────────────────

async function main() {
  const entries = await readSnapshot(SNAPSHOT);
  const leaves = entries.map(leafOf);
  const levels = buildLevels(leaves);
  const root = levels[levels.length - 1][0];

  const total = entries.reduce((sum, e) => sum + e.amount, 0n);

  await fs.mkdir(OUT_DIR, { recursive: true });

  // Every proof is verified against the root before it is written. A generator
  // that emits an unverifiable proof produces a claim page that fails for a
  // real recipient with no explanation, which is the worst kind of launch bug.
  let written = 0;
  const combined: Record<string, { index: number; amount: string; proof: string[] }> = {};

  for (const e of entries) {
    const proof = proofFor(levels, e.index);
    const leaf = leafOf(e);
    if (!verify(leaf, proof, root)) {
      throw new Error(`generated proof for ${e.address} (index ${e.index}) does not verify`);
    }

    const key = e.address.slice(2).toLowerCase();
    const record = { index: e.index, amount: e.amount.toString(), proof };

    await fs.writeFile(
      path.join(OUT_DIR, `${key}.json`),
      `${JSON.stringify(record, null, 2)}\n`,
      'utf-8',
    );
    combined[key] = record;
    written++;
  }

  // One combined file, as well as the per-recipient ones.
  //
  // The per-recipient files are gitignored, on the reasoning that thousands of
  // tiny files are not worth committing. That reasoning is sound, but the claim
  // API reads proofs off disk at runtime -- so on a deployment that has only
  // what git tracked, every claim would 404 with "not eligible" and nothing
  // anywhere would explain why.
  //
  // This file is what git tracks instead. One artefact rather than thousands,
  // and a Merkle proof is logarithmic in the recipient count, so even a large
  // snapshot stays a few megabytes.
  await fs.writeFile(
    path.join(OUT_DIR, 'proofs.json'),
    `${JSON.stringify(combined, null, 2)}\n`,
    'utf-8',
  );

  const manifest = {
    generatedFrom: path.basename(SNAPSHOT),
    snapshotSha256: createHash('sha256')
      .update(await fs.readFile(SNAPSHOT))
      .digest('hex'),
    merkleRoot: root,
    recipients: entries.length,
    totalAllocationWei: total.toString(),
    totalAllocationZor: (total / 10n ** DECIMALS).toString(),
  };
  await fs.writeFile(
    path.join(OUT_DIR, 'manifest.json'),
    `${JSON.stringify(manifest, null, 2)}\n`,
    'utf-8',
  );

  console.log('=== Zorpha Season 1 airdrop ===');
  console.log(`recipients        ${manifest.recipients}`);
  console.log(`total allocation  ${manifest.totalAllocationZor} ZOR`);
  console.log(`snapshot sha256   ${manifest.snapshotSha256}`);
  console.log(`proofs written    ${written} -> ${OUT_DIR}`);
  console.log(`combined          proofs.json (the one git tracks)`);
  console.log('');
  console.log(`AIRDROP_MERKLE_ROOT=${root}`);
  console.log('');
  console.log('Publish the snapshot file and its sha256 BEFORE opening claims, so');
  console.log('anyone can rebuild this root and confirm the allocation was not');
  console.log('changed after the fact.');
}

main().catch((err) => {
  console.error(`\nairdrop generation failed: ${err.message}`);
  process.exit(1);
});
