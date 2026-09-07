-- 014, record what the underlying was worth when a receipt was signed.
--
-- WHY
--
-- A receipt carries the manager's decision and the vault's NAV. It does not
-- carry the price of the thing they made the decision about, so "this manager
-- moved to 100% NVDA on 6 September" cannot be scored without going and
-- finding NVDA's price that day from somewhere else. The protocol's claim is
-- that a stranger can verify a track record; a row they have to leave to
-- interpret is not that.
--
-- WHY ON THE RECEIPT AND NOT LOOKED UP LATER
--
-- Because it cannot be looked up later. Measured on 7 September 2026, the
-- public RPC serves state for somewhere between 5,000 and 20,000 blocks and
-- refuses beyond it with "metadata is not found":
--
--     head -  5,000   answers
--     head - 20,000   refused
--
-- At roughly 0.15s blocks that is a window of about twelve to fifty minutes.
-- The price at a receipt's block is readable for tens of minutes and then gone
-- for good. There is no archive node to fall back on and no price feed with
-- history. So it is captured at index time or it is not captured.
--
-- WHY NOT DERIVE IT FROM THE EVENT
--
-- Tempting, and it nearly works. `rebalanceTo` aims for
-- assetLeg == tvl * targetBps / 10000, so the cash leg's value in asset terms
-- is assetLeg * (10000 - targetBps) / targetBps, and inverting `assetToCash`
-- gives a price. On receipt 1 that lands at 232.3853 against an oracle reading
-- of 232.0216, which is 0.157% out: the error is how far the rebalance missed
-- its target, not the price.
--
-- It is unusable anyway, because it divides by zero at targetBps 0 and 10000.
-- Those are "go fully flat" and "go fully long", which are the two most likely
-- instructions a long/flat manager ever signs.
--
-- WHAT IS STORED, AND WHY FOUR COLUMNS
--
--   underlying_price            raw integer answer from the feed
--   underlying_price_decimals   its scale; 8 for the TWAP adapter
--   underlying_price_block      the block the price was actually read at
--   underlying_price_exact      true when that block IS the receipt's block
--
-- The last two exist so an approximate price can never be presented as an
-- exact one. When the indexer is running normally it reads at the receipt's
-- own block and `exact` is true. When it has fallen behind the archive window,
-- or is backfilling an old receipt, it reads at the head instead and records
-- which block that was, so the row says "this is NVDA some hours later" rather
-- than quietly claiming to be the price at signing.
--
-- Nullable throughout. Rows written before this column keep the behaviour they
-- have, and the renderer shows nothing rather than inventing a price.

alter table public.rebalances
  add column if not exists underlying_price          text,
  add column if not exists underlying_price_decimals integer,
  add column if not exists underlying_price_block    bigint,
  add column if not exists underlying_price_exact    boolean;

comment on column public.rebalances.underlying_price is
  'Raw integer price of the vault asset in cash units when this receipt was signed, at underlying_price_decimals. Null for receipts indexed before migration 014, and for vaults with no price feed.';

comment on column public.rebalances.underlying_price_block is
  'The block underlying_price was read at. Equal to block_number when underlying_price_exact is true.';

comment on column public.rebalances.underlying_price_exact is
  'True when the price was read at this receipt''s own block. False when it was read later, because the RPC no longer served state at that block: the public node keeps roughly 5,000 to 20,000 blocks.';

-- text, not numeric, matching nav_per_share. These are raw uint256 answers and
-- a bigint would silently overflow on an 18-decimal feed. The renderer scales
-- by underlying_price_decimals.

-- AFTER RUNNING THIS
--
-- Existing receipts stay null and render without a price, which is correct:
-- receipt 1 sits about 139,000 blocks behind the head, so its exact price is
-- unrecoverable and inventing one would be worse than leaving the field empty.
-- Every receipt signed from here on gets an exact stamp as long as the indexer
-- is inside the archive window, which is its normal operating state.
