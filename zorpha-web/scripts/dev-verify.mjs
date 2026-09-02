// A dev server that writes to its own build tree.
//
// `next dev` and `next build` both write `.next`. Running one while the other
// is live leaves a tree that is half dev and half production: the dev server
// requests `app/portal/layout.js` and finds only `layout-8ed2efd6.js`, so every
// core chunk 404s and the app never hydrates. Nothing errors visibly. What you
// see is a fully rendered page in which every on-chain value shows the
// server-side "—" placeholder, which is indistinguishable from broken contract
// reads — and that is what sent me looking at wagmi config for a while before
// checking the disk.
//
// NEXT_DIST_DIR is read by next.config.mjs. With it set, this server keeps its
// own tree and the two stop colliding.
//
//   npm run dev         normal, writes .next
//   npm run dev:verify  writes .next-verify, safe to run beside a build
//
// Vercel never sets NEXT_DIST_DIR, so production builds are unaffected.

import { spawn } from 'node:child_process';

const child = spawn('npx', ['next', 'dev', ...process.argv.slice(2)], {
  stdio: 'inherit',
  shell: true,
  env: { ...process.env, NEXT_DIST_DIR: '.next-verify' },
});

child.on('exit', (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 0);
});
