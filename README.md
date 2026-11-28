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

### V2 Production Suite (`v2.0.0` — Live on Base Mainnet `8453`)

* **Status:** Active & Verified (5/5 contracts Exact-Match verified on **BaseScan** & **Sourcify**).
* **`TimberlineLaunchpad`:** [`0x4cA076c480e3Af82bD244202495963F8872BF4d1`](https://basescan.org/address/0x4cA076c480e3Af82bD244202495963F8872BF4d1#code)
* **`TimberlineTokenDeployer`:** [`0xC109e67FfB1Db26fF73C3ec8f36E2ec93ED84eCB`](https://basescan.org/address/0xC109e67FfB1Db26fF73C3ec8f36E2ec93ED84eCB#code)
* **`TimberlineVault`:** [`0xA3eafb48926Bb8CA11E14B7Ad82A9f47621FDe12`](https://basescan.org/address/0xA3eafb48926Bb8CA11E14B7Ad82A9f47621FDe12#code)
* **`TimberlineHook`:** [`0x0B7a2797AF22345602b3aF229157F15F22Ae28cc`](https://basescan.org/address/0x0B7a2797AF22345602b3aF229157F15F22Ae28cc#code)
* **`TimberlineProvenance`:** [`0x63b7Cf817aeC8100A2E2F07bC7910e07e8ED8956`](https://basescan.org/address/0x63b7Cf817aeC8100A2E2F07bC7910e07e8ED8956#code)
* **Protocol Treasury:** [`0x4F779e316e29D97F5c090499ab8672a48c7CE7A4`](https://basescan.org/address/0x4F779e316e29D97F5c090499ab8672a48c7CE7A4)
