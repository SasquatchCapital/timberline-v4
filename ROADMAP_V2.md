# Timberline V2 Build & Verification Roadmap

Target window: **November 25 – December 31, 2026** (aligned with V1 `$TMBR` lock expiry on December 24, 2026).

---

## Milestone Log

### [x] Milestone 0 — V1 Genesis Deployment & Post-Mortem (`v1.0.0-genesis`)
- Deployed immutable V1 contracts and `$TMBR` Genesis Showcase (`#3251586`) on Base Mainnet (`8453`).
- Documented V1 accounting and economic findings in [`POSTMORTEM_V1.md`](./POSTMORTEM_V1.md).
- Locked down `.gitignore` and initialized public transparency repository.

### [x] Milestone 1 — `TimberlineHook` v2 (`src/TimberlineHook.sol`)
- [x] Replace `block.number` clocks with `block.timestamp` across sniper decay and LVR EMA.
- [x] Implement elapsed-time exponential EMA decay (`tau` time constant) and make LVR protection **free/standard** on all pools.
- [x] Add creator-selectable base LP swap fee tiers (**`30 bps`**, **`50 bps`**, or **`100 bps`**) with dynamic LVR ceiling (`baseLpFee + 220 bps`) while keeping Timberline's quote-only hook fee fixed at **`15 bps`**.
- [x] Upgrade Block-1 anti-snipe presets to **`15%` (60s)**, **`35%` (180s)**, and **`60%` (300s)** (`85%` locked LP / `15%` Treasury).
- [x] Enable `beforeAddLiquidity` during `block.timestamp < endSnipeTime` to block Block-1 JIT LP fee siphoning.
- [x] Expire `maxBlockQuoteVolume` once `block.timestamp >= endSnipeTime`.
- [x] Move `_pendingUnspecifiedHookFeePips` to Cancun transient storage (`tstore`/`tload`) and use `SafeERC20` in `withdrawFees()`.

### [x] Milestone 2 — `TimberlineTokens` v2 (`src/TimberlineTokens.sol`)
- [x] Retain zero-admin `STANDARD`, `BURNABLE`, and `GOVERNANCE` blueprints.
- [x] Override `ERC20Votes` on `GOVERNANCE` to ERC-6372 `block.timestamp` clock mode.
- [x] Add Blueprint #4: **`SUPERCHAIN` (`SuperchainERC20` / ERC-7802)** restricted strictly to Base's canonical `SuperchainTokenBridge` (`0x4200000000000000000000000000000000000028`).
- [x] Support deterministic `CREATE2` deployment with caller-scoped salts.

### [x] Milestone 3 — `TimberlineLaunchpad` v2 (`src/TimberlineLaunchpad.sol`)
- [x] Remove `PRO_LVR_FEE` (`0.0057 ETH`); activate LVR shield by default.
- [x] Enforce delta-tracked unused-quote refunds (`balAfter - balBefore`) and minimum settled quote liquidity (`actualQuoteDeposited >= MIN_SEED`).
- [x] Auto-harvest inside `unlockLp()` to `feeRecipients` inside `_harvestLpFees()` and auto-harvest inside `unlockLp()`.
- [x] Add optional permissionless `compoundLpFees(launchId)` (`INCREASE_LIQUIDITY` back into locked Position NFT).
- [x] Add multi-tranche cap-table vesting (up to 4 tranches) and optional linear LP principal unlock schedules.
- [x] Add first-class multisig support (explicit `creator` param for 1/1, 2/3, or 3/5 Safe wallets + two-step `proposeCreator` / `acceptCreator`).
- [x] Record `devBuyQuoteAmount` & `devBuyTokensBought` plus append-only audit/disclosure hashes on `ProvenanceCertificate`.

### [ ] Milestone 4 — Foundry Fuzz/Invariant Suite & Audit Freeze (`v2.0.0-freeze`)
- [ ] Unit tests covering all 4 token blueprints, 3 LP fee tiers, 3 anti-snipe presets, and Safe handoffs.
- [ ] Stateful invariant tests proving: (1) LP NFT cannot exit before `lpUnlockTime`, (2) JIT LP reverts during sniper decay, (3) 4-way `ReturnDelta` nets to zero with zero stuck tokens, (4) multi-tranche vesting never over-claims, and (5) wall-clock EMA converges during idle periods.
- [ ] Run **Slither** and **Aderyn** static analysis and commit reports to `/audits/`.
- [ ] Cut immutable tag `v2.0.0-freeze` for independent security review.

### [ ] Milestone 5 — Base Mainnet Full V2 Redeploy & UI Cutover (`v2.0.0-mainnet`)
- [ ] Deploy V2 `TimberlineHook`, `TimberlineTokenDeployer`, and `TimberlineLaunchpad` via precomputed addresses.
- [ ] Verify Exact-Match source code + explicit `MIT` license metadata on BaseScan and Sourcify.
- [ ] Deploy V2 Genesis Showcase token (with explicit zero-utility demonstration disclaimer), wire `timberline-ui` (180-day default lock preset + Safe 1/1–2/3–3/5 wizard), and retire V1 `$TMBR` after `2026-12-24 22:02:27 UTC`.
