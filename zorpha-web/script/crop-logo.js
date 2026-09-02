// Crop a PNG to its alpha bounding box.
//
// sharp is not installed and this is a one-off asset step, so the PNG is
// decoded and re-encoded here directly: inflate IDAT, undo the per-scanline
// filters, find the bounding box of pixels that are not transparent, then write
// a fresh 8-bit RGBA PNG of just that region.
//
// Usage -- the working directory MATTERS, because node has to find this file
// before any of its own path handling can help:
//
//   from the repo root:
//     node zorpha-web/script/crop-logo.js
//     npm --prefix zorpha-web run logo:crop
//
//   from zorpha-web/:
//     node script/crop-logo.js
//     npm run logo:crop
//
// The ARGUMENTS resolve against the package root, so they never need adjusting
// and both default. That is a narrower guarantee than it first appears, and
// worth being precise about: making the arguments location-independent does
// nothing for the path to the script itself. `node script/crop-logo.js` from
// the repo root still fails with MODULE_NOT_FOUND, and `npm run logo:crop`
// there fails because the repo root has no package.json at all.

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const inPath = path.resolve(ROOT, args[0] || 'public/logo_trans.png');
const outPath = path.resolve(ROOT, args[1] || 'public/zorpha-mark.png');

if (!fs.existsSync(inPath)) {
  console.error('no such source image: ' + inPath);
  process.exit(1);
}

/* ---------- decode ---------- */

const buf = fs.readFileSync(inPath);
if (buf.readUInt32BE(0) !== 0x89504e47) {
  console.error('not a PNG');
  process.exit(1);
}

let off = 8;
let ihdr = null;
const idat = [];
while (off < buf.length) {
  const len = buf.readUInt32BE(off);
  const type = buf.toString('ascii', off + 4, off + 8);
  const data = buf.subarray(off + 8, off + 8 + len);
  if (type === 'IHDR') {
    ihdr = {
      w: data.readUInt32BE(0),
      h: data.readUInt32BE(4),
      depth: data[8],
      color: data[9],
      interlace: data[12],
    };
  } else if (type === 'IDAT') {
    idat.push(data);
  }
  off += 12 + len;
}

if (!ihdr || ihdr.depth !== 8 || ihdr.color !== 6 || ihdr.interlace !== 0) {
  console.error('need an 8-bit RGBA non-interlaced PNG, got ' + JSON.stringify(ihdr));
  process.exit(1);
}

const { w, h } = ihdr;
const bpp = 4;
const stride = w * bpp;
const raw = zlib.inflateSync(Buffer.concat(idat));
const px = Buffer.alloc(h * stride);

let p = 0;
for (let y = 0; y < h; y++) {
  const filter = raw[p++];
  const line = raw.subarray(p, p + stride);
  p += stride;
  const cur = px.subarray(y * stride, (y + 1) * stride);
  const prev = y ? px.subarray((y - 1) * stride, y * stride) : Buffer.alloc(stride);
  for (let x = 0; x < stride; x++) {
    const a = x >= bpp ? cur[x - bpp] : 0;
    const b = prev[x];
    const c = x >= bpp ? prev[x - bpp] : 0;
    let v = line[x];
    if (filter === 1) v += a;
    else if (filter === 2) v += b;
    else if (filter === 3) v += (a + b) >> 1;
    else if (filter === 4) {
      const pa = Math.abs(b - c);
      const pb = Math.abs(a - c);
      const pc = Math.abs(a + b - 2 * c);
      v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }
    cur[x] = v & 255;
  }
}

/* ---------- bounding box ---------- */

let x0 = w;
let y0 = h;
let x1 = -1;
let y1 = -1;
for (let y = 0; y < h; y++) {
  for (let x = 0; x < w; x++) {
    if (px[y * stride + x * 4 + 3] > 8) {
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
}
if (x1 < 0) {
  console.error('image is fully transparent');
  process.exit(1);
}

const cw = x1 - x0 + 1;
const ch = y1 - y0 + 1;

/* ---------- encode ---------- */

// Filter 0 (None) on every scanline. The image is tiny and this keeps the
// encoder honest -- a wrong predictor would corrupt the output silently.
const outStride = cw * bpp;
const body = Buffer.alloc(ch * (outStride + 1));
for (let y = 0; y < ch; y++) {
  body[y * (outStride + 1)] = 0;
  px.copy(
    body,
    y * (outStride + 1) + 1,
    (y0 + y) * stride + x0 * bpp,
    (y0 + y) * stride + x0 * bpp + outStride,
  );
}

const CRC = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return (b) => {
    let c = -1;
    for (let i = 0; i < b.length; i++) c = t[(c ^ b[i]) & 0xff] ^ (c >>> 8);
    return (c ^ -1) >>> 0;
  };
})();

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(CRC(td));
  return Buffer.concat([len, td, crc]);
}

const ihdrOut = Buffer.alloc(13);
ihdrOut.writeUInt32BE(cw, 0);
ihdrOut.writeUInt32BE(ch, 4);
ihdrOut[8] = 8; // bit depth
ihdrOut[9] = 6; // colour type: RGBA
ihdrOut[10] = 0; // deflate
ihdrOut[11] = 0; // adaptive filtering
ihdrOut[12] = 0; // no interlace

fs.writeFileSync(
  outPath,
  Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdrOut),
    chunk('IDAT', zlib.deflateSync(body, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]),
);

console.log(
  '  ' + w + 'x' + h + ' -> ' + cw + 'x' + ch +
  '  (cropped x ' + x0 + '..' + x1 + ', y ' + y0 + '..' + y1 + ')',
);
console.log('  wrote ' + outPath + '  ' + fs.statSync(outPath).size + ' bytes');
