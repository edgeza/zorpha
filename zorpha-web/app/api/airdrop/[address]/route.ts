import { NextRequest, NextResponse } from 'next/server';
import { promises as fs } from 'node:fs';
import path from 'node:path';

/**
 * GET /api/airdrop/[address]
 *
 * Returns `{ index, amount, proof }` for the recipient, or 404 if not eligible.
 *
 * In V1 the Merkle proof JSON is hosted as a static file at
 * `sidequest-app/data/airdrop/<lowercase-address>.json` (committed to the repo
 * after the V1 snapshot is taken). The directory structure:
 *
 *   data/airdrop/
 *     <lowercase-address-without-0x>.json   <- {"index": 7, "amount": "1000000000000000000", "proof": [...]}
 *     ...
 *
 * Generating the file: see `sidequest-protocol/scripts/generate-airdrop.ts`.
 */
export async function GET(
  _req: NextRequest,
  context: { params: Promise<{ address: string }> }
) {
  const { address } = await context.params;
  const cleaned = address.toLowerCase().replace(/^0x/, '');
  if (!/^[0-9a-f]{40}$/.test(cleaned)) {
    return new NextResponse('invalid address', { status: 400 });
  }

  const filePath = path.join(process.cwd(), 'data', 'airdrop', `${cleaned}.json`);
  try {
    const buf = await fs.readFile(filePath, 'utf-8');
    return new NextResponse(buf, {
      status: 200,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    });
  } catch {
    return new NextResponse('not eligible', { status: 404 });
  }
}