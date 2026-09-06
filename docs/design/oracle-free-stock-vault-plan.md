# Oracle-free stock vault — slice 1 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put one tokenized-equity long/flat fund on Robinhood Chain mainnet, priced by a
Uniswap V3 TWAP rather than by an operated oracle, and make it operable from the manager
terminal that already exists.

**Architecture:** One new contract, `UniswapV3TwapAdapter`, implements the
`AggregatorV3Interface` that `SpotVaultMinimal` already consumes. It reads the NVDA/USDG
0.05% pool's `observe()` for a 30-minute TWAP, converts the mean tick into "USDG per whole
NVDA, scaled to 1e8", and reverts on five guards. `SpotVaultMinimal` ships byte-for-byte
unmodified; the swap adapter, the indexer, the receipts feed and the manager terminal
already exist and are wired up rather than rewritten.

**Tech Stack:** Solidity 0.8.28 / Foundry (`sidequest-protocol/contracts`), OpenZeppelin v5
(`Math.mulDiv` for 512-bit precision), a vendored `TickMath.getSqrtRatioAtTick`, Next.js +
wagmi + viem (`zorpha-web`), Supabase (SQL migrations in `zorpha-web/migrations`), and Safe
Transaction Builder JSON for every mainnet write.

**Spec:** `docs/design/oracle-free-stock-vault.md`

## Global Constraints

Exact values, from the spec and from the live chain. Every task's requirements implicitly
include this section.

- Chain: Robinhood Chain mainnet, **chain id 4663**, RPC `https://rpc.mainnet.chain.robinhood.com`
- NVDA (asset, base): `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` — **18 decimals**
- USDG (cash, quote): `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` — **6 decimals**
- Pool: `0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3` — 0.05% fee, **token0 = USDG, token1 = NVDA**
- SwapRouter02: `0xCaf681a66D020601342297493863E78C959E5cb2`
- Governance Safe (2-of-2): `0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4`
- Timelock: `0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc`
- ProtocolTreasury (fee recipient): `0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6`
- Adapter params: `twapWindow` 1800, `minCardinality` 300, `minLiquidity` 12000000000000000000
  (1.2e19), `maxObservationAge` 14400, `maxSpotDivergenceBps` 200, `decimals()` 8
- Vault params: `maxOracleStaleness` 3600, `rebalanceThresholdBps` 100, `maxSlippageBps` 100,
  `performanceFeeBps` 1000, `emergencyRedeemCooldown` 0
- Roles: `DEFAULT_ADMIN_ROLE` to the Timelock; `KEEPER_ROLE` and `RISK_COUNCIL_ROLE` to the Safe
- Solidity **0.8.28**; every file opens `// SPDX-License-Identifier: MIT` then
  `pragma solidity ^0.8.28;`
- **All existing tests must stay green.** The runner's own baseline, measured on `main`:
  **334 passed, 0 failed, 34 skipped, 368 total.** (An earlier figure of 366 came from
  grepping `function test`, which is not what the runner counts — use these.) The 34 skips
  are the fork tests, which need `RH_MAINNET_RPC_URL`. Run `forge test` with no fork env set
  after every task, and get the exact delta with
  `forge test --no-match-path '<the file you added>'`
- `SpotVaultMinimal.sol`, `RWRotationVault.sol` and every other existing contract ship
  **unmodified**. This plan adds files; it edits no existing file under `src/`
- The adapter **must not implement `maxStaleness()`**. `OracleWindow.requireNotTighterThan`
  staticcalls for it and no-ops when it is absent; that no-op is the intended path
- Line endings **LF**, no trailing whitespace
- **No AI attribution anywhere.** No `Co-Authored-By` trailer, no "Generated with Claude
  Code" line, no mention of Claude, Anthropic or AI in any commit message, PR body, code
  comment or document
- Every mainnet state change goes through the **2-of-2 Safe** as a Transaction Builder JSON
  in `sidequest-protocol/contracts/safe-batches/`. The only hot-key transaction permitted is
  the `CREATE` in Task 8, signed from the `mainnet-deploy` keystore
- Generate every hex calldata with `cast calldata` redirected **straight to a file**. Never
  hand-copy hex into JSON — an earlier batch silently lost three bytes that way

---

## Two corrections to the spec, both measured

Settle these before starting; the tasks below already reflect them.

### 1. Fork tests run at HEAD, not at a pinned block

The spec says "against a mainnet fork at a pinned block". **The public RPC prunes archive
state, so pinning does not work.** Measured 6 September 2026, head 56,129,659:

```
$ cast call 0xd4eb...14a3 "liquidity()(uint128)" --block 55629659
Error: server returned an error response: error code -32000: metadata is not found, 55629662

$ cast call 0xd4eb...14a3 "liquidity()(uint128)"
27237174114824804987
```

All seven existing fork tests already use bare `vm.createSelectFork(url)` at head for this
reason. Follow that convention, and follow `SpotRebalanceMainnet.t.sol`'s discipline of
**deriving expected values from live state** rather than asserting hardcoded constants —
that file reads the price out of the pool precisely because a pinned number goes stale.

Fork tests are opt-in and must skip cleanly:

```solidity
// in setUp()
string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
if (bytes(url).length == 0) return;
vm.createSelectFork(url);
forked = true;

// first line of every test
if (!forked) { vm.skip(true); }
```

### 2. The manager terminal already exists

The spec's "The terminal" section reads as though it were new. It is not:

| Spec bullet | Where it already lives |
| --- | --- |
| Current position, asset against cash | `components/portal/terminal/ManagerTerminal.tsx` |
| One control that sets a target weight | `components/portal/terminal/RebalancePanel.tsx`, `SpotRebalance` |
| The resulting receipt | `RebalancePanel.tsx` transaction link, and `app/portal/receipts/page.tsx` |
| The running track record | `app/portal/receipts/page.tsx`, via `listLatestRebalances` |
| What the move will do before signing | `lib/vault-terminal.ts`, `previewSpot` |

`factoryVaults()` in `lib/vault-terminal.ts` lists the spot vault the moment
`NEXT_PUBLIC_SPOT_VAULT_ADDRESS` is set. So the genuinely new UI work in slice 1 is:

- **the NVDA price chart** (Task 12) — nothing resembling it exists;
- **retracting the site's standing claim** that the spot vault and the oracle are
  deliberately absent from mainnet (Task 11), which becomes false the moment Task 8 lands;
- **the two disclosures** the spec requires (Task 13).

Everything else is configuration.

### A third thing the spec left open: RISK_COUNCIL_ROLE

The spec assigns `DEFAULT_ADMIN_ROLE` and `KEEPER_ROLE` and says nothing about
`RISK_COUNCIL_ROLE`, which gates `setCircuitBreaker`. This plan gives it to the **Safe**, by
the spec's own argument for `KEEPER_ROLE`: halting deposits is an emergency brake and a
brake that takes 48 hours to pull is not a brake. It is disclosed alongside the keeper
exception in Task 13.

---

## File structure

**Create, contracts** (all paths under `sidequest-protocol/contracts/`)

| File | Responsibility |
| --- | --- |
| `src/lib/TickMath.sol` | `getSqrtRatioAtTick` and the two ratio bounds. Nothing else. |
| `src/oracle/UniswapV3TwapAdapter.sol` | Pool interface, price arithmetic, five guards, `latestRoundData`, and the ungated charting view. |
| `test/mocks/MockUniswapV3Pool.sol` | A pool whose tick, liquidity, cardinality and observation age are settable, so each guard fires in isolation. It must ALSO support per-slot observation ages, a per-slot `initialized` flag, and an explicit cumulative series — see the note under Task 2, Step 3. |
| `test/lib/TickMath.t.sol` | Unit, no network. Known-answer checks. |
| `test/oracle/UniswapV3TwapAdapterUnit.t.sol` | Unit, no network. Constructor ordering, price arithmetic, five guards. |
| `test/fork/StockVaultMainnet.t.sol` | Fork. Adapter against the real pool, then the whole vault round-trip. |
| `script/DeployStockVault.s.sol` | Deploys the TWAP adapter, the swap adapter and the vault, with admin landing on the Safe. |
| `safe-batches/I-stock-vault-roles.json` | The one Safe batch: roles, swap adapter, admin to the Timelock. |

**Create, web and data**

| File | Responsibility |
| --- | --- |
| `zorpha-web/migrations/013-mainnet-stock-vault.sql` | Registers the vault on chain 4663 so the indexer and the portal both see it. |
| `zorpha-web/lib/twap-adapter-abi.ts` | The adapter ABI. Kept out of `manager-abi.ts`, which is the operator surface. |
| `zorpha-web/components/portal/StockPrice.tsx` | The NVDA chart, read from the adapter. |

**Modify, web**

| File | Change |
| --- | --- |
| `zorpha-web/lib/contracts.ts` | `isExpectedAbsence`: drop `oracle` and `spotVault` from the mainnet allow-list. |
| `zorpha-web/lib/deployment.ts` | `NOT_ON_MAINNET`: remove the MedianOracle and spot-vault rows. |
| `zorpha-web/.env.local` and Vercel production env | `NEXT_PUBLIC_ORACLE_ADDRESS`, `NEXT_PUBLIC_SPOT_VAULT_ADDRESS`. |
| `zorpha-web/components/portal/terminal/ManagerTerminal.tsx` | Mount `StockPrice` and the role disclosure. |
| `zorpha-web/app/(marketing)/protocol/page.tsx` | Both disclosures, in the voice used for the adapter-timelock exception. |

**Do not touch:** `src/vaults/SpotVaultMinimal.sol`, `src/vaults/RWRotationVault.sol`,
`src/oracle/MedianOracle.sol`, `src/oracle/OracleWindow.sol`,
`src/adapters/RobinhoodChainRouterAdapter.sol`.

---

## The price arithmetic, written out once

Every task that touches price refers back to this. Getting the direction backwards is the
classic bug in this class of contract.

`SpotVaultMinimal.assetToCash` is:

```
assetToCash = assetAmt * 10^cashDec * p / (10^assetDec * 10^priceDec)
```

so `p` is **the price of one whole base token in whole quote units**, at `10^priceDec`.
Here: USDG per NVDA, at 1e8.

Uniswap gives `sqrtPriceX96` where `(sqrtPriceX96 / 2^96)^2` is **token1 raw units per
token0 raw unit**. For this pool token0 is USDG (6dp) and token1 is NVDA (18dp), so the raw
ratio is the reciprocal of what the vault wants, and both decimal scalings apply. Worked at
tick 221,882, the live tick:

```
sqrtPriceX96                            5.209002981863638e33
raw token1/token0   (sqrtP/2^96)^2      4.3225e9
NVDA per USDG       x 10^6 / 10^18      0.00432246
USDG per NVDA       reciprocal          231.35
answer at 1e8                           23,134,970,771
```

Two branches, both two `Math.mulDiv` calls, both exact to 512 bits:

```
Q96 = 2^96

base == token0 (quote == token1):
    ratioX96 = mulDiv(sqrtP, sqrtP, Q96)
    answer   = mulDiv(ratioX96, 10^baseDec * 1e8, Q96 * 10^quoteDec)

base == token1 (quote == token0):     <-- NVDA/USDG takes this branch
    inverseX96 = mulDiv(Q96, Q96, sqrtP)
    answer     = mulDiv(inverseX96, 10^baseDec * 1e8, sqrtP * 10^quoteDec)
```

Checking the second branch against the numbers above:
`inverseX96 = 6.2771e57 / 5.209e33 = 1.20505e24`, then
`1.20505e24 * 1e26 / (5.209e33 * 1e6) = 2.3134e10`. Correct.

Squaring `sqrtPriceX96` directly overflows `uint256` above roughly tick 500,000, which is
why neither branch ever forms `sqrtP * sqrtP` as a plain product.

---

## Task 1: TickMath

**Files:**
- Create: `sidequest-protocol/contracts/src/lib/TickMath.sol`
- Test: `sidequest-protocol/contracts/test/lib/TickMath.t.sol`

**Interfaces:**
- Consumes: nothing
- Produces: `library TickMath` with
  `getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96)`,
  `int24 constant MIN_TICK = -887272`, `int24 constant MAX_TICK = 887272`,
  `uint160 constant MIN_SQRT_RATIO = 4295128739`,
  `uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342`,
  and `error TickOutOfRange(int24 tick)`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/TickMath.t.sol`.

**The revert cases need a harness.** A library's `internal` function is inlined into its
caller, so it reverts inside the test frame rather than in a sub-call and `vm.expectRevert`
never sees it — the test simply fails with the library's own error. Put an external wrapper
in the same file and route the two revert tests through it. (This does not apply to later
tasks: a constructor revert is a CREATE and `latestRoundData` is an external call, both of
which `expectRevert` does intercept.)

`assertEq`, `assertGt`, `assertLe`, `assertApproxEqAbs`, `assertApproxEqRel` and
`bound(int256,int256,int256)` are all `internal pure` in this forge-std, so the value tests
can be `public pure`. The revert tests cannot, because they touch `vm`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../../src/lib/TickMath.sol";

/// @notice `getSqrtRatioAtTick` behind an external call, so `vm.expectRevert`
///         has something to intercept.
contract TickMathHarness {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }
}

/// @notice Known-answer tests for the vendored tick-to-ratio conversion.
///
///         Vendored code gets vendored wrong: a single mistyped magic constant
///         is a price that is subtly off at some ticks and exactly right at
///         others, which no round-trip test catches. So the checks below are
///         against values that are fixed by the Uniswap V3 specification, not
///         against this implementation's own output.
contract TickMathTest is Test {
    TickMathHarness harness;

    function setUp() public {
        harness = new TickMathHarness();
    }

    /// Tick zero is a ratio of exactly one, so sqrtPriceX96 is exactly 2^96.
    function test_TickZeroIsQ96() public pure {
        assertEq(uint256(TickMath.getSqrtRatioAtTick(0)), 1 << 96);
    }

    function test_BoundsMatchTheSpecification() public pure {
        assertEq(uint256(TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK)), uint256(TickMath.MIN_SQRT_RATIO));
        assertEq(uint256(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK)), uint256(TickMath.MAX_SQRT_RATIO));
    }

    /// One tick is one basis point of PRICE, so half a basis point of sqrt(price).
    function test_OneTickIsHalfABasisPointOfSqrtPrice() public pure {
        uint256 at0 = TickMath.getSqrtRatioAtTick(0);
        uint256 at1 = TickMath.getSqrtRatioAtTick(1);
        uint256 gainBpsE4 = ((at1 - at0) * 1e8) / at0; // in 1e-8 units
        // sqrt(1.0001) - 1 = 4.99987e-5, i.e. 4999 in 1e-8 units.
        assertApproxEqAbs(gainBpsE4, 4999, 2);
    }

    function test_IsMonotonic() public pure {
        assertGt(TickMath.getSqrtRatioAtTick(221882), TickMath.getSqrtRatioAtTick(221881));
        assertLt(TickMath.getSqrtRatioAtTick(-221882), TickMath.getSqrtRatioAtTick(-221881));
    }

    function test_NegativeAndPositiveAreReciprocal() public pure {
        uint256 up = TickMath.getSqrtRatioAtTick(100000);
        uint256 down = TickMath.getSqrtRatioAtTick(-100000);
        // (2^96)^2 / up should be down, to within rounding.
        uint256 expected = ((1 << 96) * (1 << 96)) / up;
        assertApproxEqRel(down, expected, 1e12); // 1e-6 relative
    }

    /// The live NVDA/USDG tick, against the value the pool's own slot0 reports.
    /// External ground truth: this number was read off chain 4663, so it cannot
    /// agree with a bug in the library.
    function test_TheLivePoolTickProducesTheObservedRatio() public pure {
        uint256 r = uint256(TickMath.getSqrtRatioAtTick(221882));
        assertApproxEqRel(r, 5209002981863638722623952383317079, 1e14, "tick 221882");
    }

    function test_RevertsAboveMaxTick() public {
        vm.expectRevert(abi.encodeWithSelector(TickMath.TickOutOfRange.selector, int24(887273)));
        harness.getSqrtRatioAtTick(int24(887273));
    }

    function test_RevertsBelowMinTick() public {
        vm.expectRevert(abi.encodeWithSelector(TickMath.TickOutOfRange.selector, int24(-887273)));
        harness.getSqrtRatioAtTick(int24(-887273));
    }

    function testFuzz_IsMonotonicEverywhere(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        assertGt(
            TickMath.getSqrtRatioAtTick(tick + 1),
            TickMath.getSqrtRatioAtTick(tick),
            "a higher tick must never produce a lower ratio"
        );
    }

    function testFuzz_StaysInsideTheRatioBounds(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint256 r = TickMath.getSqrtRatioAtTick(tick);
        assertGe(r, uint256(TickMath.MIN_SQRT_RATIO));
        assertLe(r, uint256(TickMath.MAX_SQRT_RATIO));
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
forge test --match-path 'test/lib/TickMath.t.sol' -vv
```

Expected: compilation failure, `Source "src/lib/TickMath.sol" not found`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/TickMath.sol`. The magic constants are the canonical Uniswap V3 ones and
must be copied exactly; the whole body is `unchecked` because the algorithm relies on
wrapping multiplication that 0.8.x would otherwise revert on.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TickMath
/// @notice Tick to sqrt-price conversion, vendored from Uniswap V3 core.
///
///         Vendored rather than imported because v3-core pins
///         `pragma >=0.5.0 <0.8.0` and its arithmetic DEPENDS on wrapping
///         multiplication, which 0.8.x reverts on. Adding the dependency would
///         mean either a second solc version in this build or a fork anyway.
///         This is the fork, kept to the single function that is needed.
///
///         Only `getSqrtRatioAtTick` is here. The inverse,
///         `getTickAtSqrtRatio`, is not, because nothing in this protocol goes
///         that direction and unused vendored code is unreviewed vendored code.
library TickMath {
    error TickOutOfRange(int24 tick);

    /// @dev The minimum tick that may be passed to `getSqrtRatioAtTick`.
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to `getSqrtRatioAtTick`.
    int24 internal constant MAX_TICK = 887272;

    /// @dev `getSqrtRatioAtTick(MIN_TICK)`.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev `getSqrtRatioAtTick(MAX_TICK)`.
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice Calculates sqrt(1.0001^tick) * 2^96.
    /// @param tick The input tick.
    /// @return sqrtPriceX96 The sqrt ratio as a Q64.96.
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange(tick);

            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Downcast from Q128.128 to Q64.96, rounding up so that
            // getTickAtSqrtRatio of the result is always the input tick.
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
forge test --match-path 'test/lib/TickMath.t.sol' -vv
```

Expected: **10 passing** (8 value/revert tests plus 2 fuzz runs).

- [ ] **Step 5: Confirm nothing else moved**

```bash
forge test
```

Expected: **344 passed, 0 failed, 34 skipped, 378 total** — the 334 baseline plus 10.

- [ ] **Step 6: Commit**

```bash
git add sidequest-protocol/contracts/src/lib/TickMath.sol sidequest-protocol/contracts/test/lib/TickMath.t.sol
git commit -m "feat(oracle): vendor TickMath.getSqrtRatioAtTick"
```

---

## Task 2: A mock pool, and the constructor's ordering assertion

The constructor's job is to make "the deployer passed base and quote the wrong way round"
impossible rather than merely unlikely. That is the single highest-value check in the
contract, so it gets built and tested before any price arithmetic exists.

**Files:**
- Create: `sidequest-protocol/contracts/test/mocks/MockUniswapV3Pool.sol`
- Create: `sidequest-protocol/contracts/src/oracle/UniswapV3TwapAdapter.sol` (constructor and
  interface only in this task)
- Test: `sidequest-protocol/contracts/test/oracle/UniswapV3TwapAdapterUnit.t.sol`

**Interfaces:**
- Consumes: `TickMath` from Task 1 (imported, not yet used).
- Produces:
  - `interface IUniswapV3PoolMinimal` with `token0()`, `token1()`, `liquidity()`, `slot0()`,
    `observe(uint32[])`, `observations(uint256)`
  - `contract UniswapV3TwapAdapter is AggregatorV3Interface` with constructor
    `(address pool_, address base_, address quote_, uint32 twapWindow_, uint16 minCardinality_, uint128 minLiquidity_, uint32 maxObservationAge_, uint16 maxSpotDivergenceBps_)`
  - public immutables `pool` (`IUniswapV3PoolMinimal`), `base`, `quote` (`address`),
    `baseIsToken0` (`bool`), `baseDecimals`, `quoteDecimals` (`uint8`), `twapWindow`
    (`uint32`), `minCardinality` (`uint16`), `minLiquidity` (`uint128`), `maxObservationAge`
    (`uint32`), `maxSpotDivergenceBps` (`uint16`)
  - `error PoolTokenMismatch(address token0, address token1)`
  - `function decimals() external pure returns (uint8)` returning `8`
  - `MockUniswapV3Pool` with constructor `(address token0_, address token1_)` and setters
    `setTick(int24)`, `setLiquidity(uint128)`, `setCardinality(uint16)`,
    `setObservationAge(uint32)`, `setTickCumulatives(int56 older, int56 newer)`,
    `setObserveReverts(bool)`

- [ ] **Step 1: Write the failing test**

Create `test/oracle/UniswapV3TwapAdapterUnit.t.sol` with only the constructor tests for
now. Later tasks append to this file.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniswapV3TwapAdapter} from "../../src/oracle/UniswapV3TwapAdapter.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract UniswapV3TwapAdapterUnitTest is Test {
    // Mirrors the live pool's shape: token0 is the 6dp quote, token1 the 18dp base.
    MockERC20 usdg;   // token0, quote, 6dp
    MockERC20 nvda;   // token1, base,  18dp
    MockUniswapV3Pool pool;

    uint32 constant WINDOW = 1800;
    uint16 constant MIN_CARDINALITY = 300;
    uint128 constant MIN_LIQUIDITY = 12e18;
    uint32 constant MAX_OBS_AGE = 4 hours;
    uint16 constant MAX_DIVERGENCE_BPS = 200;

    function setUp() public {
        // REQUIRED. Forge starts at block.timestamp == 1, and the mock computes
        // an observation's timestamp by subtracting an age from now. Without a
        // warp that subtraction underflows and every guard test in Task 4 fails
        // inside the fixture rather than in the code under test.
        vm.warp(1788713101);

        usdg = new MockERC20("USDG", "USDG", 6);
        nvda = new MockERC20("NVDA", "NVDA", 18);
        pool = new MockUniswapV3Pool(address(usdg), address(nvda));
    }

    function _deploy(address base_, address quote_) internal returns (UniswapV3TwapAdapter) {
        return new UniswapV3TwapAdapter(
            address(pool), base_, quote_,
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    function test_Constructor_RecordsOrderingAndDecimals() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        assertEq(a.base(), address(nvda));
        assertEq(a.quote(), address(usdg));
        assertFalse(a.baseIsToken0(), "NVDA is token1 in this pool");
        assertEq(a.baseDecimals(), 18);
        assertEq(a.quoteDecimals(), 6);
        assertEq(a.decimals(), 8);
        assertEq(a.twapWindow(), WINDOW);
        assertEq(a.minCardinality(), MIN_CARDINALITY);
        assertEq(a.minLiquidity(), MIN_LIQUIDITY);
        assertEq(a.maxObservationAge(), MAX_OBS_AGE);
        assertEq(a.maxSpotDivergenceBps(), MAX_DIVERGENCE_BPS);
    }

    /// The reversed pool, so the other branch of the ordering check is covered.
    function test_Constructor_AcceptsBaseAsToken0() public {
        MockUniswapV3Pool flipped = new MockUniswapV3Pool(address(nvda), address(usdg));
        UniswapV3TwapAdapter a = new UniswapV3TwapAdapter(
            address(flipped), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
        assertTrue(a.baseIsToken0());
    }

    /// WHAT THE ORDERING ASSERTION DOES AND DOES NOT PROMISE.
    ///
    /// Naming the pair the other way round is LEGAL and does not revert: it
    /// means "the price of USDG in NVDA", a real quantity, and the flag flips
    /// to match. What the constructor guarantees is narrower and more useful --
    /// that the ARITHMETIC BRANCH always matches the pool's real token order,
    /// so the adapter can never compute a reciprocal by accident. That is the
    /// bug this class of contract actually ships: 0.0043 where 231.35 belongs.
    ///
    /// A deployer who meant NVDA-in-USDG and typed the arguments backwards is
    /// NOT caught here, because both orderings describe a real pair. That is
    /// caught by the deploy script in Task 8 reading the answer back and
    /// printing `baseIsToken0` and `assetToCash(1e18)` before anyone signs.
    function test_Constructor_ReversingTheDirectionFlipsTheFlagRatherThanReverting() public {
        UniswapV3TwapAdapter forward = _deploy(address(nvda), address(usdg));
        UniswapV3TwapAdapter reverse = _deploy(address(usdg), address(nvda));

        assertFalse(forward.baseIsToken0(), "NVDA priced in USDG");
        assertTrue(reverse.baseIsToken0(), "USDG priced in NVDA");
        assertEq(forward.base(), reverse.quote());
        assertEq(forward.quote(), reverse.base());
    }

    function test_Constructor_RevertsWhenATokenIsNotInThePool() public {
        MockERC20 spy = new MockERC20("SPY", "SPY", 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.PoolTokenMismatch.selector, address(usdg), address(nvda)
            )
        );
        _deploy(address(spy), address(usdg));
    }

    function test_Constructor_RevertsOnZeroWindow() public {
        vm.expectRevert(bytes("zero window"));
        new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            0, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    function test_Constructor_RevertsOnZeroPool() public {
        vm.expectRevert(bytes("zero addr"));
        new UniswapV3TwapAdapter(
            address(0), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    function test_Constructor_RevertsOnZeroBase() public {
        vm.expectRevert(bytes("zero addr"));
        _deploy(address(0), address(usdg));
    }

    function test_Constructor_RevertsOnZeroQuote() public {
        vm.expectRevert(bytes("zero addr"));
        _deploy(address(nvda), address(0));
    }

    function test_Constructor_RevertsOnTheSameTokenTwice() public {
        vm.expectRevert(bytes("same token"));
        _deploy(address(nvda), address(nvda));
    }

    /// Zero would reject every observation, including one written in this very
    /// block, so the adapter would never answer at all.
    function test_Constructor_RevertsOnZeroMaxObservationAge() public {
        vm.expectRevert(bytes("zero max age"));
        new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, 0, MAX_DIVERGENCE_BPS
        );
    }

    function test_Constructor_RevertsOnBadDivergenceBps() public {
        vm.expectRevert(bytes("bad bps"));
        new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, 0
        );
    }
}
```

`test/mocks/MockERC20.sol` already exists with exactly this constructor —
`(string memory name_, string memory symbol_, uint8 decimals_)` and a `decimals()` override —
so it is reused rather than duplicated.

- [ ] **Step 2: Run it and confirm it fails**

```bash
forge test --match-path 'test/oracle/UniswapV3TwapAdapterUnit.t.sol' -vv
```

Expected: compilation failure, `Source "src/oracle/UniswapV3TwapAdapter.sol" not found`.

- [ ] **Step 3: Write the mock pool**

Create `test/mocks/MockUniswapV3Pool.sol`. Beyond the listing below it needs three things
Task 5 depends on, and which are easiest to build now:

- `setObservationAgeAt(uint256 index, uint32 age)` — a per-slot age override, falling back to
  the global `observationAge`. **Without this, `observations()` serves every slot the same
  value, an off-by-one in `(index + 1) % cardinality` returns the right answer for the wrong
  reason, and Task 5's buffer-depth test passes vacuously.**
- `setObservationUninitialized(uint256 index, bool)` — so the unfilled-ring fallback path is
  reachable.
- `setCumulativeSeries(int56[] calldata)` — return these cumulatives verbatim from `observe`
  instead of interpolating between two endpoints, so a test can make the price MOVE across
  the span. Interpolation alone cannot reveal a reversed series, because every point is equal.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A Uniswap V3 pool with every quantity the adapter guards on made
///         settable, so each guard can be triggered on its own.
///
///         A fork test cannot do this. The live pool is deep, busy and
///         well-observed, which is the whole reason it was chosen -- so on a
///         fork the liquidity, cardinality and age guards are permanently
///         satisfied and permanently untested. This mock is where those three
///         are actually exercised; the fork test proves the happy path against
///         a real pool.
contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;

    int24 public tick;
    uint128 public liquidity = 50e18;
    uint16 public cardinality = 6000;
    uint16 public observationIndex = 1;
    uint32 public observationAge;
    bool public observeReverts;

    int56 private olderCumulative;
    int56 private newerCumulative;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setTick(int24 t) external { tick = t; }
    function setLiquidity(uint128 l) external { liquidity = l; }
    function setCardinality(uint16 c) external { cardinality = c; }
    function setObservationAge(uint32 a) external { observationAge = a; }
    function setObserveReverts(bool r) external { observeReverts = r; }

    /// @notice Set the two tick cumulatives `observe` will return, oldest first.
    function setTickCumulatives(int56 older, int56 newer) external {
        olderCumulative = older;
        newerCumulative = newer;
    }

    /// @notice Set both cumulatives so the mean tick over `window` is exactly `meanTick`.
    function setMeanTick(int24 meanTick, uint32 window) external {
        olderCumulative = 0;
        newerCumulative = int56(meanTick) * int56(uint56(window));
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        // sqrtPriceX96 is returned as zero: the adapter derives spot from the
        // TICK, never from this field, and returning a plausible-looking value
        // here would hide it if that ever changed.
        return (0, tick, observationIndex, cardinality, cardinality, 0, true);
    }

    function observations(uint256)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityX128, bool initialized)
    {
        return (uint32(block.timestamp) - observationAge, newerCumulative, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityX128s)
    {
        if (observeReverts) revert("OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityX128s = new uint160[](secondsAgos.length);
        // secondsAgos arrives oldest-first, so index 0 takes the older cumulative
        // and the last takes the newer one. Intermediate points interpolate
        // linearly between them, which is what a constant tick produces.
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            if (i == 0) tickCumulatives[i] = olderCumulative;
            else if (i == secondsAgos.length - 1) tickCumulatives[i] = newerCumulative;
            else {
                int56 span = newerCumulative - olderCumulative;
                tickCumulatives[i] = olderCumulative + (span * int56(uint56(i))) / int56(uint56(secondsAgos.length - 1));
            }
        }
    }
}
```

- [ ] **Step 4: Write the adapter's interface and constructor**

Create `src/oracle/UniswapV3TwapAdapter.sol`. Only the parts the tests above touch; the
next tasks fill in `latestRoundData`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AggregatorV3Interface} from "./MedianOracle.sol";
import {TickMath} from "../lib/TickMath.sol";

/// @notice The slice of the Uniswap V3 pool this adapter reads. Declared here
///         rather than imported for the same reason TickMath is vendored:
///         v3-core does not compile under 0.8.x.
interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}

/// @title UniswapV3TwapAdapter
/// @notice A Chainlink-shaped price feed with no off-chain component: the
///         answer is a time-weighted average of the pool's own tick history.
///
///         WHY THIS AND NOT AN ORACLE
///
///         Robinhood Chain carries no price feed, and the vaults that need one
///         were left off mainnet rather than staffed with a keeper holding a
///         live signing key forever. This removes the need instead of meeting
///         it.
///
///         The property that makes it BETTER than a feed here, rather than a
///         substitute for one: NAV reads the same pool the trades clear
///         against. A price move that fools the vault's accounting also gives
///         the attacker a bad fill, so the two halves of the classic oracle
///         exploit become the same action and cancel. That is only available
///         because these equities trade on-chain with eight figures of depth --
///         measured 6 September 2026, the NVDA/USDG 0.05% pool moved 0.66% on a
///         one-million-dollar single trade, decaying the moment it stopped.
///
///         WHAT IT DELIBERATELY DOES NOT HAVE
///
///         `maxStaleness()`. `OracleWindow.requireNotTighterThan` probes for it
///         by staticcall and treats its absence as "not one of ours, invariant
///         unenforceable" -- the same branch a real Chainlink feed takes. That
///         classification is correct: the bug that library exists to prevent is
///         a property of multi-reporter median freshness, and a TWAP has no
///         reporters. Adding the getter here would enforce an invariant that
///         does not apply, so it is absent on purpose. Do not add it.
contract UniswapV3TwapAdapter is AggregatorV3Interface {
    /// @dev Chainlink convention, and what `RWRotationVault` documents.
    uint8 private constant ANSWER_DECIMALS = 8;
    uint256 private constant ANSWER_SCALE = 1e8;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant BPS = 10000;

    IUniswapV3PoolMinimal public immutable pool;
    address public immutable base;
    address public immutable quote;
    /// @notice True when `base` is the pool's token0. Fixed at construction by
    ///         comparison against the pool, never taken on the deployer's word.
    bool public immutable baseIsToken0;
    uint8 public immutable baseDecimals;
    uint8 public immutable quoteDecimals;

    uint32 public immutable twapWindow;
    uint16 public immutable minCardinality;
    uint128 public immutable minLiquidity;
    uint32 public immutable maxObservationAge;
    uint16 public immutable maxSpotDivergenceBps;

    error PoolTokenMismatch(address token0, address token1);

    constructor(
        address pool_,
        address base_,
        address quote_,
        uint32 twapWindow_,
        uint16 minCardinality_,
        uint128 minLiquidity_,
        uint32 maxObservationAge_,
        uint16 maxSpotDivergenceBps_
    ) {
        require(pool_ != address(0) && base_ != address(0) && quote_ != address(0), "zero addr");
        require(base_ != quote_, "same token");
        require(twapWindow_ > 0, "zero window");
        require(maxObservationAge_ > 0, "zero max age");
        require(maxSpotDivergenceBps_ > 0 && maxSpotDivergenceBps_ <= BPS, "bad bps");

        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool_);
        address t0 = p.token0();
        address t1 = p.token1();

        // The one check that cannot be skipped. Passing base and quote the wrong
        // way round produces a reciprocal price -- 0.0043 where 231.35 belongs --
        // which is a plausible-looking number that would price every rebalance
        // wrongly and revert nothing. Compare against the pool in ORDER, and
        // refuse anything else.
        bool isToken0;
        if (base_ == t0 && quote_ == t1) isToken0 = true;
        else if (base_ == t1 && quote_ == t0) isToken0 = false;
        else revert PoolTokenMismatch(t0, t1);
        baseIsToken0 = isToken0;

        pool = p;
        base = base_;
        quote = quote_;
        baseDecimals = IERC20Metadata(base_).decimals();
        quoteDecimals = IERC20Metadata(quote_).decimals();

        twapWindow = twapWindow_;
        minCardinality = minCardinality_;
        minLiquidity = minLiquidity_;
        maxObservationAge = maxObservationAge_;
        maxSpotDivergenceBps = maxSpotDivergenceBps_;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure returns (uint8) {
        return ANSWER_DECIMALS;
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("not implemented");
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

```bash
forge test --match-path 'test/oracle/UniswapV3TwapAdapterUnit.t.sol' -vv
```

Expected: **13 passing**. Then `forge test` for the running total: **357 passed, 0 failed,
34 skipped, 391 total**.

The placeholder `latestRoundData` is `pure`, not `view`: a body that is only a revert reads
nothing, and solc warns if it is declared `view`. It relaxes to `view` in Task 3, which the
interface permits either way.

- [ ] **Step 6: Commit**

```bash
git add sidequest-protocol/contracts/src/oracle/UniswapV3TwapAdapter.sol \
        sidequest-protocol/contracts/test/mocks/MockUniswapV3Pool.sol \
        sidequest-protocol/contracts/test/oracle/UniswapV3TwapAdapterUnit.t.sol
git commit -m "feat(oracle): TWAP adapter constructor asserts pool token ordering"
```

---

## Task 3: The price arithmetic and the TWAP read

**Files:**
- Modify: `sidequest-protocol/contracts/src/oracle/UniswapV3TwapAdapter.sol`
- Test: `sidequest-protocol/contracts/test/oracle/UniswapV3TwapAdapterUnit.t.sol` (append)

**Interfaces:**
- Consumes: `TickMath.getSqrtRatioAtTick`, `Math.mulDiv`, `IUniswapV3PoolMinimal.observe`.
- Produces:
  - `function answerAtTick(int24 tick) public view returns (uint256)` — public so tests and
    the fork test can compare against an independently computed value
  - `function meanTick() public view returns (int24)`
  - a working `latestRoundData()` returning `(1, answer, block.timestamp, block.timestamp, 1)`
    (guards arrive in Task 4)
  - `error InvalidAnswer(uint256 answer)`

- [ ] **Step 1: Write the failing test**

Append to `test/oracle/UniswapV3TwapAdapterUnit.t.sol`:

```solidity
    // --- price arithmetic ---------------------------------------------------

    /// The worked example from the spec, to the unit. VERIFIED: the contract
    /// returns exactly this, so assert equality rather than approximation --
    /// an approximate assertion lets the arithmetic drift and still agree with
    /// itself, which is the whole failure mode worth guarding.
    ///
    /// NOTE FOR TASK 6. Reading the live pool's slot0 gives
    /// sqrtPriceX96 = 5209002981863638722623952383317079, which works out to
    /// 23,133,958,672 -- 0.0044% BELOW this number. Both are correct and they
    /// answer different questions: a pool's price sits somewhere INSIDE a tick,
    /// while `getSqrtRatioAtTick` returns that tick's lower boundary. The gap is
    /// bounded by one tick, which is one basis point. Do not "fix" either one to
    /// match the other.
    function test_AnswerAtTick_MatchesTheWorkedExample() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        assertEq(a.answerAtTick(221882), 23134970771, "USDG per NVDA at 1e8");
    }

    /// Decimal scaling, isolated from the tick maths entirely.
    ///
    /// At tick 0 the sqrt ratio is exactly 2^96, so the raw ratio is exactly 1
    /// and every digit of the answer comes from the decimal adjustment. A bug
    /// in the 18/6/8 handling shows up here as a clean power of ten rather than
    /// as a plausible price.
    function test_AnswerAtTick_DecimalScalingAtUnityRatio() public {
        // One NVDA-wei buys one USDG-microunit, so one whole NVDA (1e18 wei)
        // buys 1e18 microunits = 1e12 USDG. At 1e8: 1e20.
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        assertEq(a.answerAtTick(0), 1e20, "18dp base against 6dp quote");

        // The inverse: one whole USDG buys 1e-12 NVDA, which at 1e8 rounds to
        // ZERO. Arithmetically right, and precisely why latestRoundData carries
        // a sanity guard instead of assuming a positive answer falls out.
        UniswapV3TwapAdapter b = _deploy(address(usdg), address(nvda));
        assertEq(b.answerAtTick(0), 0, "6dp base against 18dp quote underflows 1e8");
    }

    function test_AnswerAtTick_MatchedDecimalsNeedNoAdjustment() public {
        MockERC20 a18 = new MockERC20("A", "A", 18);
        MockERC20 b18 = new MockERC20("B", "B", 18);
        MockUniswapV3Pool p = new MockUniswapV3Pool(address(a18), address(b18));
        UniswapV3TwapAdapter a = new UniswapV3TwapAdapter(
            address(p), address(b18), address(a18),
            WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
        assertEq(a.answerAtTick(0), 1e8, "matched decimals at unity ratio");
    }

    /// Flipping which token is base must invert the answer, not change it by a
    /// decimal factor. This is the test that catches a decimals bug that a
    /// single-direction test would pass.
    function test_AnswerAtTick_IsReciprocalWhenBaseAndQuoteSwap() public {
        UniswapV3TwapAdapter nvdaInUsdg = _deploy(address(nvda), address(usdg));
        UniswapV3TwapAdapter usdgInNvda = _deploy(address(usdg), address(nvda));

        uint256 forward = nvdaInUsdg.answerAtTick(221882);   // ~231.35e8
        uint256 backward = usdgInNvda.answerAtTick(221882);  // ~0.00432246e8

        // forward * backward should be 1e16, i.e. (1e8)^2.
        assertApproxEqRel(forward * backward, 1e16, 1e13);
    }

    function test_MeanTick_AveragesTheCumulatives() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setMeanTick(221882, WINDOW);
        assertEq(a.meanTick(), int24(221882));
    }

    function _shortWindow() internal returns (UniswapV3TwapAdapter) {
        return new UniswapV3TwapAdapter(
            address(pool), address(nvda), address(usdg),
            2, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    /// Solidity truncates integer division toward zero; Uniswap's OracleLibrary
    /// floors. They differ only for a NEGATIVE delta with a remainder, and one
    /// tick is one basis point -- but it is a one-sided bias on falling prices,
    /// so all three cases are pinned rather than just the interesting one.
    /// delta = -5 over a window of 2 is -2.5: truncation gives -2, floor -3.
    function test_MeanTick_FloorsNegativeDeltas() public {
        UniswapV3TwapAdapter a = _shortWindow();
        pool.setTickCumulatives(int56(0), int56(-5));
        assertEq(a.meanTick(), int24(-3), "must floor, not truncate");
    }

    /// Must NOT adjust a positive delta, where truncation already floors.
    function test_MeanTick_LeavesPositiveDeltasAlone() public {
        UniswapV3TwapAdapter a = _shortWindow();
        pool.setTickCumulatives(int56(0), int56(5));
        assertEq(a.meanTick(), int24(2), "floor(2.5) is 2");
    }

    /// An exact negative division has no remainder, so no adjustment either.
    function test_MeanTick_ExactNegativeDivisionIsNotAdjusted() public {
        UniswapV3TwapAdapter a = _shortWindow();
        pool.setTickCumulatives(int56(0), int56(-6));
        assertEq(a.meanTick(), int24(-3), "floor(-3.0) is -3");
    }

    /// The answer must track the AVERAGE, not spot. "Reads a TWAP" is easy to
    /// write and easy to get wrong, so move spot and assert nothing happens.
    function test_LatestRoundData_ReportsTheAverageAndNotSpot() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setMeanTick(221882, WINDOW);

        pool.setTick(221882);
        (, int256 atMean, , , ) = a.latestRoundData();
        pool.setTick(221882 + 100); // 99.5 bps away, inside the tolerance
        (, int256 spotMoved, , , ) = a.latestRoundData();

        assertEq(spotMoved, atMean, "spot moved; the reported average must not");
    }

    function test_LatestRoundData_ReportsTheTwapAndTheCurrentTimestamp() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setTick(221882);
        pool.setMeanTick(221882, WINDOW);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
            = a.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertApproxEqRel(uint256(answer), 23134970771, 1e13);
    }

    /// The shape `SpotVaultMinimal._oraclePrice` checks: answeredInRound must
    /// not be below roundId, and updatedAt must not be zero.
    function test_LatestRoundData_SatisfiesTheVaultsFreshnessChecks() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setTick(221882);
        pool.setMeanTick(221882, WINDOW);
        (uint80 roundId, , , uint256 updatedAt, uint80 answeredInRound) = a.latestRoundData();
        assertGe(answeredInRound, roundId);
        assertGt(updatedAt, 0);
    }

    /// The invariant OracleWindow depends on. A contract with no fallback
    /// reverts on an unknown selector, so this staticcall must fail -- which is
    /// how `requireNotTighterThan` learns to take its no-op branch.
    function test_DoesNotImplementMaxStaleness() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        (bool ok, ) = address(a).staticcall(abi.encodeWithSignature("maxStaleness()"));
        assertFalse(ok, "the adapter must not answer maxStaleness()");
    }
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
forge test --match-path 'test/oracle/UniswapV3TwapAdapterUnit.t.sol' -vv
```

Expected: compilation failure on `answerAtTick` and `meanTick` being undefined.

- [ ] **Step 3: Implement**

In `src/oracle/UniswapV3TwapAdapter.sol`, add the error alongside `PoolTokenMismatch`:

```solidity
    error InvalidAnswer(uint256 answer);
```

then replace the placeholder `latestRoundData` with:

```solidity
    /// @notice The price of one whole `base` token in whole `quote` units, at
    ///         `ANSWER_DECIMALS`, for an arbitrary tick.
    ///
    ///         Public because the fork test compares it against a TWAP computed
    ///         independently from the pool's raw cumulatives, and because the
    ///         charting view and `latestRoundData` must demonstrably share one
    ///         implementation rather than two that agree today.
    ///
    ///         DIRECTION. `SpotVaultMinimal.assetToCash` is
    ///         `assetAmt * 10^cashDec * p / (10^assetDec * 10^priceDec)`, so `p`
    ///         is quote-per-base. A Uniswap tick expresses token1/token0 in RAW
    ///         units, so when base is token1 it is the reciprocal of what the
    ///         vault wants AND both decimal scalings apply. Worked at tick
    ///         221,882 with token0 = USDG (6dp), token1 = NVDA (18dp):
    ///
    ///             raw token1/token0     1.0001^221882    = 4.3225e9
    ///             NVDA per USDG         x 10^6 / 10^18   = 0.00432246
    ///             USDG per NVDA         reciprocal       = 231.35
    ///             answer at 1e8                          = 23,134,970,771
    ///
    ///         Neither branch forms `sqrtP * sqrtP` as a plain product: that
    ///         overflows uint256 above roughly tick 500,000. `Math.mulDiv`
    ///         carries the 512-bit intermediate instead.
    function answerAtTick(int24 tick) public view returns (uint256) {
        uint256 sqrtP = uint256(TickMath.getSqrtRatioAtTick(tick));
        uint256 baseUnit = 10 ** baseDecimals;
        uint256 quoteUnit = 10 ** quoteDecimals;

        if (baseIsToken0) {
            // raw token1/token0 is quote-raw per base-raw, so scale directly.
            uint256 ratioX96 = Math.mulDiv(sqrtP, sqrtP, Q96);
            return Math.mulDiv(ratioX96, baseUnit * ANSWER_SCALE, Q96 * quoteUnit);
        }
        // base is token1: invert first, then scale.
        uint256 inverseX96 = Math.mulDiv(Q96, Q96, sqrtP);
        return Math.mulDiv(inverseX96, baseUnit * ANSWER_SCALE, sqrtP * quoteUnit);
    }

    /// @notice The arithmetic mean tick over `twapWindow`, from the pool's own
    ///         observation history.
    function meanTick() public view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory cumulatives, ) = pool.observe(secondsAgos);
        int56 delta = cumulatives[1] - cumulatives[0];
        int56 window = int56(uint56(twapWindow));

        int24 mean = int24(delta / window);
        // Solidity truncates toward zero; Uniswap's OracleLibrary floors. They
        // differ only for a negative delta with a remainder. One tick is one
        // basis point of price, so this is small -- and matching the reference
        // implementation costs nothing.
        if (delta < 0 && (delta % window != 0)) mean--;
        return mean;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev `updatedAt` is `block.timestamp` because that is the truth: a TWAP
    ///      is computed at call time from history and is never stale in the
    ///      sense `MedianOracle.updatedAt` carries. The real staleness risk for
    ///      a TWAP is a pool nobody is trading, which `updatedAt` cannot express
    ///      and which the observation-age guard handles instead.
    ///
    ///      `roundId` and `answeredInRound` are both 1 so the vault's
    ///      `answeredInRound < roundId` check passes. There are no rounds here.
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        uint256 answer = answerAtTick(meanTick());
        if (answer == 0 || answer > uint256(type(int256).max)) revert InvalidAnswer(answer);
        return (1, int256(answer), block.timestamp, block.timestamp, 1);
    }
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
forge test --match-path 'test/oracle/UniswapV3TwapAdapterUnit.t.sol' -vv
```

Expected: **25 passing**. Then `forge test` for the running total: **369 passed, 0 failed,
34 skipped, 403 total**.

Note the constants `ANSWER_SCALE = 1e8` and `Q96 = 1 << 96` are needed from here on, as is
`error InvalidAnswer(uint256 answer)`. Add them beside `ANSWER_DECIMALS` and
`PoolTokenMismatch` if Task 2 left them out. `latestRoundData` also relaxes from `pure` back
to `view` now that it reads state.

- [ ] **Step 5: Confirm nothing else moved**

```bash
forge test
```

- [ ] **Step 6: Commit**

```bash
git add sidequest-protocol/contracts/src/oracle/UniswapV3TwapAdapter.sol \
        sidequest-protocol/contracts/test/oracle/UniswapV3TwapAdapterUnit.t.sol
git commit -m "feat(oracle): TWAP price arithmetic, quote per whole base at 1e8"
```

---

## Task 4: The five guards

Each guard must revert on its own trigger **and only on its own trigger** — a guard that
fires for a neighbour's reason sends an operator to fix the wrong thing.

**Files:**
- Modify: `sidequest-protocol/contracts/src/oracle/UniswapV3TwapAdapter.sol`
- Test: `sidequest-protocol/contracts/test/oracle/UniswapV3TwapAdapterUnit.t.sol` (append)

**Interfaces:**
- Consumes: everything from Task 3.
- Produces, all reverting from inside `latestRoundData`:
  - `error InsufficientCardinality(uint16 have, uint16 need)`
  - `error InsufficientLiquidity(uint128 have, uint128 need)`
  - `error ObservationTooOld(uint32 ageSeconds, uint32 maxAgeSeconds)`
  - `error SpotDivergesFromTwap(uint256 twapAnswer, uint256 spotAnswer, uint256 divergenceBps)`
  - `error InvalidAnswer(uint256 answer)` (already declared in Task 3)

- [ ] **Step 1: Write the failing test**

Append to `test/oracle/UniswapV3TwapAdapterUnit.t.sol`:

```solidity
    // --- guards -------------------------------------------------------------

    /// Puts the pool in a state where every guard is satisfied, so each test
    /// below breaks exactly one thing.
    function _healthy(UniswapV3TwapAdapter) internal {
        pool.setTick(221882);
        pool.setMeanTick(221882, WINDOW);
        pool.setLiquidity(50e18);
        pool.setCardinality(6000);
        pool.setObservationAge(60);
    }

    function test_Guard_AllHealthyDoesNotRevert() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0);
    }

    function test_Guard_CardinalityBelowMinimumReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setCardinality(299);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TwapAdapter.InsufficientCardinality.selector, uint16(299), MIN_CARDINALITY)
        );
        a.latestRoundData();
    }

    function test_Guard_CardinalityExactlyAtMinimumPasses() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setCardinality(300);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0);
    }

    function test_Guard_LiquidityBelowFloorReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setLiquidity(MIN_LIQUIDITY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.InsufficientLiquidity.selector, MIN_LIQUIDITY - 1, MIN_LIQUIDITY
            )
        );
        a.latestRoundData();
    }

    function test_Guard_LiquidityExactlyAtFloorPasses() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setLiquidity(MIN_LIQUIDITY);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0);
    }

    function test_Guard_ObservationOlderThanMaxAgeReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setObservationAge(MAX_OBS_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.ObservationTooOld.selector, MAX_OBS_AGE + 1, MAX_OBS_AGE
            )
        );
        a.latestRoundData();
    }

    function test_Guard_ObservationExactlyAtMaxAgePasses() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setObservationAge(MAX_OBS_AGE);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0);
    }

    /// Spot 3% above the TWAP: 300bps against a 200bps tolerance.
    /// 1.0001^300 = 1.0305, so a 300-tick gap is roughly 3%.
    function test_Guard_SpotAboveTwapByMoreThanToleranceReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        // Base is token1, so a HIGHER tick means a LOWER answer. Direction does
        // not matter to the guard, only the magnitude.
        pool.setTick(221882 + 300);
        vm.expectRevert();
        a.latestRoundData();
    }

    function test_Guard_SpotBelowTwapByMoreThanToleranceReverts() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setTick(221882 - 300);
        vm.expectRevert();
        a.latestRoundData();
    }

    /// 1.0001^100 = 1.01, i.e. 100bps, comfortably inside the 200bps tolerance.
    function test_Guard_SmallSpotDivergenceIsAllowed() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setTick(221882 + 100);
        (, int256 answer, , , ) = a.latestRoundData();
        assertGt(answer, 0);
    }

    /// The divergence guard must report the two answers it compared, so an
    /// operator reading the revert can see WHICH way the pool had moved rather
    /// than only that it had.
    function test_Guard_DivergenceRevertCarriesBothAnswers() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setTick(221882 + 300);
        uint256 twap = a.answerAtTick(221882);
        uint256 spot = a.answerAtTick(221882 + 300);
        uint256 diff = twap > spot ? twap - spot : spot - twap;
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapAdapter.SpotDivergesFromTwap.selector, twap, spot, (diff * 10000) / twap
            )
        );
        a.latestRoundData();
    }

    /// The guards run in a fixed order, and the order is load-bearing: a pool
    /// with no usable history makes `observe` revert with an opaque "OLD", so
    /// cardinality must be checked BEFORE anything calls observe.
    function test_Guard_CardinalityIsCheckedBeforeObserve() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy(a);
        pool.setCardinality(1);
        pool.setObserveReverts(true);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TwapAdapter.InsufficientCardinality.selector, uint16(1), MIN_CARDINALITY)
        );
        a.latestRoundData();
    }
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
forge test --match-path 'test/oracle/UniswapV3TwapAdapterUnit.t.sol' -vv
```

Expected: the cardinality, liquidity, age and divergence tests fail — the guards do not
exist yet, so `latestRoundData` returns an answer where a revert was expected.

- [ ] **Step 3: Implement**

Add the errors:

```solidity
    error InsufficientCardinality(uint16 have, uint16 need);
    error InsufficientLiquidity(uint128 have, uint128 need);
    error ObservationTooOld(uint32 ageSeconds, uint32 maxAgeSeconds);
    error SpotDivergesFromTwap(uint256 twapAnswer, uint256 spotAnswer, uint256 divergenceBps);
```

and replace `latestRoundData` with the guarded version:

```solidity
    /// @inheritdoc AggregatorV3Interface
    /// @dev Every guard reverts. A failure here stops a rebalance rather than
    ///      pricing one wrongly, which is the whole point: the vault's
    ///      `_oraclePrice` is the only path to `rebalanceTo`, so refusing to
    ///      answer is refusing to trade.
    ///
    ///      ORDER IS LOAD-BEARING. Cardinality comes first because a pool with
    ///      no usable history makes `observe` revert with a bare "OLD" that
    ///      names nothing an operator can act on. Checking it first turns that
    ///      into a typed error carrying both numbers.
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (, int24 spotTick, uint16 observationIndex, uint16 cardinality, , , ) = pool.slot0();

        // 1. History. A pool at cardinality 1 keeps a single observation and
        //    cannot answer a windowed query at all -- SPY/USDG 0.01% and
        //    ZOR/USDG both sit there today.
        if (cardinality < minCardinality) revert InsufficientCardinality(cardinality, minCardinality);

        // 2. Depth. This is what makes the TWAP expensive to move, so its
        //    draining away is the condition under which every other guarantee
        //    here weakens. Note `liquidity()` is IN-RANGE liquidity and moves as
        //    positions enter and leave range, so the floor is set well below the
        //    observed value rather than just under it.
        uint128 liq = pool.liquidity();
        if (liq < minLiquidity) revert InsufficientLiquidity(liq, minLiquidity);

        // 3. Activity. On a quiet pool `observe` extrapolates the last tick
        //    forward, so it returns a confident price nobody has traded at.
        //    The subtraction is unchecked because the pool stores timestamps
        //    truncated to uint32; wrapping subtraction is the correct arithmetic
        //    there and is what Uniswap itself does.
        (uint32 lastObservedAt, , , ) = pool.observations(observationIndex);
        uint32 age;
        unchecked { age = uint32(block.timestamp) - lastObservedAt; }
        if (age > maxObservationAge) revert ObservationTooOld(age, maxObservationAge);

        uint256 twapAnswer = answerAtTick(meanTick());
        uint256 spotAnswer = answerAtTick(spotTick);

        // 5, run before 4 because a zero denominator cannot be divided by.
        if (twapAnswer == 0 || twapAnswer > uint256(type(int256).max)) revert InvalidAnswer(twapAnswer);
        if (spotAnswer == 0) revert InvalidAnswer(spotAnswer);

        // 4. The important one, and a market-condition check as much as a
        //    manipulation check: a 2% gap between spot and a 30-minute average
        //    is a moment a fund should not be rebalancing, whatever the cause.
        uint256 diff = twapAnswer > spotAnswer ? twapAnswer - spotAnswer : spotAnswer - twapAnswer;
        uint256 divergenceBps = (diff * BPS) / twapAnswer;
        if (divergenceBps > maxSpotDivergenceBps) {
            revert SpotDivergesFromTwap(twapAnswer, spotAnswer, divergenceBps);
        }

        return (1, int256(twapAnswer), block.timestamp, block.timestamp, 1);
    }
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
forge test --match-path 'test/oracle/UniswapV3TwapAdapterUnit.t.sol' -vv
```

Expected: **42 passing**. Then `forge test`: **386 passed, 0 failed, 34 skipped, 420 total**.

- [ ] **Step 5: Confirm nothing else moved**

```bash
forge test
```

- [ ] **Step 6: Commit**

```bash
git add sidequest-protocol/contracts/src/oracle/UniswapV3TwapAdapter.sol \
        sidequest-protocol/contracts/test/oracle/UniswapV3TwapAdapterUnit.t.sol
git commit -m "feat(oracle): five reverting guards on the TWAP adapter"
```

---

## Task 5: The charting view

The terminal needs a price series. Reading it from the adapter rather than reimplementing
`TickMath` in TypeScript keeps one implementation of the arithmetic, and makes the chart and
NAV agree by construction rather than by coincidence.

Measured 6 September 2026: the pool's ring buffer holds observations reaching back roughly
55 hours, so a 24-hour chart is available from pool state alone — no indexer, no archive node.

**Files:**
- Modify: `sidequest-protocol/contracts/src/oracle/UniswapV3TwapAdapter.sol`
- Test: `sidequest-protocol/contracts/test/oracle/UniswapV3TwapAdapterUnit.t.sol` (append)

**Interfaces:**
- Consumes: `answerAtTick`, `pool.observe`, `pool.slot0`, `pool.observations`.
- Produces:
  - `function answersOverWindows(uint32[] calldata secondsAgos) external view returns (uint256[] memory answers)`
    — `secondsAgos` strictly decreasing and ending at 0; returns `secondsAgos.length - 1`
    answers, each the mean price over one interval. **Ungated on purpose.**
  - `function oldestObservationSecondsAgo() external view returns (uint32)`
  - `error BadWindowSeries()`

- [ ] **Step 1: Write the failing test**

Append to `test/oracle/UniswapV3TwapAdapterUnit.t.sol`:

```solidity
    // --- charting -----------------------------------------------------------

    function test_AnswersOverWindows_ReturnsOneAnswerPerInterval() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setMeanTick(221882, 3600);

        uint32[] memory agos = new uint32[](4);
        agos[0] = 3600; agos[1] = 2400; agos[2] = 1200; agos[3] = 0;

        uint256[] memory answers = a.answersOverWindows(agos);
        assertEq(answers.length, 3);
        // A constant tick across the whole span means three equal answers.
        assertApproxEqRel(answers[0], 23134970771, 1e13);
        assertApproxEqRel(answers[1], answers[0], 1e13);
        assertApproxEqRel(answers[2], answers[0], 1e13);
    }

    function test_AnswersOverWindows_RejectsANonDecreasingSeries() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        uint32[] memory agos = new uint32[](3);
        agos[0] = 1200; agos[1] = 2400; agos[2] = 0; // not decreasing
        vm.expectRevert(UniswapV3TwapAdapter.BadWindowSeries.selector);
        a.answersOverWindows(agos);
    }

    function test_AnswersOverWindows_RejectsASeriesNotEndingAtZero() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        uint32[] memory agos = new uint32[](2);
        agos[0] = 2400; agos[1] = 60;
        vm.expectRevert(UniswapV3TwapAdapter.BadWindowSeries.selector);
        a.answersOverWindows(agos);
    }

    function test_AnswersOverWindows_RejectsFewerThanTwoPoints() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        uint32[] memory agos = new uint32[](1);
        agos[0] = 0;
        vm.expectRevert(UniswapV3TwapAdapter.BadWindowSeries.selector);
        a.answersOverWindows(agos);
    }

    /// A chart is not NAV. This view must keep answering while the guards are
    /// refusing, or the terminal goes blank in exactly the conditions a manager
    /// most needs to see the price.
    function test_AnswersOverWindows_IsNotGuarded() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setMeanTick(221882, 3600);
        pool.setLiquidity(1);
        pool.setCardinality(1);
        pool.setObservationAge(MAX_OBS_AGE * 10);

        uint32[] memory agos = new uint32[](2);
        agos[0] = 3600; agos[1] = 0;
        uint256[] memory answers = a.answersOverWindows(agos);
        assertGt(answers[0], 0);
    }

    /// THE SERIES MUST NOT COME BACK MIRRORED.
    ///
    /// `secondsAgos` runs oldest-first, so answers[0] is the OLDEST interval.
    /// Reverse that and the chart renders back to front -- a bug no
    /// constant-price fixture can reveal, because every point is identical. So
    /// the ticks move across the span here. Base is token1, so a rising TICK is
    /// a FALLING price, which pins the ordering and the inversion together.
    function test_AnswersOverWindows_IsOrderedOldestFirst() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));

        int56[] memory cum = new int56[](4);
        cum[0] = 0;
        cum[1] = cum[0] + int56(221000) * 1200;
        cum[2] = cum[1] + int56(221882) * 1200;
        cum[3] = cum[2] + int56(222500) * 1200;
        pool.setCumulativeSeries(cum);

        uint32[] memory agos = new uint32[](4);
        agos[0] = 3600; agos[1] = 2400; agos[2] = 1200; agos[3] = 0;
        uint256[] memory answers = a.answersOverWindows(agos);

        assertEq(answers[1], 23134970771, "middle interval is the known tick");
        assertGt(answers[0], answers[1], "oldest interval had the lowest tick");
        assertGt(answers[1], answers[2], "newest interval had the highest tick");
    }

    /// Equal neighbours are a zero-length interval, so a division by zero
    /// rather than a validation error.
    function test_AnswersOverWindows_RejectsARepeatedEntry() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        uint32[] memory agos = new uint32[](3);
        agos[0] = 1200; agos[1] = 1200; agos[2] = 0;
        vm.expectRevert(UniswapV3TwapAdapter.BadWindowSeries.selector);
        a.answersOverWindows(agos);
    }

    /// The chart and NAV must be the same arithmetic, not two that agree today.
    function test_AnswersOverWindows_AgreesWithLatestRoundData() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        _healthy();
        uint32[] memory agos = new uint32[](2);
        agos[0] = WINDOW; agos[1] = 0;
        (, int256 nav, , , ) = a.latestRoundData();
        assertEq(a.answersOverWindows(agos)[0], uint256(nav), "same window, same number");
    }

    // The oldest slot is the one AFTER the newest, because the ring overwrites
    // forward. These three need the per-slot mock support from Task 2: on a
    // uniform ring an off-by-one returns the right answer for the wrong reason.

    function test_OldestObservationSecondsAgo_ReadsTheSlotAfterTheNewest() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setCardinality(6000);
        pool.setObservationIndex(1);
        pool.setObservationAgeAt(1, 60);        // newest
        pool.setObservationAgeAt(2, 198438);    // oldest, ~55 hours
        assertEq(a.oldestObservationSecondsAgo(), 198438, "must read index + 1");
    }

    function test_OldestObservationSecondsAgo_WrapsAtTheEndOfTheRing() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setCardinality(300);
        pool.setObservationIndex(299);
        pool.setObservationAgeAt(299, 30);
        pool.setObservationAgeAt(0, 7200);
        assertEq(a.oldestObservationSecondsAgo(), 7200, "must wrap to slot 0");
    }

    /// An unfilled ring has nothing at `index + 1`. Uniswap leaves those slots
    /// uninitialised, and their zero timestamp reads as a buffer stretching
    /// back to 1970. Slot 0 is written at pool creation, so it is the fallback.
    function test_OldestObservationSecondsAgo_FallsBackWhenTheRingIsUnfilled() public {
        UniswapV3TwapAdapter a = _deploy(address(nvda), address(usdg));
        pool.setCardinality(6000);
        pool.setObservationIndex(3);
        pool.setObservationAgeAt(4, 0);
        pool.setObservationUninitialized(4, true);
        pool.setObservationAgeAt(0, 3600);
        assertEq(a.oldestObservationSecondsAgo(), 3600, "uninitialised slot must not be trusted");
    }
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
forge test --match-path 'test/oracle/UniswapV3TwapAdapterUnit.t.sol' -vv
```

Expected: compilation failure on `answersOverWindows` and `oldestObservationSecondsAgo`.

- [ ] **Step 3: Implement**

Add the error and the two views:

```solidity
    error BadWindowSeries();

    /// @notice The price over each of a series of consecutive intervals, for
    ///         charting.
    ///
    ///         DELIBERATELY UNGUARDED. None of the five checks in
    ///         `latestRoundData` runs here, and that is the point: a chart is
    ///         not NAV. A manager whose vault has just refused to rebalance
    ///         because spot diverged from the average is exactly the person who
    ///         needs to see the price, and a guarded view would go blank at that
    ///         moment. Nothing that moves funds may call this.
    ///
    ///         Reading the series from the adapter rather than recomputing tick
    ///         maths in the browser means the chart and the vault's own NAV
    ///         cannot disagree: there is one implementation of the arithmetic.
    ///
    /// @param secondsAgos Strictly decreasing, ending at 0, at least two entries.
    /// @return answers One per adjacent pair, `secondsAgos.length - 1` of them,
    ///         oldest interval first.
    function answersOverWindows(uint32[] calldata secondsAgos)
        external
        view
        returns (uint256[] memory answers)
    {
        uint256 n = secondsAgos.length;
        if (n < 2) revert BadWindowSeries();
        if (secondsAgos[n - 1] != 0) revert BadWindowSeries();
        for (uint256 i = 1; i < n; i++) {
            if (secondsAgos[i] >= secondsAgos[i - 1]) revert BadWindowSeries();
        }

        (int56[] memory cumulatives, ) = pool.observe(secondsAgos);

        answers = new uint256[](n - 1);
        for (uint256 i = 0; i < n - 1; i++) {
            int56 span = int56(uint56(secondsAgos[i] - secondsAgos[i + 1]));
            int56 delta = cumulatives[i + 1] - cumulatives[i];
            int24 mean = int24(delta / span);
            if (delta < 0 && (delta % span != 0)) mean--;
            answers[i] = answerAtTick(mean);
        }
    }

    /// @notice How far back the pool's observation ring buffer reaches.
    ///
    ///         `observe` reverts with a bare "OLD" for any `secondsAgo` beyond
    ///         this, so a caller building a chart must clamp its horizon to the
    ///         value returned here rather than guessing and retrying.
    function oldestObservationSecondsAgo() external view returns (uint32) {
        (, , uint16 index, uint16 cardinality, , , ) = pool.slot0();
        uint256 oldestIndex = cardinality == 0 ? 0 : (uint256(index) + 1) % uint256(cardinality);
        (uint32 ts, , , bool initialized) = pool.observations(oldestIndex);
        // An unfilled buffer wraps to slot 0, which is always initialised.
        if (!initialized) (ts, , , ) = pool.observations(0);
        unchecked { return uint32(block.timestamp) - ts; }
    }
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
forge test --match-path 'test/oracle/UniswapV3TwapAdapterUnit.t.sol' -vv
```

Expected: **53 passing**. Then `forge test`: **397 passed, 0 failed, 34 skipped, 431 total**.
The adapter is complete after this task; Tasks 6 and 7 add no contract code.

- [ ] **Step 5: Confirm nothing else moved, and check the contract size**

```bash
forge test
forge build --sizes 2>&1 | grep -i twap
```

Expected: all green. Measured runtime size **5,824 bytes**, far under the 24,576 limit.

- [ ] **Step 6: Commit**

```bash
git add sidequest-protocol/contracts/src/oracle/UniswapV3TwapAdapter.sol \
        sidequest-protocol/contracts/test/oracle/UniswapV3TwapAdapterUnit.t.sol
git commit -m "feat(oracle): ungated price-series view for the terminal chart"
```

---

## Task 6: The adapter against the real pool

Everything so far ran against a mock. This is the first contact with the pool the money will
actually trade in.

**Files:**
- Create: `sidequest-protocol/contracts/test/fork/StockVaultMainnet.t.sol`

**Interfaces:**
- Consumes: `UniswapV3TwapAdapter`, `IUniswapV3PoolMinimal`, `TickMath`.
- Produces: nothing consumed by later tasks; Task 7 appends to this same file.

- [ ] **Step 1: Write the failing test**

Create `test/fork/StockVaultMainnet.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapV3TwapAdapter, IUniswapV3PoolMinimal} from "../../src/oracle/UniswapV3TwapAdapter.sol";
import {SpotVaultMinimal} from "../../src/vaults/SpotVaultMinimal.sol";
import {RobinhoodChainRouterAdapter} from "../../src/adapters/RobinhoodChainRouterAdapter.sol";

/// @notice The oracle-free stock vault, against the pool it will actually use.
///
///         Runs at HEAD, not at a pinned block, because the public RPC prunes
///         archive state -- a call one block behind the tip returns
///         "metadata is not found". So nothing here asserts a hardcoded price:
///         every expected value is derived from the same live state the
///         contract reads, which is the discipline SpotRebalanceMainnet.t.sol
///         already follows.
///
///         Opt-in. Run with:
///           RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///           forge test --match-path 'test/fork/StockVaultMainnet.t.sol' -vv
contract StockVaultMainnetForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // token0, 6dp
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // token1, 18dp
    address constant POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05%
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    uint24 constant FEE = 500;

    uint32 constant TWAP_WINDOW = 1800;
    uint16 constant MIN_CARDINALITY = 300;
    uint128 constant MIN_LIQUIDITY = 12e18;
    uint32 constant MAX_OBS_AGE = 4 hours;
    uint16 constant MAX_DIVERGENCE_BPS = 200;

    uint256 constant ONE_USDG = 1e6;

    UniswapV3TwapAdapter adapter;
    IUniswapV3PoolMinimal pool;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;

        pool = IUniswapV3PoolMinimal(POOL);
        adapter = new UniswapV3TwapAdapter(
            POOL, NVDA, USDG,
            TWAP_WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
        );
    }

    /// The pool's shape, so a change on chain fails here rather than somewhere
    /// downstream where the cause is unrecognisable.
    function test_PoolIsShapedAsTheSpecAssumes() public {
        if (!forked) { vm.skip(true); }
        assertEq(pool.token0(), USDG, "token0 must be USDG");
        assertEq(pool.token1(), NVDA, "token1 must be NVDA");
        assertFalse(adapter.baseIsToken0());
        assertEq(adapter.baseDecimals(), 18);
        assertEq(adapter.quoteDecimals(), 6);
    }

    /// The answer must match a TWAP computed independently from the pool's raw
    /// cumulatives -- not from the adapter's own meanTick, which would be the
    /// implementation checking itself.
    function test_AnswerMatchesAnIndependentlyComputedTwap() public {
        if (!forked) { vm.skip(true); }

        uint32[] memory agos = new uint32[](2);
        agos[0] = TWAP_WINDOW;
        agos[1] = 0;
        (int56[] memory cum, ) = pool.observe(agos);

        int56 delta = cum[1] - cum[0];
        int56 window = int56(uint56(TWAP_WINDOW));
        int24 expectedTick = int24(delta / window);
        if (delta < 0 && delta % window != 0) expectedTick--;

        assertEq(adapter.meanTick(), expectedTick, "mean tick");

        (, int256 answer, , , ) = adapter.latestRoundData();
        assertEq(uint256(answer), adapter.answerAtTick(expectedTick), "answer");

        console2.log("NVDA/USDG 30m TWAP at 1e8:", uint256(answer));
        assertGt(uint256(answer), 1e8, "under $1 is not a plausible NVDA price");
        assertLt(uint256(answer), 100000e8, "over $100,000 is not a plausible NVDA price");
    }

    /// The TWAP was measured as stable across two orders of magnitude of window
    /// (60s to 7200s moved it three cents). If that stops being true the window
    /// choice needs revisiting, so assert it rather than trusting the spec.
    function test_TwapIsStableAcrossWindowLengths() public {
        if (!forked) { vm.skip(true); }

        uint32[3] memory windows = [uint32(60), 1800, 7200];
        uint256 reference;
        for (uint256 i = 0; i < windows.length; i++) {
            UniswapV3TwapAdapter a = new UniswapV3TwapAdapter(
                POOL, NVDA, USDG,
                windows[i], MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBS_AGE, MAX_DIVERGENCE_BPS
            );
            (, int256 answer, , , ) = a.latestRoundData();
            console2.log("window", windows[i], "answer", uint256(answer));
            if (i == 0) reference = uint256(answer);
            else assertApproxEqRel(uint256(answer), reference, 2e16); // within 2%
        }
    }

    /// The four numeric guards must all be SATISFIED by the live pool, or the
    /// vault could never rebalance. Assert the headroom rather than assuming it.
    function test_LivePoolClearsEveryGuardWithHeadroom() public {
        if (!forked) { vm.skip(true); }

        (, , uint16 index, uint16 cardinality, , , ) = pool.slot0();
        uint128 liq = pool.liquidity();
        (uint32 lastObs, , , ) = pool.observations(index);
        uint32 age = uint32(block.timestamp) - lastObs;

        console2.log("cardinality", cardinality);
        console2.log("liquidity", liq);
        console2.log("newest observation age", age);
        console2.log("buffer reaches back", adapter.oldestObservationSecondsAgo());

        assertGe(cardinality, MIN_CARDINALITY, "cardinality below the floor");
        assertGe(liq, MIN_LIQUIDITY, "liquidity below the floor");
        assertLe(age, MAX_OBS_AGE, "newest observation older than the guard allows");

        // Not a guard, but the reason the chart in the terminal has anything to
        // draw. Recorded so a shrinking buffer is visible before it matters.
        assertGe(adapter.oldestObservationSecondsAgo(), 3600, "buffer shallower than one hour");
    }

    /// The `OracleWindow` no-op branch, exercised through the real constructor
    /// rather than asserted about it.
    function test_VaultConstructsAgainstTheAdapter() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = new SpotVaultMinimal(
            NVDA, USDG, address(adapter), 3600,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            100, 100, 1000,
            address(this), address(this), 0
        );

        assertEq(address(vault.oracle()), address(adapter));
        assertEq(vault.maxOracleStaleness(), 3600);
        // The vault read decimals() off the adapter at construction. If that had
        // come back as anything but 8, every conversion below would be wrong by
        // a power of ten.
        assertEq(vault.assetToCash(1e18), uint256(_answer()) / 100, "1 NVDA in USDG (6dp)");
    }

    /// A vault window TIGHTER than the adapter's TWAP window must ALSO be
    /// accepted, because the adapter has no maxStaleness() for OracleWindow to
    /// compare against. This is the branch the spec relies on.
    function test_VaultConstructsWithAWindowTighterThanTheTwap() public {
        if (!forked) { vm.skip(true); }
        SpotVaultMinimal vault = new SpotVaultMinimal(
            NVDA, USDG, address(adapter), 60, // 60s vault against an 1800s TWAP
            "Zorpha NVDA Long/Flat", "zqNVDA",
            100, 100, 1000,
            address(this), address(this), 0
        );
        assertEq(vault.maxOracleStaleness(), 60);
    }

    function _answer() internal view returns (int256 answer) {
        (, answer, , , ) = adapter.latestRoundData();
    }
}
```

Note the `assertEq(vault.assetToCash(1e18), uint256(_answer()) / 100, ...)` line: the answer
is at 1e8 and USDG has 6 decimals, so one whole NVDA in USDG units is the answer divided by
100. If that assertion is off by a power of ten, the decimals handling is wrong and this is
the test that says so.

- [ ] **Step 2: Run it and confirm it fails without a fork, then run it with one**

```bash
forge test --match-path 'test/fork/StockVaultMainnet.t.sol' -vv
```

Expected: all skipped (no `RH_MAINNET_RPC_URL`).

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path 'test/fork/StockVaultMainnet.t.sol' -vv
```

Expected: **7 passing**. If `test_LivePoolClearsEveryGuardWithHeadroom` fails on liquidity,
**stop and report** — the floor of 1.2e19 was set against 5.0993e19 measured 6 September and
in-range liquidity had already fallen to 2.7237e19 by that evening. A floor the live pool
cannot clear is a vault that can never rebalance, and that is a decision for the spec, not
for the implementer.

- [ ] **Step 3: There is no separate implementation step**

The contract is finished. This task is proof, not construction. If a test fails, fix the
contract and re-run both the fork suite and `forge test`.

- [ ] **Step 4: Confirm the unit suite still passes**

```bash
forge test
```

- [ ] **Step 5: Commit**

```bash
git add sidequest-protocol/contracts/test/fork/StockVaultMainnet.t.sol
git commit -m "test(fork): TWAP adapter against the live NVDA/USDG pool"
```

---

## Task 7: The round trip, and a simulated manipulation

**Files:**
- Modify: `sidequest-protocol/contracts/test/fork/StockVaultMainnet.t.sol` (append)

**Interfaces:**
- Consumes: everything from Task 6, plus `RobinhoodChainRouterAdapter` and `SpotVaultMinimal`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing test**

Append to `test/fork/StockVaultMainnet.t.sol`. Add a helper that builds a fully wired vault,
then the two tests:

```solidity
    // --- the whole vault ----------------------------------------------------

    address alice = address(0xA11CE);

    function _wiredVault() internal returns (SpotVaultMinimal vault) {
        vault = new SpotVaultMinimal(
            NVDA, USDG, address(adapter), 3600,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            100,   // rebalanceThresholdBps
            100,   // maxSlippageBps
            1000,  // performanceFeeBps
            address(this), address(this), 0
        );
        RobinhoodChainRouterAdapter swap =
            new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, NVDA, USDG, FEE, address(this));
        swap.grantRole(swap.VAULT_ROLE(), address(vault));
        vault.setSwapAdapter(address(swap));
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }

    /// Deposit, go fully long, come fully flat, redeem. The only value that may
    /// be lost is fees and slippage: two swaps at 0.05% plus impact, bounded by
    /// the 1% maxSlippageBps the vault enforces on each leg.
    function test_RoundTrip_DepositLongFlatRedeem() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = _wiredVault();

        // The vault is denominated in NVDA, so the depositor deposits NVDA.
        uint256 deposit = 1e18; // one whole NVDA
        deal(NVDA, alice, deposit);

        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), deposit);
        uint256 shares = vault.deposit(deposit, alice);
        vm.stopPrank();

        assertGt(shares, 0, "no shares minted");
        assertEq(vault.totalAssets(), deposit, "fresh vault should hold exactly the deposit");

        // Already fully long: the deposit arrived in NVDA. Go flat.
        vault.rebalanceTo(0);
        assertEq(vault.targetWeightBps(), 0);
        assertEq(vault.rebalanceCount(), 1, "flat move should have emitted a receipt");
        assertGt(IERC20(USDG).balanceOf(address(vault)), 0, "no cash leg after going flat");

        uint256 flatNav = vault.totalAssets();
        console2.log("NAV after going flat (NVDA units):", flatNav);

        // And back to fully long.
        vault.rebalanceTo(10000);
        assertEq(vault.targetWeightBps(), 10000);
        assertEq(vault.rebalanceCount(), 2);

        uint256 longNav = vault.totalAssets();
        console2.log("NAV after going long again:", longNav);

        // Two round-trip swaps at 0.05% each way plus impact, inside the 1%
        // slippage bound the vault enforced on each leg. 3% is a generous
        // ceiling that still fails loudly if a leg executed at a wrong price.
        assertApproxEqRel(longNav, deposit, 3e16);

        // The depositor can leave with what is left.
        vm.startPrank(alice);
        uint256 got = vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();
        assertApproxEqRel(got, deposit, 5e16);
        console2.log("redeemed:", got);
    }

    /// The claim that makes this design better than an oracle rather than a
    /// substitute for one: a price push large enough to matter is caught by the
    /// spot-vs-TWAP guard, and the rebalance refuses rather than pricing off a
    /// manipulated tick.
    function test_Manipulation_PushingSpotBlocksTheRebalance() public {
        if (!forked) { vm.skip(true); }

        SpotVaultMinimal vault = _wiredVault();

        uint256 deposit = 1e18;
        deal(NVDA, alice, deposit);
        vm.startPrank(alice);
        IERC20(NVDA).approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        // A rebalance is possible right now.
        vault.rebalanceTo(0);
        assertEq(vault.rebalanceCount(), 1);
        vault.rebalanceTo(10000);
        assertEq(vault.rebalanceCount(), 2);

        // Now shove spot with a large single trade through the same router the
        // vault uses. This moves slot0 and leaves the 30-minute average alone,
        // which is exactly the condition the divergence guard exists for.
        RobinhoodChainRouterAdapter attacker =
            new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, NVDA, USDG, FEE, address(this));
        attacker.grantRole(attacker.VAULT_ROLE(), address(this));

        uint256 push = 3_000_000 * ONE_USDG;
        deal(USDG, address(this), push);
        IERC20(USDG).approve(address(attacker), push);
        attacker.swap(USDG, NVDA, push, 1);

        (, int24 spotAfter, , , , , ) = pool.slot0();
        int24 meanAfter = adapter.meanTick();
        console2.log("spot tick after the push:", int256(spotAfter));
        console2.log("mean tick (unmoved):    ", int256(meanAfter));

        // The adapter now refuses, and because _oraclePrice is the only path to
        // a rebalance, so does the vault.
        vm.expectRevert();
        adapter.latestRoundData();

        vm.expectRevert();
        vault.rebalanceTo(0);
        assertEq(vault.rebalanceCount(), 2, "no receipt may be emitted while the guard is tripped");
    }

    /// And the chart keeps working while NAV refuses, which is the reason
    /// answersOverWindows is ungated.
    function test_Manipulation_ChartStillAnswersWhileNavRefuses() public {
        if (!forked) { vm.skip(true); }

        RobinhoodChainRouterAdapter attacker =
            new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, NVDA, USDG, FEE, address(this));
        attacker.grantRole(attacker.VAULT_ROLE(), address(this));
        uint256 push = 3_000_000 * ONE_USDG;
        deal(USDG, address(this), push);
        IERC20(USDG).approve(address(attacker), push);
        attacker.swap(USDG, NVDA, push, 1);

        vm.expectRevert();
        adapter.latestRoundData();

        uint32 horizon = adapter.oldestObservationSecondsAgo();
        if (horizon > 3600) horizon = 3600;
        uint32[] memory agos = new uint32[](3);
        agos[0] = horizon;
        agos[1] = horizon / 2;
        agos[2] = 0;
        uint256[] memory series = adapter.answersOverWindows(agos);
        assertEq(series.length, 2);
        assertGt(series[0], 0);
        assertGt(series[1], 0);
    }
```

- [ ] **Step 2: Run it against a fork**

```bash
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path 'test/fork/StockVaultMainnet.t.sol' -vv
```

Expected: 10 passing.

If `test_Manipulation_PushingSpotBlocksTheRebalance` does **not** revert, the $3M push was
not enough to move spot 200bps — the pool is deeper than it was on 6 September. Raise `push`
until the guard trips and record the figure it took in a comment; that number is the
measured cost of defeating this vault's price and is worth writing down.

- [ ] **Step 3: Confirm the unit suite still passes**

```bash
forge test
```

- [ ] **Step 4: Commit**

```bash
git add sidequest-protocol/contracts/test/fork/StockVaultMainnet.t.sol
git commit -m "test(fork): vault round trip, and a manipulation the guard refuses"
```

---

## Task 8: The deploy script

Three `CREATE`s from the deployer keystore, with **admin landing on the Safe** so no hot key
retains power for even one block, and the Safe can finish the setup atomically in Task 9.

**Files:**
- Create: `sidequest-protocol/contracts/script/DeployStockVault.s.sol`

**Interfaces:**
- Consumes: `UniswapV3TwapAdapter`, `SpotVaultMinimal`, `RobinhoodChainRouterAdapter`.
- Produces: three addresses printed to the console, consumed by hand in Tasks 9, 11 and 12.

- [ ] **Step 1: Write the script**

Create `script/DeployStockVault.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {UniswapV3TwapAdapter} from "../src/oracle/UniswapV3TwapAdapter.sol";
import {SpotVaultMinimal} from "../src/vaults/SpotVaultMinimal.sol";
import {RobinhoodChainRouterAdapter} from "../src/adapters/RobinhoodChainRouterAdapter.sol";

/// @notice Deploys the oracle-free NVDA long/flat vault on Robinhood Chain 4663.
///
///         WHY ADMIN LANDS ON THE SAFE AND NOT ON THE TIMELOCK
///
///         The end state is admin on the Timelock. Deploying straight to it
///         would mean the Timelock has to grant KEEPER_ROLE and set the swap
///         adapter, and every one of those is a 48-hour proposal -- three
///         separate ones, during which the vault exists on chain and cannot
///         trade. So the constructor hands DEFAULT_ADMIN to the SAFE, and the
///         Safe batch in safe-batches/I-stock-vault-roles.json does the roles,
///         the adapter wiring and the handover to the Timelock in ONE atomic
///         transaction that ends with the Safe renouncing its own admin.
///
///         The deployer key holds nothing at any point. It pays gas and signs
///         three CREATEs; it is never granted a role.
///
///         RUN
///           forge script script/DeployStockVault.s.sol:DeployStockVault \
///             --rpc-url https://rpc.mainnet.chain.robinhood.com \
///             --account mainnet-deploy \
///             --broadcast --slow
///
///         Never pass --password. Let cast prompt, so the passphrase stays out
///         of shell history.
contract DeployStockVault is Script {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // 18dp
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6dp
    address constant POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05%
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    uint24 constant FEE = 500;

    address constant SAFE = 0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4;
    address constant TREASURY = 0x3D9FE37DC0D08BeD0CD48c74Cb344064df9fB3C6;

    uint32 constant TWAP_WINDOW = 1800;
    uint16 constant MIN_CARDINALITY = 300;
    uint128 constant MIN_LIQUIDITY = 12e18;
    uint32 constant MAX_OBSERVATION_AGE = 4 hours;
    uint16 constant MAX_SPOT_DIVERGENCE_BPS = 200;

    uint256 constant MAX_ORACLE_STALENESS = 3600;
    uint16 constant REBALANCE_THRESHOLD_BPS = 100;
    uint16 constant MAX_SLIPPAGE_BPS = 100;
    uint256 constant PERFORMANCE_FEE_BPS = 1000;
    uint256 constant EMERGENCY_REDEEM_COOLDOWN = 0;

    function run() external {
        require(block.chainid == 4663, "wrong chain: this script is mainnet 4663 only");

        vm.startBroadcast();

        UniswapV3TwapAdapter oracle = new UniswapV3TwapAdapter(
            POOL, NVDA, USDG,
            TWAP_WINDOW, MIN_CARDINALITY, MIN_LIQUIDITY, MAX_OBSERVATION_AGE, MAX_SPOT_DIVERGENCE_BPS
        );

        SpotVaultMinimal vault = new SpotVaultMinimal(
            NVDA, USDG, address(oracle), MAX_ORACLE_STALENESS,
            "Zorpha NVDA Long/Flat", "zqNVDA",
            REBALANCE_THRESHOLD_BPS, MAX_SLIPPAGE_BPS, PERFORMANCE_FEE_BPS,
            TREASURY,  // feeRecipient, matching zsUSDG
            SAFE,      // admin, handed to the Timelock by the Safe batch
            EMERGENCY_REDEEM_COOLDOWN
        );

        // Its own swap adapter, admin on the Safe, so VAULT_ROLE can be granted
        // to the vault in the same batch that does everything else.
        RobinhoodChainRouterAdapter swap =
            new RobinhoodChainRouterAdapter(SWAP_ROUTER_02, NVDA, USDG, FEE, SAFE);

        vm.stopBroadcast();

        // Read back, so a wrong constructor argument is visible now rather than
        // at the first rebalance.
        (, int256 answer, , , ) = oracle.latestRoundData();

        console2.log("");
        console2.log("=== deployed ===");
        console2.log("UniswapV3TwapAdapter      ", address(oracle));
        console2.log("SpotVaultMinimal (zqNVDA) ", address(vault));
        console2.log("RobinhoodChainRouterAdapter", address(swap));
        console2.log("");
        console2.log("=== read back ===");
        console2.log("oracle.decimals()         ", oracle.decimals());
        console2.log("oracle answer (1e8)       ", uint256(answer));
        console2.log("baseIsToken0 (expect false)", oracle.baseIsToken0());
        console2.log("vault.assetToCash(1e18)   ", vault.assetToCash(1e18));
        console2.log("vault admin is the Safe   ", vault.hasRole(0x00, SAFE));
        console2.log("");
        console2.log("NEXT: safe-batches/I-stock-vault-roles.json, with these addresses.");
    }
}
```

- [ ] **Step 2: Dry-run it against a fork**

```bash
cd sidequest-protocol/contracts
RH_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge script script/DeployStockVault.s.sol:DeployStockVault \
  --rpc-url https://rpc.mainnet.chain.robinhood.com
```

No `--broadcast`, so nothing is sent. Expected: three addresses printed, `baseIsToken0`
false, `oracle answer` a plausible NVDA price at 1e8, `assetToCash(1e18)` equal to that
answer divided by 100, and `vault admin is the Safe` true.

- [ ] **Step 3: Confirm the suite still compiles and passes**

```bash
forge test
```

- [ ] **Step 4: Commit**

```bash
git add sidequest-protocol/contracts/script/DeployStockVault.s.sol
git commit -m "feat(script): deploy the oracle-free NVDA long/flat vault"
```

- [ ] **Step 5: STOP. Broadcasting is a human decision.**

Do not broadcast as part of executing this plan. Present the dry-run output and the gas
estimate, and let the operator decide. When they do broadcast, record the three addresses —
Tasks 9, 11 and 12 all need them.

---

## Task 9: The Safe batch

One atomic transaction, one Safe nonce. It ends with the Safe holding the keeper and risk
roles and holding no admin.

**Files:**
- Create: `sidequest-protocol/contracts/safe-batches/I-stock-vault-roles.json`

**Interfaces:**
- Consumes: the three addresses printed by Task 8.
- Produces: a Transaction Builder JSON the operator uploads to the Safe.

- [ ] **Step 1: Generate every calldata with cast, straight to files**

Never hand-copy hex. Substitute the real addresses for the four shell variables.

```bash
cd sidequest-protocol/contracts/safe-batches
mkdir -p .calldata
VAULT=0x0000000000000000000000000000000000000000   # from Task 8
SWAP=0x0000000000000000000000000000000000000000    # from Task 8
SAFE=0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4
TIMELOCK=0x813D69B8e1DBE2E08bcB892BE203A6BCE99b36Fc
KEEPER=0xfc8737ab85eb45125971625a9ebdb75cc78e01d5c1fa80c4c6e5203f47bc4fab
RISK=0x9957de8c5d95da580823ca52e598d0c0d2818cb1f8fd9773a5166d2a45d82b05
VAULT_ROLE=$(cast keccak "VAULT_ROLE")   # 0x31e0210044b4f6757ce6aa31f9c6e8d4896d24a755014887391a926c5224d959
ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000

cast calldata "grantRole(bytes32,address)" $KEEPER $SAFE      > .calldata/1-keeper.hex
cast calldata "grantRole(bytes32,address)" $RISK   $SAFE      > .calldata/2-risk.hex
cast calldata "grantRole(bytes32,address)" $VAULT_ROLE $VAULT > .calldata/3-vaultrole.hex
cast calldata "setSwapAdapter(address)"    $SWAP              > .calldata/4-adapter.hex
cast calldata "grantRole(bytes32,address)" $ADMIN  $TIMELOCK  > .calldata/5-admin.hex
cast calldata "renounceRole(bytes32,address)" $ADMIN $SAFE    > .calldata/6-renounce.hex

for f in .calldata/*.hex; do echo "$f  $(wc -c < "$f") chars"; done
```

Every file must be 139 characters for a `(bytes32,address)` call (`0x` + 8 + 64 + 64 + a
newline) and 75 for `setSwapAdapter`. A short file is a truncated argument — a previous
batch shipped 353 bytes where 356 belonged, from exactly this.

- [ ] **Step 2: Assemble the batch**

Create `safe-batches/I-stock-vault-roles.json`, pasting each `data` from the file of the
same number. `createdAt` is milliseconds since the epoch; use `date +%s%3N`.

```json
{
  "version": "1.0",
  "chainId": "4663",
  "createdAt": 0,
  "meta": {
    "name": "I - stock vault roles and handover to the Timelock",
    "description": "Finishes the oracle-free NVDA long/flat vault in one atomic transaction. Grants KEEPER_ROLE and RISK_COUNCIL_ROLE to this Safe, grants VAULT_ROLE on the swap adapter to the vault, points the vault at that swap adapter, grants DEFAULT_ADMIN_ROLE to the Timelock, and renounces this Safe's own DEFAULT_ADMIN_ROLE. KEEPER on the Safe rather than the Timelock is deliberate and is disclosed on the site: rebalanceTo is the manager's actual job and cannot wait 48 hours. RISK_COUNCIL likewise, because a circuit breaker that takes two days to pull is not a breaker. Everything about the vault's CONFIGURATION - fees, roles, the swap adapter - stays timelocked. Atomic on purpose: the vault must never exist in a state where it has an admin who is neither the Safe nor the Timelock, and the six steps must not be able to half-apply. NOTE: Safe nonces execute in order.",
    "txBuilderVersion": "1.16.5"
  },
  "transactions": [
    { "to": "<VAULT>", "value": "0", "data": "<1-keeper.hex>", "contractMethod": null, "contractInputsValues": null },
    { "to": "<VAULT>", "value": "0", "data": "<2-risk.hex>", "contractMethod": null, "contractInputsValues": null },
    { "to": "<SWAP>", "value": "0", "data": "<3-vaultrole.hex>", "contractMethod": null, "contractInputsValues": null },
    { "to": "<VAULT>", "value": "0", "data": "<4-adapter.hex>", "contractMethod": null, "contractInputsValues": null },
    { "to": "<VAULT>", "value": "0", "data": "<5-admin.hex>", "contractMethod": null, "contractInputsValues": null },
    { "to": "<VAULT>", "value": "0", "data": "<6-renounce.hex>", "contractMethod": null, "contractInputsValues": null }
  ]
}
```

The renounce must be **last**. Any other order leaves a step that needs an admin the Safe has
already given up.

- [ ] **Step 3: Simulate the whole batch on a fork before it is ever signed**

```bash
cd sidequest-protocol/contracts
cast rpc anvil_impersonateAccount $SAFE --rpc-url http://127.0.0.1:8545
```

Run each transaction in order against a local fork with the Safe impersonated, then assert
the end state:

```bash
RPC=http://127.0.0.1:8545
cast call $VAULT "hasRole(bytes32,address)(bool)" $KEEPER $SAFE      --rpc-url $RPC  # true
cast call $VAULT "hasRole(bytes32,address)(bool)" $RISK   $SAFE      --rpc-url $RPC  # true
cast call $VAULT "hasRole(bytes32,address)(bool)" $ADMIN  $TIMELOCK  --rpc-url $RPC  # true
cast call $VAULT "hasRole(bytes32,address)(bool)" $ADMIN  $SAFE      --rpc-url $RPC  # FALSE
cast call $VAULT "swapAdapter()(address)"                            --rpc-url $RPC  # the swap adapter
cast call $SWAP  "hasRole(bytes32,address)(bool)" $VAULT_ROLE $VAULT --rpc-url $RPC  # true
```

All six must read as marked. `hasRole(ADMIN, SAFE)` being **false** is the one that proves
the handover completed.

- [ ] **Step 4: Commit the batch**

```bash
git add sidequest-protocol/contracts/safe-batches/I-stock-vault-roles.json
git commit -m "chore(safe): batch I, stock vault roles and Timelock handover"
```

- [ ] **Step 5: STOP. Signing is a human decision.**

Present the simulation output. The operator uploads the JSON to the Safe and collects both
signatures.

---

## Task 10: Register the vault for the indexer and the portal

The indexer reads its vault list from the `vaults` table, not from an env var. An unregistered
vault emits `Rebalanced` events that nothing copies into the receipts feed — the track record
would simply not exist.

**Files:**
- Create: `zorpha-web/migrations/013-mainnet-stock-vault.sql`

**Interfaces:**
- Consumes: the vault and adapter addresses from Task 8.
- Produces: one row in `public.vaults` at `(chain_id = 4663, address = <vault>)`.

- [ ] **Step 1: Write the migration**

The primary key has been `(chain_id, address)` since migration 012, so the conflict target
must name both columns. Create `zorpha-web/migrations/013-mainnet-stock-vault.sql`:

```sql
-- 013, register the oracle-free NVDA long/flat vault on mainnet 4663.
--
-- WHY A ROW IS REQUIRED AND NOT MERELY TIDY
--
-- The indexer reads its vault list from THIS TABLE, not from VAULT_ADDRESSES --
-- see indexer/src/index.ts, which warns and skips for any address in the env
-- var that has no row here. So a vault absent from this table emits Rebalanced
-- events that nothing copies into `rebalances`, and the receipts feed shows an
-- empty track record for a manager who has been trading. The protocol's whole
-- claim is "a track record you can verify"; this row is what makes the claim
-- true for this vault.
--
-- oracle IS populated, unlike the yield vault's NULL. A yield vault prices from
-- its ERC-4626 target and needs no feed; this one prices through a
-- UniswapV3TwapAdapter, and recording which one matters because the answer is
-- only meaningful together with the pool it was read from.
--
-- manager_address is the governance Safe: it holds KEEPER_ROLE, so it is the
-- address that will appear as the signer on every receipt.

begin;

insert into public.vaults
  (chain_id, address, vault_type, name, symbol, asset, cash, base_asset, oracle,
   strategy, manager_address, listed)
values
  (4663,
   '0x0000000000000000000000000000000000000000',   -- REPLACE: SpotVaultMinimal from Task 8
   'spot',
   'Zorpha NVDA Long/Flat', 'zqNVDA',
   '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',   -- NVDA, 18dp
   '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',   -- USDG, 6dp
   NULL,
   '0x0000000000000000000000000000000000000000',   -- REPLACE: UniswapV3TwapAdapter from Task 8
   'Long or flat on tokenized NVDA. The manager sets one number: how much of the vault sits in NVDA and how much in USDG. Priced by a 30-minute time-weighted average of the same Uniswap pool the trades clear against, so a price that fools the accounting also gives the attacker a bad fill.',
   '0xC75E64Ccf3ce6E2F40939Ab58255681769BcF8C4',   -- governance Safe, holds KEEPER_ROLE
   true)

on conflict (chain_id, address) do update set
  vault_type      = excluded.vault_type,
  name            = excluded.name,
  symbol          = excluded.symbol,
  asset           = excluded.asset,
  cash            = excluded.cash,
  base_asset      = excluded.base_asset,
  oracle          = excluded.oracle,
  strategy        = excluded.strategy,
  manager_address = excluded.manager_address,
  listed          = true;

commit;

-- AFTER RUNNING THIS
--
-- /portal/vaults should list two vaults on mainnet: zsUSDG and zqNVDA. The
-- indexer's next cycle should report vaultsTracked 2 rather than 1. Neither
-- happens until the two placeholder addresses above are replaced -- a row at
-- the zero address is worse than no row, because it looks registered.
```

- [ ] **Step 2: Verify the conflict target matches the live schema**

```bash
grep -n "vaults_pkey" zorpha-web/migrations/012-cursor-and-vault-chain-scope.sql
```

Expected: `primary key (chain_id, address)`. If it reads differently, correct the
`on conflict` clause to match rather than assuming.

- [ ] **Step 3: Commit**

```bash
git add zorpha-web/migrations/013-mainnet-stock-vault.sql
git commit -m "feat(db): register the NVDA long/flat vault on mainnet"
```

- [ ] **Step 4: STOP until Task 8 has broadcast.**

Do not run this migration with placeholder addresses. Replace both, then run it against
Supabase, then confirm `vaultsTracked` in the indexer's next log line.

---

## Task 11: Retract the "not on mainnet" claims and wire the addresses

Right now the site states, in four places, that the spot vault and the oracle are
deliberately absent from mainnet. Task 8 makes all four false. This is the same class of
stale claim the session already corrected six times, and it is worse than a missing feature:
it is the site describing a protocol that no longer exists.

**Files:**
- Modify: `zorpha-web/lib/contracts.ts` (the `isExpectedAbsence` switch)
- Modify: `zorpha-web/lib/deployment.ts:46-52` (`NOT_ON_MAINNET`)
- Modify: `zorpha-web/.env.local`
- Modify: Vercel production environment variables (by hand, in the dashboard)

**Interfaces:**
- Consumes: the vault and adapter addresses from Task 8.
- Produces: `contracts.spotVault` and `contracts.oracle` resolving to real addresses, so
  `factoryVaults()` returns the spot vault and the terminal lists it.

- [ ] **Step 1: Write the failing test**

`zorpha-web/lib/contracts.test.ts` already exists and already pins this behaviour the other
way round. It uses **`node:test` and `node:assert/strict`** — not vitest, not jest — and it
carries a `BY_DESIGN` array listing `'oracle'` and `'spotVault'`. So this is an edit to an
existing assertion, not a new one appended beside it. Leaving the old array in place would
have the suite assert both claims at once.

Change the array and its test name, so the file states what is now true:

```typescript
/** Absent on 4663 by decision; see lib/deployment.ts NOT_ON_MAINNET. */
const BY_DESIGN: ContractKey[] = [
  'strategyExecutor',
  'rotationVault',
  'reputationRegistry',
];

test('the three systems that were never deployed to mainnet are not faults', () => {
  for (const key of BY_DESIGN) {
    assert.equal(
      isExpectedAbsence(key, MAINNET_CHAIN_ID),
      true,
      `${key} is in NOT_ON_MAINNET, so its absence is a decision, not a misconfiguration`,
    );
  }
});
```

and add, next to the yield-vault test that makes the same kind of point:

```typescript
test('the stock vault and its price feed are deployed, so an unset address is a fault', () => {
  // Both used to be in BY_DESIGN. The spot vault is live on 4663 now, priced by
  // a UniswapV3TwapAdapter reading the NVDA/USDG pool directly, so an unset
  // address for either is a real misconfiguration and the banner must say so.
  // This is the same failure the yield-vault entry above was: a key excused out
  // of a warning somebody needed.
  assert.equal(isExpectedAbsence('spotVault', MAINNET_CHAIN_ID), false);
  assert.equal(isExpectedAbsence('oracle', MAINNET_CHAIN_ID), false);
});
```

The last test in the file iterates `[...BY_DESIGN, 'leaderFaucet', 'yieldVault']` for
testnet. Add `'oracle'` and `'spotVault'` to that literal so testnet coverage does not shrink
when they leave `BY_DESIGN`.

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd zorpha-web && npm test
```

Expected: the new test fails — both calls still return `true`.

- [ ] **Step 3: Edit the switch**

In `zorpha-web/lib/contracts.ts`, `isExpectedAbsence`, remove `case 'oracle':` and
`case 'spotVault':` from the deferred group and rewrite the comment so it describes what is
now true:

```typescript
    // Written and tested, deliberately not deployed on 4663. lib/deployment.ts
    // NOT_ON_MAINNET carries the reasoning and the public disclosure; the
    // whitepaper and /protocol say so too. Absent by decision, not by fault.
    //
    // `oracle` and `spotVault` USED to be in this list. They are not any more:
    // the spot vault is live on 4663, priced by a UniswapV3TwapAdapter that
    // reads the NVDA/USDG pool directly. The oracle problem was removed rather
    // than deferred, so an unset address for either is now a real
    // misconfiguration and the banner should say so.
    case 'strategyExecutor':
    case 'rotationVault':
    case 'reputationRegistry':
      return true;
```

- [ ] **Step 4: Edit NOT_ON_MAINNET**

In `zorpha-web/lib/deployment.ts`, drop the `MedianOracle` and `Spot vault (long/flat)`
rows, and change the rotation vault's note, which currently blames a dependency that no
longer blocks anything:

```typescript
export const NOT_ON_MAINNET: { name: string; note: string }[] = [
  { name: 'StrategyExecutor', note: 'The signed-rebalance path. Not deployed because nothing on mainnet drives a vault by signature yet; the stock vault is operated directly by its keeper.' },
  { name: 'Rotation vault (basket)', note: 'Reweights a basket of Stock Tokens. Every leg needs its own priced pool, and only some of them have one deep enough. Deferred until they do.' },
  { name: 'ReputationRegistry', note: 'Manager commitments. Deferred with the manager-bonding design it belongs to.' },
];
```

`MedianOracle` leaves the list entirely: it is not deferred, it is not wanted. Running one
would mean a keeper holding a live signing key forever, and the TWAP adapter removes the
need. If the surrounding page implies the list means "coming later", adjust that sentence
too — check `grep -rn "NOT_ON_MAINNET" zorpha-web/app zorpha-web/components`.

- [ ] **Step 5: Set the addresses**

```bash
cd zorpha-web
# Local dev
sed -i 's|^NEXT_PUBLIC_ORACLE_ADDRESS=.*|NEXT_PUBLIC_ORACLE_ADDRESS=<adapter from Task 8>|' .env.local
sed -i 's|^NEXT_PUBLIC_SPOT_VAULT_ADDRESS=.*|NEXT_PUBLIC_SPOT_VAULT_ADDRESS=<vault from Task 8>|' .env.local
grep -E 'ORACLE_ADDRESS|SPOT_VAULT_ADDRESS' .env.local
```

Production reads from Vercel, not from this file. Set both in the Vercel project's
Environment Variables for Production **and redeploy** — `NEXT_PUBLIC_*` values are inlined
at build time, so an env change with no rebuild changes nothing.

- [ ] **Step 6: Run the tests and confirm they pass**

```bash
cd zorpha-web && npm test && npm run lint && npm run build
```

- [ ] **Step 7: Commit**

```bash
git add zorpha-web/lib/contracts.ts zorpha-web/lib/deployment.ts zorpha-web/lib/contracts.test.ts
git commit -m "fix(site): the spot vault and its price feed are on mainnet now"
```

---

## Task 12: The NVDA price chart

**Files:**
- Create: `zorpha-web/lib/twap-adapter-abi.ts`
- Create: `zorpha-web/components/portal/StockPrice.tsx`
- Modify: `zorpha-web/components/portal/terminal/ManagerTerminal.tsx`

**Interfaces:**
- Consumes: `contracts.oracle` from Task 11; the adapter's `answersOverWindows`,
  `oldestObservationSecondsAgo`, `latestRoundData`, `decimals` from Task 5.
- Produces: `export const twapAdapterAbi`, and
  `export function StockPrice({ oracleAddress, symbol }: { oracleAddress: \`0x${string}\`; symbol: string })`.

- [ ] **Step 1: Write the ABI**

Create `zorpha-web/lib/twap-adapter-abi.ts`:

```typescript
/**
 * The UniswapV3TwapAdapter's read surface.
 *
 * Kept out of `manager-abi.ts`, which is the OPERATOR surface and is loaded on
 * the terminal only. This one is read by a page any visitor can open, so it
 * carries the four views a chart needs and nothing else.
 *
 * `answersOverWindows` is deliberately ungated on the contract: no cardinality,
 * liquidity, age or divergence check runs inside it. That is why the chart
 * keeps drawing when `latestRoundData` is reverting, which is exactly the
 * moment a manager wants to look at the price.
 */
export const twapAdapterAbi = [
  {
    type: 'function',
    name: 'decimals',
    stateMutability: 'pure',
    inputs: [],
    outputs: [{ type: 'uint8' }],
  },
  {
    type: 'function',
    name: 'latestRoundData',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'roundId', type: 'uint80' },
      { name: 'answer', type: 'int256' },
      { name: 'startedAt', type: 'uint256' },
      { name: 'updatedAt', type: 'uint256' },
      { name: 'answeredInRound', type: 'uint80' },
    ],
  },
  {
    type: 'function',
    name: 'oldestObservationSecondsAgo',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint32' }],
  },
  {
    type: 'function',
    name: 'answersOverWindows',
    stateMutability: 'view',
    inputs: [{ name: 'secondsAgos', type: 'uint32[]' }],
    outputs: [{ type: 'uint256[]' }],
  },
  { type: 'function', name: 'twapWindow', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint32' }] },
  { type: 'function', name: 'pool', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const;
```

- [ ] **Step 2: Write the component**

Create `zorpha-web/components/portal/StockPrice.tsx`, following `VaultApy.tsx`'s shape: a
`useReadContracts` hook returning a discriminated union, then a component that renders each
state honestly.

```tsx
'use client';

import { useMemo } from 'react';
import { useReadContract, useReadContracts } from 'wagmi';
import { twapAdapterAbi } from '@/lib/twap-adapter-abi';
import { Mono } from '@/components/ui/Primitives';

/**
 * The price of the vault's underlying, read from the pool the vault trades in.
 *
 * WHY THE SERIES COMES FROM THE CONTRACT
 *
 * Uniswap stores a ring buffer of tick cumulatives, and turning those into a
 * price means tick maths -- a 2^128 fixed-point exponentiation with twenty
 * magic constants. Reimplementing that in TypeScript would put a second copy of
 * the protocol's most error-prone arithmetic in the browser, where a divergence
 * from the contract's copy would show as a chart that quietly disagrees with
 * NAV. So the adapter exposes `answersOverWindows` and this component draws
 * what the vault itself would price. There is one implementation.
 *
 * WHY IT KEEPS DRAWING WHEN THE VAULT WILL NOT TRADE
 *
 * `answersOverWindows` runs none of the five guards. A manager whose rebalance
 * has just been refused because spot diverged from the average is precisely the
 * person who needs to see what the price has been doing, and a guarded view
 * would go blank at that moment. The banner below says when NAV is refusing;
 * the chart carries on.
 *
 * WHERE THE HISTORY COMES FROM
 *
 * Entirely from pool state, read at the current block. No indexer, no archive
 * node -- which matters, because the public RPC for this chain prunes archive
 * state and cannot answer a historical call at all. The horizon is whatever the
 * pool's observation buffer reaches back to, which was about 55 hours when this
 * was built, clamped to 24.
 */

const POINTS = 48;
const MAX_HORIZON_SECONDS = 24 * 60 * 60;
const REFRESH_MS = 30_000;

type Series =
  | { state: 'loading' }
  | { state: 'unreadable' }
  | { state: 'ready'; prices: number[]; horizonSeconds: number; navRefusing: boolean; latest: number | null };

function useStockPrice(oracle: `0x${string}`): Series {
  // The buffer depth first, because `observe` reverts with a bare "OLD" for any
  // horizon beyond it. Asking and clamping beats guessing and retrying.
  const { data: oldest, isLoading: depthLoading, isError: depthError } = useReadContract({
    abi: twapAdapterAbi,
    address: oracle,
    functionName: 'oldestObservationSecondsAgo',
    query: { refetchInterval: REFRESH_MS },
  });

  const horizon = useMemo(() => {
    if (oldest === undefined) return 0;
    // A small margin off the very oldest slot: it can be overwritten between
    // this read and the next block, which would turn the chart call into "OLD".
    const usable = Math.max(0, Number(oldest) - 120);
    return Math.min(usable, MAX_HORIZON_SECONDS);
  }, [oldest]);

  const secondsAgos = useMemo(() => {
    if (horizon < POINTS) return null;
    const step = Math.floor(horizon / POINTS);
    const out: number[] = [];
    for (let i = POINTS; i >= 1; i--) out.push(step * i);
    out.push(0);
    return out;
  }, [horizon]);

  const reads = useReadContracts({
    contracts: [
      {
        abi: twapAdapterAbi,
        address: oracle,
        functionName: 'answersOverWindows',
        args: secondsAgos ? [secondsAgos] : undefined,
      },
      { abi: twapAdapterAbi, address: oracle, functionName: 'latestRoundData' },
    ],
    query: { enabled: Boolean(secondsAgos), refetchInterval: REFRESH_MS },
  });

  if (depthError) return { state: 'unreadable' };
  if (depthLoading || !secondsAgos || reads.isLoading) return { state: 'loading' };
  if (reads.isError) return { state: 'unreadable' };

  const [seriesRead, navRead] = reads.data ?? [];
  if (seriesRead?.status !== 'success') return { state: 'unreadable' };

  const prices = (seriesRead.result as readonly bigint[]).map((v) => Number(v) / 1e8);
  if (prices.length === 0 || prices.some((p) => !Number.isFinite(p) || p <= 0)) {
    return { state: 'unreadable' };
  }

  // A reverting latestRoundData is INFORMATION, not an error: it means one of
  // the five guards is refusing, so the vault cannot rebalance right now.
  const navRefusing = navRead?.status !== 'success';
  const latest = navRead?.status === 'success'
    ? Number((navRead.result as readonly [bigint, bigint, bigint, bigint, bigint])[1]) / 1e8
    : null;

  return { state: 'ready', prices, horizonSeconds: horizon, navRefusing, latest };
}

function describeHorizon(seconds: number): string {
  if (seconds < 7200) return `${Math.round(seconds / 60)} minutes`;
  return `${Math.round(seconds / 3600)} hours`;
}

/** A sparkline. No chart library: it is one polyline over a normalised range. */
function Spark({ prices }: { prices: number[] }) {
  const width = 640;
  const height = 120;
  const min = Math.min(...prices);
  const max = Math.max(...prices);
  const span = max - min || 1;

  const points = prices
    .map((p, i) => {
      const x = (i / (prices.length - 1 || 1)) * width;
      const y = height - ((p - min) / span) * height;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(' ');

  const last = prices[prices.length - 1];
  const first = prices[0];
  const rising = last >= first;

  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      className="mt-4 h-32 w-full overflow-visible"
      role="img"
      aria-label={`Price over the charted window, ${first.toFixed(2)} to ${last.toFixed(2)}`}
      preserveAspectRatio="none"
    >
      <polyline
        points={points}
        fill="none"
        strokeWidth={2}
        vectorEffect="non-scaling-stroke"
        className={rising ? 'stroke-verified-400' : 'stroke-ink-400'}
      />
    </svg>
  );
}

export function StockPrice({
  oracleAddress,
  symbol,
}: {
  oracleAddress: `0x${string}`;
  symbol: string;
}) {
  const s = useStockPrice(oracleAddress);

  return (
    <div className="card-pad">
      <div className="flex items-baseline justify-between gap-3">
        <div className="stat-label">{symbol} price</div>
        {s.state === 'ready' && s.latest !== null ? (
          <span className="font-mono text-2xl tabular-nums">${s.latest.toFixed(2)}</span>
        ) : null}
      </div>

      {s.state === 'loading' ? (
        <div
          className="mt-4 h-32 w-full animate-pulse rounded bg-void-700"
          role="status"
          aria-label="Reading the pool's price history"
        />
      ) : null}

      {s.state === 'unreadable' ? (
        <>
          <div className="stat-value mt-2 text-ink-500">&mdash;</div>
          <p className="mt-2 text-xs leading-relaxed text-ink-400">
            The pool did not answer this read. The figure is unavailable rather than zero, and
            those are different things.
          </p>
        </>
      ) : null}

      {s.state === 'ready' ? (
        <>
          <Spark prices={s.prices} />
          <p className="mt-3 text-xs leading-relaxed text-ink-400">
            The last {describeHorizon(s.horizonSeconds)}, read from the Uniswap pool&rsquo;s own
            observation history at the current block. Each point is a time-weighted average over
            its interval, computed by the same contract that prices the vault &mdash; not by this
            page, and not from an index.
          </p>
          {s.navRefusing ? (
            <p className="mt-3 text-xs leading-relaxed text-amber-400">
              The vault will not rebalance right now: one of the price feed&rsquo;s guards is
              refusing, most often because spot has moved more than 2% away from the 30-minute
              average. The chart above still reads, because <Mono>answersOverWindows</Mono> runs
              none of those checks. Signing a rebalance in this state only spends gas.
            </p>
          ) : null}
        </>
      ) : null}
    </div>
  );
}
```

All class names here already exist: `card-pad`, `stat-label`, `stat-value`, `text-ink-400`,
`text-verified-400` and `bg-void-700` are used in `VaultTvl.tsx`, and `text-amber-400` is the
warning tone `app/globals.css` uses for `.badge-warn`. `Mono` is exported from
`components/ui/Primitives.tsx`.

- [ ] **Step 3: Mount it in the terminal**

In `ManagerTerminal.tsx`, render `StockPrice` for a spot vault only, above the rebalance
panel, reading the oracle address from the vault rather than from config so the chart cannot
drift from what the vault actually prices against. The terminal already reads
`spotVaultAbi`'s `oracle` view, so use that value.

```tsx
import { StockPrice } from '@/components/portal/StockPrice';

// ...inside the spot branch, above <SpotRebalance ... />:
{vaultOracle ? <StockPrice oracleAddress={vaultOracle} symbol={assetSymbol} /> : null}
```

Find the existing name for the oracle read in that file before wiring it — do not add a
second read of the same value.

- [ ] **Step 4: Verify it in the browser**

```bash
cd zorpha-web && npm run dev
```

Then, using the preview tools: open `/portal/manage`, select the NVDA vault, and check that
the sparkline renders with a plausible NVDA price, that the console is clean, and that
resizing to mobile does not scroll the page sideways. Take a screenshot for the record.

- [ ] **Step 5: Lint, typecheck, build**

```bash
cd zorpha-web && npm run lint && npm run build
```

- [ ] **Step 6: Commit**

```bash
git add zorpha-web/lib/twap-adapter-abi.ts zorpha-web/components/portal/StockPrice.tsx \
        zorpha-web/components/portal/terminal/ManagerTerminal.tsx
git commit -m "feat(portal): price chart read from the pool the vault trades in"
```

---

## Task 13: The two disclosures

The spec requires both, and requires the first "in the same words" as the adapter-timelock
exception the site already carries.

**Files:**
- Modify: `zorpha-web/app/(marketing)/protocol/page.tsx`
- Modify: `zorpha-web/components/portal/terminal/ManagerTerminal.tsx`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Find the existing exception's wording and match it**

```bash
grep -rn "Adapter changes\|takes effect immediately\|Timelock-gated" \
  zorpha-web/app/\(marketing\)/protocol/page.tsx | head -20
```

That block was rewritten earlier in this project to say plainly that one action is not
timelocked while everything else is. The new disclosures go in the same table and the same
voice. Do not invent a second format.

- [ ] **Step 2: Add the role disclosure**

On `/protocol`, in the same table that carries the adapter exception, add:

> **Rebalances** — Immediate. `KEEPER_ROLE` on the stock vault is held by the 2-of-2 Safe,
> not by the Timelock. A manager decision takes effect as soon as both signers approve it;
> everything about the vault's configuration — its fees, its roles, the venue it trades
> through — does not, and stays behind the 48-hour Timelock.
>
> **Circuit breaker** — Immediate, and for the same reason. `RISK_COUNCIL_ROLE` is held by
> the Safe, so deposits can be halted at once. A brake that takes two days to pull is not a
> brake.

- [ ] **Step 3: Add the 24/7 disclosure**

Next to the vault, not in a footnote. In `ManagerTerminal.tsx`, above the rebalance panel for
the spot vault, and on `/protocol` alongside the roles table:

> **This vault trades around the clock, and the stock it tracks does not.** NVDA trades
> 09:30–16:00 ET on weekdays. Tokenized NVDA trades all the time. A rebalance at 03:00 on a
> Sunday prices against a market with no underlying reference and thin flow, and the token
> can drift from the equity it represents. There is no market-hours restriction here and no
> widened off-hours tolerance: the guards are the same at every hour. Trading then is
> allowed, and it is your judgement.

- [ ] **Step 4: Check the whitepaper and FAQ for anything this contradicts**

```bash
grep -rn "no oracle\|oracle on 4663\|not deployed\|MedianOracle" \
  zorpha-web/app/\(marketing\)/whitepaper/page.tsx \
  zorpha-web/app/\(marketing\)/faq/page.tsx \
  zorpha-web/app/\(marketing\)/protocol/page.tsx \
  zorpha-web/README.md
```

Any sentence claiming the protocol has no priced vault on mainnet, or that the oracle is a
funding problem waiting to be solved, is now false. Correct each one. This is the fifth time
this project has shipped a claim that the chain contradicted; the grep is cheap.

- [ ] **Step 5: Lint, typecheck, build, and read the rendered page**

```bash
cd zorpha-web && npm run lint && npm run build
```

Then open `/protocol` in the preview and confirm the table reads coherently with the
adapter exception rather than beside it.

- [ ] **Step 6: Commit**

```bash
git add zorpha-web/app/\(marketing\)/protocol/page.tsx \
        zorpha-web/components/portal/terminal/ManagerTerminal.tsx
git commit -m "docs(site): disclose the immediate keeper role and 24/7 trading"
```

---

## Task 14: Verify the contracts on Blockscout

Nine contracts are verified today, and "verify everything yourself" is the protocol's
central claim. Two unverified contracts holding the price of a live vault would undercut it.

**Files:** none created.

- [ ] **Step 1: Verify both new contracts**

The verify button in the Blockscout UI does nothing on this chain; the CLI path works but
needs retrying until it returns 200. `script/verify-mainnet.sh` already carries that loop —
read it and follow the same pattern:

```bash
sed -n '1,60p' sidequest-protocol/contracts/script/verify-mainnet.sh
```

Verify `UniswapV3TwapAdapter` and the new `RobinhoodChainRouterAdapter` instance. The vault
is `SpotVaultMinimal`, whose source is already verified for another address but must be
verified again at this one.

- [ ] **Step 2: Confirm by fetching the pages**

```bash
for a in <ORACLE> <VAULT> <SWAP>; do
  echo -n "$a "
  curl -s "https://robinhoodchain.blockscout.com/api/v2/smart-contracts/$a" \
    | python -c "import sys,json; d=json.load(sys.stdin); print(d.get('is_verified'), d.get('name'))"
done
```

All three must print `True` and the right contract name.

- [ ] **Step 3: Update the site's contract list if it enumerates verified contracts**

```bash
grep -rn "nine\|9 contracts\|all contracts verified" zorpha-web/app zorpha-web/README.md | head
```

If a count is written down anywhere, it is now twelve.

- [ ] **Step 4: Commit any resulting edits**

```bash
git commit -am "docs(site): the stock vault's contracts are verified too"
```

---

## Self-review

Run against the spec with fresh eyes.

**1. Spec coverage**

| Spec requirement | Task |
| --- | --- |
| `UniswapV3TwapAdapter` implements `AggregatorV3Interface` | 2, 3 |
| `decimals()` returns 8 | 2 (asserted), 3 |
| `latestRoundData` returns `(1, answer, ts, ts, 1)` | 3 |
| Answer is quote-per-whole-base at 1e8, worked example matched | 3 |
| Base/quote ordering asserted against `token0`/`token1` | 2 |
| `maxStaleness()` NOT implemented | 3 (test), 6 (`OracleWindow` branch exercised) |
| Guard: spot vs TWAP > 200bps | 4 |
| Guard: cardinality < 300 | 4 |
| Guard: liquidity < 1.2e19 | 4 |
| Guard: observation age > 4h | 4 |
| Guard: answer not strictly positive | 3, 4 |
| Deployment parameters, all fourteen | 8 |
| `admin = Timelock`, `KEEPER_ROLE = Safe` | 8 (deploy to Safe), 9 (batch hands over) |
| Disclosure of the keeper exception, in the same words | 13 |
| Test 1: answer matches an independent TWAP | 6 |
| Test 2: each guard reverts on its own trigger only | 4 |
| Test 3: vault constructs, `OracleWindow` not-ours branch | 6 |
| Test 4: deposit, `rebalanceTo(10000)`, `rebalanceTo(0)` round trip | 7 |
| Test 5: simulated manipulation blocks the rebalance | 7 |
| Test 6: decimal correctness across 18/6/8 | 3 (reciprocal), 6 (`assetToCash`) |
| Terminal: price chart | 12 |
| Terminal: current position | already exists (`ManagerTerminal.tsx`) |
| Terminal: one target-weight control | already exists (`RebalancePanel.tsx`) |
| Terminal: the resulting receipt | already exists; needs Task 10 to index |
| Terminal: past calls with the date and price then | already exists (`/portal/receipts`); needs Task 10 |
| 24/7 disclosure, next to the vault | 13 |
| `SpotVaultMinimal` unmodified | Global Constraints; no task edits it |

Two gaps found and closed while reviewing: the spec never says the vault must be **registered
with the indexer**, without which the receipts feed and the track record — the whole point of
slice 1 — stay empty (Task 10); and it never says the site's standing claim that the spot
vault is deliberately absent from mainnet has to be **retracted** (Task 11). Both are now
tasks.

One gap noted and **deliberately left open**: the spec's receipt copy, *"on 6 September this
manager moved to 100% NVDA"*, implies the receipts feed shows NVDA's price at the time of
each call. The `rebalances` table stores `nav_per_share` but not the underlying's price, and
`ReceiptCard.tsx` would need a schema column and an indexer change to show it. That is a
change to the receipts feed rather than to this vault, it affects zsUSDG's rows too, and it
is not needed for the first receipt to exist. **Out of scope for slice 1; raise it with slice
2, the public track record.**

**2. Placeholder scan**

No "TBD", no "implement later", no "add error handling", no "similar to Task N". Every code
step carries the code. Three deliberate placeholders remain and each is flagged with a STOP
step, because filling them requires an address that does not exist until a human broadcasts:
the `<VAULT>`, `<SWAP>` and `<ORACLE>` substitutions in Tasks 9, 10, 11 and 12. Task 10's own
footer says a row at the zero address is worse than no row.

**3. Type consistency**

- `answerAtTick(int24) returns (uint256)` — declared Task 3, used in Tasks 4, 5, 6.
- `meanTick() returns (int24)` — declared Task 3, used in Tasks 4, 6.
- `answersOverWindows(uint32[]) returns (uint256[])` — declared Task 5, ABI in Task 12
  matches (`uint32[]` in, `uint256[]` out).
- `oldestObservationSecondsAgo() returns (uint32)` — declared Task 5, ABI and component in
  Task 12 match.
- `baseIsToken0` is `bool` throughout; `minLiquidity` is `uint128` in the constructor, in the
  error, and in the test's `MIN_LIQUIDITY` constant.
- `MockUniswapV3Pool.setMeanTick(int24, uint32)` — defined Task 2, used in Tasks 3, 4, 5.
- `InvalidAnswer` is declared once, in Task 3, and reused in Task 4 rather than redeclared.
- `StockPrice({ oracleAddress, symbol })` — declared Task 12, mounted with those exact prop
  names in the same task.

**4. One risk the implementer must not silently absorb**

`minLiquidity` is 1.2e19. The spec calls that "~25% of the 5.0993e19 measured 6 Sep". In-range
liquidity had already fallen to **2.7237e19** by that evening — the floor is still cleared,
but at 2.3x rather than 4.2x. Task 6 asserts the headroom and says to **stop and report**
rather than lower the floor, because where that floor sits is a spec decision.

---

## Execution

Plan complete and saved to `docs/design/oracle-free-stock-vault-plan.md`.

Tasks 1 through 7 are self-contained and can run end to end: they build and prove the
contract without touching mainnet. Task 8 stops before broadcasting, and Tasks 9 through 14
each need an address that only exists after a human has signed.
