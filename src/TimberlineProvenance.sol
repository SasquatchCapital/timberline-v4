// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TimberlineHook} from "./TimberlineHook.sol";
import {TimberlineTokenDeployer} from "./TimberlineTokens.sol";
import {TimberlineLaunchpad} from "./TimberlineLaunchpad.sol";
import {TimberlineVault} from "./TimberlineVault.sol";

/// @title TimberlineProvenance
/// @notice Immutable, zero-admin on-chain Provenance Seal reader compiling full launch,
///         liquidity lock, vesting, fee-split, and disclosure proofs in one RPC call.
contract TimberlineProvenance {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct ProvenanceCertificate {
        uint256 launchId;
        address launchToken;
        address quoteToken;
        PoolId poolId;
        uint256 lpTokenId;
        address creator;
        address pendingCreator;
        TimberlineTokenDeployer.Blueprint blueprint;
        bool isNativeBlueprint;
        bool lpUnlocked;
        uint24 baseLpFeePips;
        TimberlineHook.SnipePreset snipePreset;
        uint256 totalSupply;
        uint256 poolTokenAmount;
        uint256 initialQuoteAmount;
        uint256 pairedSupplyBps;
        uint128 initialLiquidity;
        uint128 liquidityWithdrawn;
        uint64 lpUnlockTime;
        uint64 lpVestingEnd;
        uint256 vestedTotal;
        uint256 devBuyQuoteAmount;
        uint256 devBuyTokensBought;
        address hookAddress;
        address vaultAddress;
        address treasuryAddress;
        address[] feeRecipients;
        uint16[] feeSharesBps;
        TimberlineVault.VestingTranche[] vestingTranches;
        TimberlineVault.DisclosureRecord[] disclosures;
    }

    TimberlineLaunchpad public immutable LAUNCHPAD;
    TimberlineVault public immutable VAULT;

    error InvalidLaunchId();

    constructor(TimberlineLaunchpad _launchpad, TimberlineVault _vault) {
        require(address(_launchpad) != address(0) && address(_vault) != address(0), "ZERO_ADDR");
        LAUNCHPAD = _launchpad;
        VAULT = _vault;
    }

    function getLaunchCertificate(uint256 launchId) public view returns (ProvenanceCertificate memory cert) {
        TimberlineLaunchpad.LaunchRecord memory rec = LAUNCHPAD.getLaunchRecord(launchId);
        if (rec.launchId == 0) revert InvalidLaunchId();
        TimberlineVault.VaultRecord memory v = VAULT.getVaultRecord(launchId);

        uint256 pairedBps = (rec.poolTokenAmount * BPS_DENOMINATOR) / rec.totalSupply;
        cert = ProvenanceCertificate({
            launchId: rec.launchId,
            launchToken: rec.launchToken,
            quoteToken: rec.quoteToken,
            poolId: rec.poolId,
            lpTokenId: rec.lpTokenId,
            creator: v.creator,
            pendingCreator: VAULT.pendingCreator(launchId),
            blueprint: rec.blueprint,
            isNativeBlueprint: rec.isNativeBlueprint,
            lpUnlocked: v.lpUnlocked,
            baseLpFeePips: rec.baseLpFeePips,
            snipePreset: rec.snipePreset,
            totalSupply: rec.totalSupply,
            poolTokenAmount: rec.poolTokenAmount,
            initialQuoteAmount: rec.initialQuoteAmount,
            pairedSupplyBps: pairedBps,
            initialLiquidity: v.initialLiquidity,
            liquidityWithdrawn: v.liquidityWithdrawn,
            lpUnlockTime: v.lpUnlockTime,
            lpVestingEnd: v.lpVestingEnd,
            vestedTotal: v.vestedTotal,
            devBuyQuoteAmount: rec.devBuyQuoteAmount,
            devBuyTokensBought: rec.devBuyTokensBought,
            hookAddress: address(LAUNCHPAD.HOOK()),
            vaultAddress: address(VAULT),
            treasuryAddress: LAUNCHPAD.TREASURY(),
            feeRecipients: VAULT.getFeeRecipients(launchId),
            feeSharesBps: VAULT.getFeeSharesBps(launchId),
            vestingTranches: VAULT.getVestingTranches(launchId),
            disclosures: VAULT.getDisclosures(launchId)
        });
    }

    function getLaunchCertificateByToken(address token) external view returns (ProvenanceCertificate memory) {
        uint256 id = LAUNCHPAD.launchIdByToken(token);
        if (id == 0) revert InvalidLaunchId();
        return getLaunchCertificate(id);
    }
}
