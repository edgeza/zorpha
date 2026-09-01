# Testnet, start to finish

Written for someone who has never deployed this before. Every command is meant
to be copied as-is. Where a value is yours to fill in, it looks like
`<THIS>`.

---

## Where you already are

Checked on chain, so this is not an assumption:

| | |
| --- | --- |
| Your wallet | `0xB4a7C2DeebB5EaDC34e120bC8a5708508DC17f4b` |
| Testnet balance | **0.01 ETH** — the faucet worked |
| Transactions sent | 0 |
| Whole deploy costs | ~0.00047 ETH at the current 0.01 gwei |
| Headroom | **21×** |

You have enough gas. Nothing else about funding needs thinking about.

---

## The one thing you still need

**A second account.** Both deploy scripts refuse to run if the governance
address equals the deployer, and that refusal is the point: the deploy proves
the deploy key ends up holding no tokens and no roles, which means nothing if
it is also the key that governs everything.

In Rabby: **Add address → Create new address** on the same seed. Copy its
address. That is your `GOVERNANCE`.

Send it a little testnet ETH too. It needs none for the deploy itself, but it
does for the two steps afterwards, and finding that out later is annoying.

---

## Getting your key into the terminal

The deploy needs to sign transactions, so it needs the deployer's private key
in your shell.

In Rabby: **⋮ next to the account → Private Key → enter password → copy.**

Three things, and then never think about it again:

- Paste it **only** into your own terminal. Not into a chat, a file, a commit,
  or an issue. Anyone who has it has the account.
- This is a **testnet** key holding 0.01 test ETH. Treat mainnet as an entirely
  separate problem, ideally a hardware wallet.
- After the deploy the script asserts this key holds **zero** ZOR and **zero**
  roles. That is deliberate: by the end it is a key that can do nothing.

---

## Step 1 — Set your variables

Open a terminal in `sidequest-protocol/contracts` and paste this, filling in
the two placeholders:

```bash
export PRIVATE_KEY=<PASTE_YOUR_RABBY_KEY>
export GOVERNANCE=<YOUR_SECOND_ACCOUNT_ADDRESS>

# Where the 13% protocol-owned liquidity goes. On testnet your own second
# account is fine.
export LIQUIDITY_RECIPIENT=$GOVERNANCE

export RH_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com/rpc
export RH_EXPLORER_URL=https://explorer.testnet.chain.robinhood.com
```

These live only in this terminal window. Close it and they are gone, which is
why the rest of the guide happens in the same window.

---

## Step 2 — Generate the airdrop root

The distributor commits to a Merkle root at deploy time, so it has to exist
first. This runs from `sidequest-protocol/`, one level up from the contracts:

```bash
cd .. && npm install && npm run airdrop:testnet
```

It reads `data/snapshot-testnet.csv`, which already contains your two accounts
so you can actually test claiming, writes each recipient's proof into
`zorpha-web/data/airdrop/`, and prints a line you can copy verbatim:

```
AIRDROP_MERKLE_ROOT=0x...
```

Paste that line into your terminal, then add the deadline and go back:

```bash
export AIRDROP_CLAIM_DEADLINE=$(date -d '+90 days' +%s)
cd contracts
```

That snapshot is a testnet fixture, not the real allocation. The real one is a
separate file, published with its sha256 **before** claims open so anyone can
rebuild the root and confirm nothing changed afterwards.

---

## Step 3 — Deploy everything

```bash
./script/testnet-launch.sh
```

That is the whole deploy. It runs four phases in order and passes each one's
addresses to the next, so there is no copying hex between steps.

**Phase 1, fixtures.** Testnet is a bare chain — no USDG, no curated vaults, no
DEX — so this deploys stand-ins for all three.

**Phases 2 and 3, token and vault layers.** Runs the full test suite and
slither first and stops if either fails. Then deploys ZOR and distributes the
entire supply in one transaction, then the vaults.

**Phase 4, leadership.** The permissionless vault launcher, and it writes its
address into `zorpha-web/.env.local` for you.

Expect a few minutes, mostly tests. It refuses up front — before spending any
gas — if your governance account is the deployer, if the RPC is not testnet, or
if you have no balance.

### What to read in the output

- `verified: deployer holds 0 ZOR` — the distribution worked. If this is
  missing, stop.
- A **swap stub** warning is expected. Testnet has no DEX.
- A **yield stub** warning is not. It would mean the yield vault earns nothing.

---

## Step 4 — Two things the script cannot do

Both fail **silently** if skipped, which is exactly why they are called out.

### 4a. Let the launcher create vaults

The factory's admin is your governance account, so only it can grant this. The
script prints the exact command with the addresses already filled in. Until it
runs, `launchYieldVault` reverts for everyone and the Leaders page just sits
empty with no error anywhere.

Run it from the **governance** account, either with `cast send` using that
account's key, or by pasting the same call into Rabby.

### 4b. Accept treasury ownership

`ProtocolTreasury` uses a two-step ownership transfer, so it stays pending
until accepted. Queue `acceptOwnership()` through the Timelock.

---

## Step 5 — Start the site

```bash
cd ../../zorpha-web && npm run dev
```

**Watch the port it prints.** Another project on this machine already listens on
3000 (Autonama AI Fund), so Next will fall through to 3001 or higher. Opening
3000 out of habit shows you a different site's 404 and looks like Zorpha is
broken when it is running perfectly on the next port up.

Open `/portal` on whatever port it printed. The orange "not configured" banner
should be **gone** — the deploy filled every address in. If a name is still
listed there, that contract did not deploy.

---

## Step 6 — Prove it works

Work phases 3 and 5b of `docs/LAUNCH-CHECKLIST.md`. The two that matter most,
because they are the product:

**The yield vault charges a fee.** Deposit tUSDG, make the venue earn, redeem.
You should get back **less** than the full gain — that difference is the 10%
performance fee. If you get all of it, fees are broken.

```bash
cast send $YIELD_TARGET "accrue(uint256)" 500000000 \
  --rpc-url $RH_TESTNET_RPC_URL --private-key $PRIVATE_KEY
```

**The manager loses first.** Launch a vault from a *second* account, deposit
from a *third*, then force a loss smaller than the leader's buffer. The
depositor redeems **whole**, and `totalAbsorbed()` on the escrow is non-zero.
That is the entire pitch, and you should watch it happen once before telling
anyone about it.

---

## When something goes wrong

**`GOVERNANCE must not equal the deployer`** — you need that second account.

**`insufficient funds`** — the faucet went to a different address than the key
you exported. Check `cast wallet address --private-key $PRIVATE_KEY` matches
the funded one.

**`forge: command not found`** — foundry is not on this shell's PATH. Reopen
the terminal.

**Slither or a test fails** — the script stops before deploying anything. That
is the gate working. Read the failure; do not skip it.

**A phase half-finished** — safe to re-run `./script/testnet-launch.sh`. Each
phase redeploys and the last run wins.

---

## Before mainnet

Two gates, and neither is optional.

**The fork test.** Testnet proves the protocol's own accounting and nothing at
all about whether it talks to real venues correctly — that is where the router
bug was hiding.

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path 'test/fork/*' -vv
```

**An external audit.** The first-loss waterfall is new financial logic and the
only person who has reviewed it is the one who wrote it. That review found two
real bugs, which is the argument for someone else doing it.
