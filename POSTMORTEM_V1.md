# V1 Engineering Post-Mortem & Public Disclosure

We believe non-custodial infrastructure earns trust by documenting its mistakes openly rather than hiding behind upgradeable admin proxies. On November 24–25, 2026, we deployed Timberline V1 to Base Mainnet and launched `$TMBR` (`0x8dc39de1EA51E50AadD1B6179143c9119681A817`) as a live Genesis Proof-of-Concept before onboarding external builders.

**Zero external user funds or locked LP principal were ever at risk or lost.** Position NFT `#3251586` (`1,000 USDC` + `1,000,000 TMBR` initial seed) remains 100% locked inside Uniswap v4 `PoolManager` until `2026-12-24 22:02:27 UTC`. However, live mainnet execution and an internal line-by-line review exposed five issues that require a full, immutable V2 redeployment.

---

## 1. Unused-Quote Refund Balance Sweep (`$55.013232 USDC` Harvested Fee Skim)
* **Incident:** In Base Mainnet tx `0xc593b263b6712d781ae072ea5d5b4f5a100eeb1393d9ba742f17e796e2eb3f55` (Block `61989860`, `2026-11-25 06:32:27 UTC`), an MEV searcher (`0xe6cbe3ad0ac40c68f2f70a27ce98568c4669eb05`) chained two calls in one atomic transaction:
  1. Called `harvestLpFees()` on Position `#3251586`, moving `55.013232 USDC` and `13,045.150471 TMBR` of accrued LP swap fees from Uniswap v4 `PoolManager` onto `TimberlineLaunchpad`'s balance sheet (`claimableFees`).
  2. Called `launchExistingToken()` with `1,000 USDC` and an out-of-range `initialSqrtPriceX96` that consumed `0 USDC` in `PoolManager`, triggering an unused-quote refund that read `IERC20(USDC).balanceOf(address(this))` instead of the caller's exact deposit delta—sending `1,055.013232 USDC` (`1,000 USDC` deposit + `55.013232 USDC` harvested fees) back to the caller.
* **V2 Fix:**
  1. Track exact pre/post balance deltas (`balAfter - balBefore`) around `PositionManager.mint` so unused-quote refunds can never sweep unrelated contract balances.
  2. Require `actualQuoteDeposited >= MIN_SEED` inside `PoolManager` so out-of-range ticks (`0 USDC` settled) revert at launch.
  3. Push harvested LP fees directly to `feeRecipients` inside `_harvestLpFees()` rather than holding idle tokens on the launchpad contract.

## 2. Permanent `2.50%` Default Block Volume Cap (`$25` Swap Ceiling)
* **Issue:** When `maxBlockQuoteVolume == 0`, V1 `TimberlineLaunchpad` defaulted to `DEFAULT_BLOCK_CAP_BPS = 250` (`2.50%` of initial seed per block = `$25.00` on a `$1,000` pool), and V1 `TimberlineHook` enforced that cap permanently for the life of the pool.
* **V2 Fix:** Expire `maxBlockQuoteVolume` automatically once `block.timestamp >= endSnipeTime` so post-launch trading scales without artificial swap ceilings.

## 3. Block-1 JIT Liquidity Siphoning
* **Issue:** Because `beforeAddLiquidity` was disabled in V1 `TimberlineHook`, an MEV bot could bundle a Just-In-Time (JIT) concentrated liquidity add right ahead of a Block-1 swap to capture the majority of the `85%` LP sniper tax and remove liquidity in the same block.
* **V2 Fix:** Enable `beforeAddLiquidity` strictly during the sniper decay window (`block.timestamp < endSnipeTime`) to block external liquidity additions until decay completes, guaranteeing `85%` of sniper taxes accrue exclusively to the locked genesis LP position.

## 4. Trade-Count EMA Stall on Quiet Pools
* **Issue:** V1 `TimberlineHook` updated its LVR EMA by a fixed `1%` (`EMA_ALPHA_BPS = 100`) per active traded block rather than elapsed wall-clock time—allowing quiet pools to remain pinned near the `2.65%` combined fee ceiling after a price move or be nudged via 1-wei dust swaps.
* **V2 Fix:** Replace block-count stepping with elapsed-time exponential decay using `block.timestamp`, and include the LVR Volatility Shield as a **free, standard feature** on every launch (`PRO_LVR_FEE` removed).

## 5. Unharvested LP Fees on `unlockLp()` & Unrecorded `devBuy`
* **Issue:** Calling `unlockLp()` transferred the Uniswap v4 Position NFT (and any unharvested fees attached to it) to `recipient` without harvesting pending fees for co-`feeRecipients` first, and `ProvenanceCertificate` did not expose atomic `devBuyQuoteAmount` / `devBuyTokensBought`.
* **V2 Fix:** Invoke `_harvestLpFees(launchId)` automatically inside `unlockLp()` before transferring the NFT, and store `devBuy` execution figures directly in `LaunchRecord` and `ProvenanceCertificate`.
