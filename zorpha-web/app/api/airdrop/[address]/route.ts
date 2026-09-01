import { NextRequest, NextResponse } from 'next/server';
import { promises as fs } from 'node:fs';
import path from 'node:path';

/**
 * GET /api/airdrop/[address]
 *
 * Returns `{ index, amount, proof }` for the recipient, or 404 if not eligible.
 *
 * Proofs come from `data/airdrop/proofs.json`, a single file keyed by lowercase
 * address without the `0x`, produced by
 * `sidequest-protocol/scripts/generate-airdrop.ts`.
 *
 * It reads the combined file rather than the per-recipient ones on purpose.
 * Those are gitignored — thousands of tiny files are not worth committing —
 * which means a deployment only ever has what git tracked. Reading them at
 * runtime would 404 every single claim in production with "not eligible" and
 * nothing anywhere to explain it, while working perfectly in local dev where
 * the generator's output is still sitting on disk.
 *
 * The per-recipient files are still a fallback, purely so a local run that has
 * generated them but not yet regenerated the combined file keeps working.
 */

/**
 * Cached across requests. The file is immutable for a given snapshot, and a
 * large airdrop is a few megabytes that should not be re-read and re-parsed on
 * every claim.
 */
let proofsCache: Record<string, unknown> | null = null;

async function loadProofs(): Promise<Record<string, unknown> | null> {
  if (proofsCache) return proofsCache;
  try {
    const file = path.join(process.cwd(), 'data', 'airdrop', 'proofs.json');
    proofsCache = JSON.parse(await fs.readFile(file, 'utf-8'));
    return proofsCache;
  } catch {
    return null;
  }
}

export async function GET(
  _req: NextRequest,
  context: { params: Promise<{ address: string }> }
) {
  const { address } = await context.params;
  const cleaned = address.toLowerCase().replace(/^0x/, '');
  if (!/^[0-9a-f]{40}$/.test(cleaned)) {
    return new NextResponse('invalid address', { status: 400 });
  }

  const proofs = await loadProofs();
  const hit = proofs?.[cleaned];
  if (hit) {
    return new NextResponse(JSON.stringify(hit), {
      status: 200,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    });
  }

  // Local-only fallback: the generator wrote per-recipient files but the
  // combined one is missing or stale.
  try {
    const filePath = path.join(process.cwd(), 'data', 'airdrop', `${cleaned}.json`);
    const buf = await fs.readFile(filePath, 'utf-8');
    return new NextResponse(buf, {
      status: 200,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    });
  } catch {
    return new NextResponse('not eligible', { status: 404 });
  }
}
