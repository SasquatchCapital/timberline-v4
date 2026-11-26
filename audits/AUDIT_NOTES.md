# Compiler & Static Linter Explanations (`foundry.toml`)

All Solidity code-level warnings (`encode-packed-collision`, `divide-before-multiply`, and `require-revert-in-loop`) have been resolved directly in `src/`. The following `forge lint` rules are explicitly excluded in `foundry.toml` and documented below for security auditors:

1. **`reentrancy-balance` (`TimberlineLaunchpad.compoundLpFees`)**: `compoundLpFees` is guarded by OpenZeppelin `nonReentrant` and interacts exclusively with Uniswap v4's canonical `PositionManager` to measure exact harvested fee deltas before re-adding liquidity to the locked Position NFT.
2. **`missing-events-access-control` (`TimberlineLaunchpad.acceptCreator` & `unlockCallback`)**:
   - `acceptCreator()` deletes `pendingCreator[launchId]` immediately before emitting `CreatorAccepted(launchId, previous, msg.sender)`.
   - `_pendingDevBuy.active` is a single-transaction callback lock cleared immediately inside `unlockCallback` (not a persistent role or privilege).
3. **`arbitrary-send-eth` (`TimberlineLaunchpad._sendCurrency`)**: `_sendCurrency` is invoked solely by `claimFees(launchId, currency)`, where `to` is hardcoded to `msg.sender` and `amount` is bounded by `claimableFees[launchId][msg.sender][currency]`.
4. **`block-timestamp` & `unsafe-typecast`**: Timestamps (`uint40` / `uint64`) are used intentionally for L2 block-cadence immunity across LP locks, vesting cliffs, sniper decay, and EMA time constants, with explicit bounds checks on all casts.
