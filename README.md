# Timberline Protocol (`timberline-v4`)

**Non-Custodial Exclusive Concierge Token Service (ECTS) for Uniswap v4 on Base Mainnet (`8453`).**

Timberline provides audited, zero-admin token blueprints, deterministic `CREATE2` deployment, Uniswap v4 liquidity locking, multi-tranche cap-table vesting, Block-1 anti-snipe protection, and wall-clock Loss-Versus-Rebalancing (LVR) protection—with **zero admin keys, zero proxy upgradeability, and zero custody of user funds**.

## Core Architectural Invariants
1. **Zero Admin or Custody Backdoors:** No `Ownable`, no upgradeable proxies, no pause switches, and no emergency sweep functions. Once an LP Position NFT or vested token allocation enters `TimberlineLaunchpad`, it can only exit via on-chain timestamp expiry to the designated creator/Safe or beneficiary.
2. **State-Compiled Provenance Seal:** `getLaunchCertificateByToken(address)` compiles launch configuration, LP lock expiry, multi-tranche vesting schedules, atomic `devBuy` disclosures, fee splits, and audit hashes directly from Base Mainnet state.
3. **Immutable Upgrades via Full Redeploy:** Because deployed contracts cannot be mutated, security and economic upgrades ship as clean, full-suite redeployments with full public changelogs.

## Live Deployments (Base Mainnet — Chain ID `8453`)

### V1 Genesis Proof-of-Concept (Legacy — Superseded by V2)
* **Status:** Active for Genesis Showcase (`$TMBR`) until LP lock expiry on **2026-12-24 22:02:27 UTC**; deprecated for new launches. See [`POSTMORTEM_V1.md`](./POSTMORTEM_V1.md) for full engineering disclosure.
* **`TimberlineHook` v1:** `0x22BE8cDE1ab03be3E82C00dd2689E49b1edD20cc`
* **`TimberlineLaunchpad` v1:** `0x3791c1acce47A6763CCc9811922B2F8d611926d1`
* **`TimberlineTokenDeployer` v1:** `0x0ffCE9600FF889046183C35e5AA3835107367D52`
* **Genesis Showcase Token (`$TMBR` v1):** `0x8dc39de1EA51E50AadD1B6179143c9119681A817` (Uniswap v4 Position NFT `#3251586`)
* **Protocol Treasury:** `0x4F779e316e29D97F5c090499ab8672a48c7CE7A4`

### V2 Production Suite (`v2.0.0` — In Development)
* Tracked in [`ROADMAP_V2.md`](./ROADMAP_V2.md). Contract addresses will be published upon `v2.0.0-freeze` audit completion and BaseScan / Sourcify Exact-Match verification.
