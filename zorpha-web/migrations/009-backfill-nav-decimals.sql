-- 009, backfill nav_decimals, and stop rendering a NAV we cannot scale.
--
-- 007 added the column, left old rows null, and had the renderer fall back to
-- 18 so that "rows written before this column keep exactly the behaviour they
-- have now rather than flipping to a different wrong number". That reasoning
-- was about not making things worse. It also left the original wrong number in
-- place, and the public receipts feed still shows it.
--
-- Observed on the live feed today, two receipts down from the current ones:
--
--     rotation  0x15257073…  nav_per_share 1000000  nav_decimals null  -> "0"
--     yield     0x521a90ba…  nav_per_share 3000000  nav_decimals null  -> "0"
--
-- Both are 6-decimal values divided by 10^18. The true figures are 1.0 and 3.0.
-- On the one page whose stated claim is that a manager's record is verifiable
-- and reconstructible from chain, two of the four receipts say the vault was
-- worth nothing. That is not a display nit; it is a false statement about a
-- manager's track record, on the artefact the protocol sells.
--
-- WHERE THESE NUMBERS COME FROM
--
-- Read from the vaults themselves, which are retired but still deployed, so the
-- backfill is recoverable rather than assumed:
--
--     0x521a90ba…  yield     asset() decimals            = 6
--     0x15257073…  rotation  baseDecimals()              = 6   (asset() is 18)
--
-- The rotation vault is worth pausing on, because it is the whole reason this
-- column exists. Its asset() reports 18 -- it is the equity-led vault that 008
-- retired, so asset() was tAAPL -- while its NAV is denominated in its base,
-- tUSDG, at 6. Anything deriving the scale from asset() would get it wrong by
-- twelve orders of magnitude and look entirely reasonable doing it.
--
-- Scoped by address rather than applied to every null, so a future null cannot
-- be silently swept up by a value that was only ever correct for these two.

update public.rebalances set nav_decimals = 6
where nav_decimals is null
  and lower(vault_address) = lower('0x521a90ba9a5afcda27db1bbb9cb93c3a2135b2d5');

update public.rebalances set nav_decimals = 6
where nav_decimals is null
  and lower(vault_address) = lower('0x15257073a761021d37852453d4bde2fba8fcc9e6');

comment on column public.rebalances.nav_decimals is
  'Decimals of the unit nav_per_share is denominated in: asset() for spot and '
  'yield, baseDecimals() for rotation. Backfilled from chain for pre-007 rows '
  'in migration 009. A null now means the scale is genuinely unknown, and the '
  'renderer shows a dash rather than inventing one.';
