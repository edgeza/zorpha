-- 007, record the unit nav_per_share is denominated in.
--
-- WHY
--
-- nav_per_share is stored as a raw uint256 and rendered with a hardcoded 18.
-- That is right for exactly one of the three vault types:
--
--     spot      navPerShare in asset() units      tAAPL, 18   -> correct
--     rotation  navPerShare in baseAsset() units  tUSDG,  6   -> 10^12 out
--     yield     navPerShare in asset() units      tUSDG,  6   -> 10^12 out
--
-- So a rotation receipt showing a NAV of 1.000000 rendered as 0.00000, and the
-- public feed -- the thing that carries the claim that a manager's record is
-- verifiable -- displayed two thirds of its receipts as a vault that had lost
-- everything.
--
-- WHY ON THE RECEIPT AND NOT THE VAULT
--
-- It could live on `vaults` as one value per vault rather than one per row, and
-- that would be less data. But a receipt is meant to be independently
-- interpretable: the whole point is that somebody can take one row, recompute
-- the commitment, and check it without trusting us. A row that cannot be read
-- without joining a mutable table alongside it is not that. The same argument
-- put token_legs on the receipt in 006 rather than reconstructing it later.
--
-- Nullable, and the renderer falls back to 18. Rows written before this column
-- keep exactly the behaviour they have now rather than flipping to a different
-- wrong number, and only re-indexing from chain can populate them honestly.

alter table public.rebalances
  add column if not exists nav_decimals smallint;

comment on column public.rebalances.nav_decimals is
  'Decimals of the unit nav_per_share is denominated in: asset() for spot and '
  'yield, baseAsset() for rotation. Null on rows indexed before migration 007, '
  'where the renderer falls back to 18.';
