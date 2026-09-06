-- 006, record the token legs of a basket rebalance.
--
-- WHY
--
-- A rotation vault emits:
--
--     Rebalanced(uint16[] targetBps, uint256 navInBase, uint256[] tokenLegs,
--                uint256 baseLeg, uint256 nonce, bytes32 commitment)
--
-- and `commitment` is ReceiptRenderer.basketCommitment, which binds:
--
--     manager, vault, targetWeights, navPerShare, tokenLegs, baseLeg,
--     nonce, blockTimestamp, txHash
--
-- The indexer decoded tokenLegs and threw it away. Every other input to that
-- hash was stored; this one was not. So a rotation receipt sat in the feed
-- carrying a commitment that nobody could recompute, and the claim that every
-- rebalance is an independently verifiable public receipt was false for one of
-- the three vault types. Nothing errored, because a hash you cannot check looks
-- exactly like a hash you have not checked.
--
-- It is also the most interesting column on the table. targetBps is what the
-- manager AIMED at; tokenLegs is what the basket actually held afterwards. A
-- fund's record is the second one.
--
-- SHAPE
--
-- jsonb, matching target_weights, holding an ordered array of decimal strings
-- positionally aligned with the vault's `tokens` array. Strings rather than
-- numbers because these are uint256 balances and JSON numbers are doubles --
-- an 18-decimal balance loses precision silently as a number, which is the
-- same class of error as the hash it exists to let you verify.
--
-- Backfill is deliberately not attempted. Rows written before this column
-- existed cannot recover the value from the database; re-indexing from the
-- chain is the only honest way to populate them, and that is an operational
-- decision rather than something a migration should do silently.

alter table public.rebalances
  add column if not exists token_legs jsonb;

comment on column public.rebalances.token_legs is
  'Rotation vaults only. Ordered uint256 balances as decimal strings, aligned '
  'with the vault''s tokens array. Required to recompute basketCommitment; '
  'null on spot and yield receipts, and on rotation rows indexed before '
  'migration 006.';
