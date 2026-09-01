#!/usr/bin/env node
/**
 * Every contract a broadcast artifact created, as "address source:Name 0xargs".
 *
 * Written for verification. Three things it does that the previous hardcoded
 * list of `forge verify-contract` calls did not:
 *
 *  1. It finds contracts the deploy script did not name. The oracle, the two
 *     adapters and the three vaults were all deployed and none of them were
 *     ever verified, because nobody added a line for them.
 *
 *  2. It recovers constructor arguments. forge records `arguments` as decoded
 *     strings, which would have to be re-encoded against the ABI to be usable.
 *     The transaction input is creationCode ++ abi.encode(args), so stripping
 *     the compiled creation code off the front yields the exact bytes with no
 *     re-encoding and no guesswork.
 *
 *  3. It covers CREATE2. The three vaults come out of the factory rather than
 *     from a top-level transaction, so they appear only under
 *     `additionalContracts` and carry an initCode rather than an input. They
 *     have no contractName either, so the artifact is identified by finding
 *     the one whose creation code the initCode starts with.
 *
 * Usage: node script/broadcast-contracts.js <run-latest.json>...
 */
const fs = require("fs");
const path = require("path");

const artifactCache = new Map();

function loadArtifact(name) {
  if (artifactCache.has(name)) return artifactCache.get(name);
  let found = null;
  for (const dir of fs.readdirSync("out")) {
    const p = path.join("out", dir, name + ".json");
    if (fs.existsSync(p)) {
      found = JSON.parse(fs.readFileSync(p, "utf8"));
      break;
    }
  }
  artifactCache.set(name, found);
  return found;
}

/** Every compiled artifact, for matching CREATE2 initcode against. */
let allArtifacts = null;
function artifacts() {
  if (allArtifacts) return allArtifacts;
  allArtifacts = [];
  for (const dir of fs.readdirSync("out")) {
    const d = path.join("out", dir);
    if (!fs.statSync(d).isDirectory()) continue;
    for (const f of fs.readdirSync(d)) {
      if (!f.endsWith(".json")) continue;
      try {
        const a = JSON.parse(fs.readFileSync(path.join(d, f), "utf8"));
        const code = a.bytecode && a.bytecode.object;
        // Anything without creation code or a compilation target cannot have
        // been deployed: interfaces, libraries that were inlined, ABI-only.
        if (code && code.length > 2 && a.metadata) {
          allArtifacts.push({ name: f.slice(0, -5), artifact: a, code: code.replace(/^0x/, "") });
        }
      } catch {
        /* not a contract artifact */
      }
    }
  }
  // Longest creation code first: a shorter contract's code is never a prefix of
  // a longer one's by accident, but checking long-first makes that impossible.
  allArtifacts.sort((x, y) => y.code.length - x.code.length);
  return allArtifacts;
}

function sourcePath(artifact, name) {
  const target = artifact.metadata && artifact.metadata.settings.compilationTarget;
  if (!target) return null;
  for (const [file, contract] of Object.entries(target)) {
    if (contract === name) return file;
  }
  return Object.keys(target)[0] || null;
}

const rows = [];
const seen = new Set();

for (const file of process.argv.slice(2)) {
  if (!fs.existsSync(file)) continue;
  const j = JSON.parse(fs.readFileSync(file, "utf8"));

  for (const t of j.transactions || []) {
    if (t.transactionType === "CREATE" && t.contractAddress && t.contractName) {
      const a = loadArtifact(t.contractName);
      if (!a) {
        console.error(`  no compiled artifact for ${t.contractName}`);
        continue;
      }
      const code = (a.bytecode.object || "").replace(/^0x/, "");
      const input = ((t.transaction && t.transaction.input) || "").replace(/^0x/, "");
      const args = input.startsWith(code) ? input.slice(code.length) : "";
      const src = sourcePath(a, t.contractName);
      if (!src) continue;
      if (seen.has(t.contractAddress)) continue;
      seen.add(t.contractAddress);
      rows.push([t.contractAddress, `${src}:${t.contractName}`, args ? "0x" + args : ""].join(" "));
    }

    for (const extra of t.additionalContracts || []) {
      if (!extra.address || seen.has(extra.address)) continue;
      const ic = (extra.initCode || "").replace(/^0x/, "");
      if (!ic) continue;
      const hit = artifacts().find((x) => ic.startsWith(x.code));
      if (!hit) {
        console.error(`  could not identify CREATE2 contract at ${extra.address}`);
        continue;
      }
      const src = sourcePath(hit.artifact, hit.name);
      if (!src) continue;
      seen.add(extra.address);
      const args = ic.slice(hit.code.length);
      rows.push([extra.address, `${src}:${hit.name}`, args ? "0x" + args : ""].join(" "));
    }
  }
}

if (rows.length) console.log(rows.join("\n"));
