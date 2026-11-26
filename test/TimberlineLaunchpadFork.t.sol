// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TimberlineHook} from "../src/TimberlineHook.sol";
import {
    TimberlineTokenDeployer,
    TimberlineGovernanceToken,
    TimberlineSuperchainToken,
    IERC7802
} from "../src/TimberlineTokens.sol";
import {TimberlineLaunchpad} from "../src/TimberlineLaunchpad.sol";
import {TimberlineVault} from "../src/TimberlineVault.sol";
import {TimberlineProvenance} from "../src/TimberlineProvenance.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract CleanExternalToken is ERC20 {
    constructor(uint256 supply, address to) ERC20("External Utility", "EXTU") {
        _mint(to, supply);
    }
}

contract FeeOnTransferMock is ERC20 {
    constructor(uint256 supply, address to) ERC20("Skim Token", "SKIM") {
        _mint(to, supply);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("REJECT_ETH");
    }
}

contract TimberlineLaunchpadForkTest is Test {
    using CurrencyLibrary for Currency;

    address constant POOL_MANAGER_ADDR = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant POSM_ADDR = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC_ADDR = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant VAULT_ADDR = 0x4F779e316e29D97F5c090499ab8672a48c7CE7A4;
    address constant SUPERCHAIN_BRIDGE = 0x4200000000000000000000000000000000000028;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_PRICE_05ETH_1M = 112045541949572279837463876454916;
    uint160 constant SQRT_PRICE_1000USDC_1M = 2505414483750479311864138015696;

    TimberlineHook hook;
    TimberlineTokenDeployer tokenDeployer;
    TimberlineVault vault;
    TimberlineLaunchpad launchpad;
    TimberlineProvenance provenance;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    address creator = makeAddr("ectsCreator");
    address safeMultisig2of3 = makeAddr("safeMultisig2of3");
    address safeMultisig3of5 = makeAddr("safeMultisig3of5");
    address coFounder = makeAddr("coFounder");
    address treasuryWallet = makeAddr("projectTreasury");
    address attacker = makeAddr("attacker");
    address trader = makeAddr("ectsTrader");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        uint64 nonce = vm.getNonce(address(this));
        address predictedLaunchpad = vm.computeCreateAddress(address(this), nonce + 3);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address expectedHook, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(TimberlineHook).creationCode,
            abi.encode(POOL_MANAGER_ADDR, predictedLaunchpad, VAULT_ADDR)
        );

        hook = new TimberlineHook{salt: salt}(IPoolManager(POOL_MANAGER_ADDR), predictedLaunchpad, VAULT_ADDR);
        vault = new TimberlineVault(
            IPoolManager(POOL_MANAGER_ADDR),
            IPositionManager(POSM_ADDR),
            IAllowanceTransfer(PERMIT2_ADDR),
            predictedLaunchpad
        );
        tokenDeployer = new TimberlineTokenDeployer(predictedLaunchpad);
        launchpad = new TimberlineLaunchpad(
            IPoolManager(POOL_MANAGER_ADDR),
            IPositionManager(POSM_ADDR),
            IAllowanceTransfer(PERMIT2_ADDR),
            hook,
            tokenDeployer,
            vault,
            VAULT_ADDR,
            USDC_ADDR
        );

        require(address(hook) == expectedHook, "HOOK_ADDR_MISMATCH");
        require(address(launchpad) == predictedLaunchpad, "LAUNCHPAD_ADDR_MISMATCH");
        provenance = new TimberlineProvenance(launchpad, vault);

        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER_ADDR));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER_ADDR));

        vm.deal(creator, 50 ether);
        vm.deal(safeMultisig2of3, 50 ether);
        vm.deal(attacker, 50 ether);
        vm.deal(trader, 50 ether);
    }

    function _sqrtPriceForUsdc1000To1M(address token) internal pure returns (uint160) {
        return uint160(USDC_ADDR) < uint160(token)
            ? 2505414483750479311864138015696
            : 2505414483750479311864138015;
    }

    function _defaultEthPoolConfig() internal view returns (TimberlineLaunchpad.PoolLaunchConfig memory cfg) {
        address[] memory recipients = new address[](2);
        recipients[0] = creator;
        recipients[1] = coFounder;

        uint16[] memory shares = new uint16[](2);
        shares[0] = 7_000;
        shares[1] = 3_000;

        cfg = TimberlineLaunchpad.PoolLaunchConfig({
            creator: address(0),
            quoteToken: address(0),
            poolTokenAmount: 1_000_000e18,
            quoteTokenAmount: 0.5 ether,
            sqrtPriceX96: SQRT_PRICE_05ETH_1M,
            tickLower: -887220,
            tickUpper: 887220,
            baseLpFeePips: 5_000, // 50 bps creator tier
            snipePreset: TimberlineHook.SnipePreset.HIGH_GUARD,
            maxBlockQuoteVolume: 0,
            lpLockDuration: 30 days,
            lpVestingDuration: 0,
            vestingTranches: new TimberlineVault.VestingTrancheInput[](0),
            devBuyQuoteAmount: 0,
            minDevBuyTokensOut: 0,
            devBuyRecipient: address(0),
            feeRecipients: recipients,
            feeSharesBps: shares
        });
    }

    // =========================================================================
    // 1. V2 CORE LIFECYCLE, AUTO-HARVEST ON UNLOCK & FREE LVR SHIELD
    // =========================================================================

    function testFork_V2EthLaunchFeeTierAutoHarvestOnUnlockAndFreeLvr() public {
        uint256 vaultBefore = VAULT_ADDR.balance;

        vm.prank(creator);
        (uint256 launchId, address token, PoolId poolId, uint256 lpTokenId) = launchpad.launchNewToken{
            value: 0.5 ether
        }(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Timberline V2 Alpha",
                symbol: "TV2A",
                totalSupply: 1_000_000e18,
                salt: keccak256("ALPHA_V2"),
                pool: _defaultEthPoolConfig()
            })
        );

        // Zero upfront Pro LVR fee in V2
        assertEq(VAULT_ADDR.balance, vaultBefore, "No upfront LVR fee charged in V2");
        assertEq(IERC721Owner(POSM_ADDR).ownerOf(lpTokenId), address(vault), "LP NFT locked in vault");

        TimberlineProvenance.ProvenanceCertificate memory cert = provenance.getLaunchCertificateByToken(token);
        assertEq(cert.launchId, launchId);
        assertEq(PoolId.unwrap(cert.poolId), PoolId.unwrap(poolId));
        assertEq(cert.baseLpFeePips, 5_000);
        assertEq(cert.pairedSupplyBps, 10_000);
        assertTrue(cert.isNativeBlueprint);
        assertFalse(cert.lpUnlocked);

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Swap after sniper decay finishes to test steady-state 50 bps LP + 15 bps hook fee
        vm.warp(vm.getBlockTimestamp() + 200);
        vm.prank(trader);
        swapRouter.swap{value: 0.02 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.02 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        // Sweep Treasury's 15 bps quote-only hook fee
        hook.withdrawFees(CurrencyLibrary.ADDRESS_ZERO);
        assertGt(VAULT_ADDR.balance, vaultBefore, "Treasury collects 15 bps hook fee");

        // Warp past 30d lock WITHOUT calling harvestLpFees first; unlockLp must auto-harvest for coFounder
        vm.warp(vm.getBlockTimestamp() + 30 days + 1);
        vm.prank(creator);
        vault.unlockLp(launchId, creator);
        assertEq(IERC721Owner(POSM_ADDR).ownerOf(lpTokenId), creator);

        uint256 coFounderClaimable = vault.claimableFees(launchId, coFounder, CurrencyLibrary.ADDRESS_ZERO);
        assertGt(coFounderClaimable, 0, "unlockLp must auto-harvest accrued fees for co-recipients");

        uint256 coFounderBefore = coFounder.balance;
        vm.prank(coFounder);
        vault.claimFees(launchId, CurrencyLibrary.ADDRESS_ZERO);
        assertEq(coFounder.balance - coFounderBefore, coFounderClaimable);
    }

    // =========================================================================
    // 2. MULTI-TRANCHE CAP-TABLE VESTING & SUPERCHAIN ERC-7802 + CREATE2
    // =========================================================================

    function testFork_V2MultiTrancheVestingAndSuperchainCreate2() public {
        TimberlineVault.VestingTrancheInput[] memory tranches = new TimberlineVault.VestingTrancheInput[](2);
        tranches[0] = TimberlineVault.VestingTrancheInput({
            beneficiary: coFounder,
            amount: 200_000e18,
            cliffDuration: 14 days,
            vestingDuration: 60 days
        });
        tranches[1] = TimberlineVault.VestingTrancheInput({
            beneficiary: treasuryWallet,
            amount: 100_000e18,
            cliffDuration: 30 days,
            vestingDuration: 90 days
        });

        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.poolTokenAmount = 700_000e18;
        cfg.sqrtPriceX96 = 93744028492578283401476445896704;
        cfg.vestingTranches = tranches;

        bytes32 userSalt = keccak256("SUPERCHAIN_TGE_V2");
        address predictedToken = tokenDeployer.computeTokenAddress(
            TimberlineTokenDeployer.Blueprint.SUPERCHAIN,
            "Timberline Superchain",
            "TSUP",
            1_000_000e18,
            creator,
            userSalt
        );

        vm.prank(creator);
        (uint256 launchId, address token,,) = launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.SUPERCHAIN,
                name: "Timberline Superchain",
                symbol: "TSUP",
                totalSupply: 1_000_000e18,
                salt: userSalt,
                pool: cfg
            })
        );

        assertEq(token, predictedToken, "CREATE2 token address must match deterministic prediction");
        assertEq(IERC20(token).balanceOf(creator), 0, "Zero Block-1 creator free float");
        assertTrue(TimberlineSuperchainToken(token).supportsInterface(type(IERC7802).interfaceId));

        // Verify ERC-7802 SuperchainTokenBridge access control
        vm.prank(attacker);
        vm.expectRevert(TimberlineSuperchainToken.UnauthorizedSuperchainBridge.selector);
        TimberlineSuperchainToken(token).crosschainMint(attacker, 100e18);

        vm.prank(SUPERCHAIN_BRIDGE);
        TimberlineSuperchainToken(token).crosschainMint(trader, 500e18);
        assertEq(IERC20(token).balanceOf(trader), 500e18);

        vm.prank(SUPERCHAIN_BRIDGE);
        TimberlineSuperchainToken(token).crosschainBurn(trader, 500e18);
        assertEq(IERC20(token).balanceOf(trader), 0);

        // Verify multi-tranche cliff & linear claims at Day 29 (Tranche 0 unlocked 15/60d; Tranche 1 still in 30d cliff)
        vm.warp(vm.getBlockTimestamp() + 29 days);
        vm.prank(coFounder);
        uint256 claimedCoFounder = vault.claimAllVestedTokens(launchId);
        assertApproxEqAbs(claimedCoFounder, 50_000e18, 2_000);
        assertEq(vault.getClaimableVested(launchId, 1), 0, "Tranche 1 still in 30d cliff");

        vm.warp(vm.getBlockTimestamp() + 120 days);
        vm.prank(coFounder);
        vault.claimAllVestedTokens(launchId);
        vm.prank(treasuryWallet);
        vault.claimAllVestedTokens(launchId);

        uint256 tranche0Total = provenance.getLaunchCertificate(launchId).vestingTranches[0].totalAmount;
        assertGe(tranche0Total, 200_000e18);
        assertEq(IERC20(token).balanceOf(coFounder), tranche0Total, "Tranche 0 absorbs tick-rounding dust for zero free float");
        assertEq(IERC20(token).balanceOf(treasuryWallet), 100_000e18);
    }

    // =========================================================================
    // 3. ERC-6372 TIMESTAMP GOVERNANCE & HONEST DEV BUY PROVENANCE SEAL
    // =========================================================================

    function testFork_V2GovernanceTimestampClockAndHonestDevBuySeal() public {
        deal(USDC_ADDR, creator, 2_000e6);

        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        bytes32 govSalt = keccak256("GOV_V2");
        address predictedGov = tokenDeployer.computeTokenAddress(
            TimberlineTokenDeployer.Blueprint.GOVERNANCE,
            "Timberline Gov V2",
            "TGV2",
            1_000_000e6,
            creator,
            govSalt
        );
        cfg.quoteToken = USDC_ADDR;
        cfg.poolTokenAmount = 1_000_000e6;
        cfg.quoteTokenAmount = 1_000e6;
        cfg.sqrtPriceX96 = _sqrtPriceForUsdc1000To1M(predictedGov);
        cfg.baseLpFeePips = 10_000; // 100 bps creator tier
        cfg.devBuyQuoteAmount = 25e6;
        cfg.minDevBuyTokensOut = 1;
        cfg.devBuyRecipient = creator;

        vm.startPrank(creator);
        IERC20(USDC_ADDR).approve(address(launchpad), type(uint256).max);
        (, address token,,) = launchpad.launchNewToken(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.GOVERNANCE,
                name: "Timberline Gov V2",
                symbol: "TGV2",
                totalSupply: 1_000_000e6,
                salt: govSalt,
                pool: cfg
            })
        );

        uint256 bought = IERC20(token).balanceOf(creator);
        assertGt(bought, 0);

        TimberlineProvenance.ProvenanceCertificate memory cert = provenance.getLaunchCertificateByToken(token);
        assertEq(cert.baseLpFeePips, 10_000);
        assertEq(cert.devBuyQuoteAmount, 25e6, "Provenance Seal must disclose devBuy quote spent");
        assertGt(cert.devBuyTokensBought, 0);
        assertApproxEqAbs(bought, cert.devBuyTokensBought, 100, "Provenance Seal must disclose devBuy tokens bought");

        assertEq(TimberlineGovernanceToken(token).CLOCK_MODE(), "mode=timestamp");
        assertEq(TimberlineGovernanceToken(token).clock(), uint48(block.timestamp));

        TimberlineGovernanceToken(token).delegate(creator);
        assertEq(TimberlineGovernanceToken(token).getVotes(creator), bought);
        vm.stopPrank();
    }

    // =========================================================================
    // 4. SAFE MULTISIG HANDOFFS (2/3 -> 3/5) & ON-CHAIN DISCLOSURE HASHES
    // =========================================================================

    function testFork_V2SafeMultisigHandoffAndDisclosureHashes() public {
        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.creator = safeMultisig2of3;

        vm.prank(creator);
        (uint256 launchId, address token,,) = launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Safe Protocol",
                symbol: "SAFE",
                totalSupply: 1_000_000e18,
                salt: keccak256("SAFE_V2"),
                pool: cfg
            })
        );

        assertEq(provenance.getLaunchCertificateByToken(token).creator, safeMultisig2of3);

        // Two-step transfer from 2/3 Safe to 3/5 Safe
        vm.prank(safeMultisig2of3);
        vault.proposeCreator(launchId, safeMultisig3of5);
        assertEq(vault.pendingCreator(launchId), safeMultisig3of5);

        vm.prank(attacker);
        vm.expectRevert(TimberlineVault.OnlyPendingCreator.selector);
        vault.acceptCreator(launchId);

        vm.prank(safeMultisig3of5);
        vault.acceptCreator(launchId);
        assertEq(provenance.getLaunchCertificateByToken(token).creator, safeMultisig3of5);

        // Anchor immutable audit report hash onto Provenance Seal
        bytes32 auditHash = keccak256("Spearbit-Cantina-Timberline-V2-Audit-Report");
        vm.prank(safeMultisig3of5);
        vault.addDisclosureHash(launchId, auditHash, "Security Review Report");

        TimberlineProvenance.ProvenanceCertificate memory cert = provenance.getLaunchCertificateByToken(token);
        assertEq(cert.disclosures.length, 1);
        assertEq(cert.disclosures[0].docHash, auditHash);
    }

    // =========================================================================
    // 5. AUTO-COMPOUNDING POL & STAGED LINEAR LP UNLOCK
    // =========================================================================

    function testFork_V2AutoCompoundLpFeesAndLinearLpUnlock() public {
        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.lpLockDuration = 30 days;
        cfg.lpVestingDuration = 60 days; // Linear principal unlock from Day 30 to Day 90

        vm.prank(creator);
        (uint256 launchId, address token,,) = launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Linear POL",
                symbol: "LPOL",
                totalSupply: 1_000_000e18,
                salt: keccak256("LINEAR_POL"),
                pool: cfg
            })
        );

        uint128 initialLiq = provenance.getLaunchCertificate(launchId).initialLiquidity;

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Two-way swaps accrue both ETH and token fees
        vm.warp(vm.getBlockTimestamp() + 200);
        vm.startPrank(trader);
        swapRouter.swap{value: 0.05 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.05 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -20_000e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();

        // Permissionlessly auto-compound accrued fees back into locked Position NFT
        (uint128 addedLiq,,) = vault.compoundLpFees(launchId);
        assertGt(addedLiq, 0, "Auto-compound must increase locked LP liquidity");
        assertEq(provenance.getLaunchCertificate(launchId).initialLiquidity, initialLiq + addedLiq);

        // At Day 60 (midpoint of 30d..90d linear LP unlock), creator withdraws ~50% of principal
        vm.warp(vm.getBlockTimestamp() + 30 days + 30 days);
        vm.prank(creator);
        uint128 removed = vault.withdrawLinearLp(launchId, creator);
        assertApproxEqRel(removed, (initialLiq + addedLiq) / 2, 0.02e18);
    }

    // =========================================================================
    // 6. BLOCK-1 JIT LP LOCK, EXPIRING CAP & V1 REFUND-DELTA REGRESSION
    // =========================================================================

    function testFork_V2JitLiquidityBlockedDuringDecayAndBlockCapExpires() public {
        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.snipePreset = TimberlineHook.SnipePreset.FORTRESS; // 60% start, 300s decay
        cfg.maxBlockQuoteVolume = 0.025 ether; // 5% of 0.5 ETH during launch window

        vm.prank(creator);
        (, address token,,) = launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Fortress Token",
                symbol: "FORT",
                totalSupply: 1_000_000e18,
                salt: keccak256("FORTRESS_V2"),
                pool: cfg
            })
        );

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // External JIT LP addition during 300s decay window must revert
        deal(token, attacker, 100_000e18);
        vm.startPrank(attacker);
        IERC20(token).approve(address(lpRouter), type(uint256).max);
        vm.expectRevert();
        lpRouter.modifyLiquidity{value: 0.1 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 1e15,
                salt: bytes32(0)
            }),
            bytes("")
        );
        vm.stopPrank();

        // After 300s decay expires, both external LP and swaps > 0.025 ETH succeed cleanly
        vm.warp(vm.getBlockTimestamp() + 301);
        vm.prank(attacker);
        lpRouter.modifyLiquidity{value: 0.1 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 1e15,
                salt: bytes32(0)
            }),
            bytes("")
        );

        vm.prank(trader);
        swapRouter.swap{value: 0.05 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.05 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function testFork_V2DeltaSafeRefundsPreventHarvestedFeeSweep() public {
        deal(USDC_ADDR, creator, 5_000e6);
        deal(USDC_ADDR, attacker, 5_000e6);

        bytes32 salt1 = keccak256("PROT_1");
        address pred1 = tokenDeployer.computeTokenAddress(
            TimberlineTokenDeployer.Blueprint.STANDARD,
            "Protected Pool",
            "PROT",
            1_000_000e6,
            creator,
            salt1
        );
        TimberlineLaunchpad.PoolLaunchConfig memory cfg1 = _defaultEthPoolConfig();
        cfg1.quoteToken = USDC_ADDR;
        cfg1.poolTokenAmount = 1_000_000e6;
        cfg1.quoteTokenAmount = 1_000e6;
        cfg1.sqrtPriceX96 = _sqrtPriceForUsdc1000To1M(pred1);

        vm.startPrank(creator);
        IERC20(USDC_ADDR).approve(address(launchpad), type(uint256).max);
        (uint256 launchId1, address token1,,) = launchpad.launchNewToken(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Protected Pool",
                symbol: "PROT",
                totalSupply: 1_000_000e6,
                salt: salt1,
                pool: cfg1
            })
        );
        vm.stopPrank();

        bool usdcIs0 = uint160(USDC_ADDR) < uint160(token1);
        PoolKey memory key1 = PoolKey({
            currency0: usdcIs0 ? Currency.wrap(USDC_ADDR) : Currency.wrap(token1),
            currency1: usdcIs0 ? Currency.wrap(token1) : Currency.wrap(USDC_ADDR),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Generate swap fees on Launch #1 and harvest them onto TimberlineLaunchpad
        vm.warp(vm.getBlockTimestamp() + 200);
        vm.startPrank(trader);
        deal(USDC_ADDR, trader, 500e6);
        IERC20(USDC_ADDR).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key1,
            IPoolManager.SwapParams({
                zeroForOne: usdcIs0,
                amountSpecified: -100e6,
                sqrtPriceLimitX96: usdcIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();

        (uint256 earned0, uint256 earned1) = vault.harvestLpFees(launchId1);
        uint256 harvestedUsdc = usdcIs0 ? earned0 : earned1;
        assertGt(harvestedUsdc, 0);

        // Attacker launches Launch #2 while harvestedUsdc sits in launchpad; Launch #1 fees stay 100% intact
        bytes32 salt2 = keccak256("SECD_2");
        address pred2 = tokenDeployer.computeTokenAddress(
            TimberlineTokenDeployer.Blueprint.STANDARD,
            "Second Pool",
            "SECD",
            1_000_000e6,
            attacker,
            salt2
        );
        TimberlineLaunchpad.PoolLaunchConfig memory cfg2 = _defaultEthPoolConfig();
        cfg2.quoteToken = USDC_ADDR;
        cfg2.poolTokenAmount = 1_000_000e6;
        cfg2.quoteTokenAmount = 1_000e6;
        cfg2.sqrtPriceX96 = _sqrtPriceForUsdc1000To1M(pred2);

        vm.startPrank(attacker);
        IERC20(USDC_ADDR).approve(address(launchpad), type(uint256).max);
        launchpad.launchNewToken(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Second Pool",
                symbol: "SECD",
                totalSupply: 1_000_000e6,
                salt: salt2,
                pool: cfg2
            })
        );
        vm.stopPrank();

        assertEq(
            IERC20(USDC_ADDR).balanceOf(address(vault)),
            harvestedUsdc,
            "Harvested USDC from Launch #1 must remain isolated in TimberlineVault"
        );
        assertEq(
            IERC20(USDC_ADDR).balanceOf(address(launchpad)),
            0,
            "Launchpad must retain zero residual USDC after Launch #2 delta refund"
        );
    }

    // =========================================================================
    // 7. ADVERSARIAL & GUARDRAIL REVERT TESTS
    // =========================================================================

    function testFork_RevertWhen_InvalidBaseLpFeeOrSeedOrLock() public {
        TimberlineLaunchpad.PoolLaunchConfig memory badFee = _defaultEthPoolConfig();
        badFee.baseLpFeePips = 2_500; // 25 bps not allowed

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InvalidBaseLpFee.selector);
        launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "BadFee",
                symbol: "BFEE",
                totalSupply: 1_000_000e18,
                salt: bytes32(uint256(1)),
                pool: badFee
            })
        );

        TimberlineLaunchpad.PoolLaunchConfig memory lowEth = _defaultEthPoolConfig();
        lowEth.quoteTokenAmount = 0.499 ether;
        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InsufficientSeedLiquidity.selector);
        launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "LowEth",
                symbol: "LETH",
                totalSupply: 1_000_000e18,
                salt: bytes32(uint256(2)),
                pool: lowEth
            })
        );

        TimberlineLaunchpad.PoolLaunchConfig memory shortLock = _defaultEthPoolConfig();
        shortLock.lpLockDuration = 30 days - 1;
        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InvalidLpLockDuration.selector);
        launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "ShortLock",
                symbol: "SLCK",
                totalSupply: 1_000_000e18,
                salt: bytes32(uint256(3)),
                pool: shortLock
            })
        );
    }

    function testFork_RevertWhen_PriceRangeMismatchOrFeeOnTransfer() public {
        TimberlineLaunchpad.PoolLaunchConfig memory skewedPrice = _defaultEthPoolConfig();
        skewedPrice.sqrtPriceX96 = SQRT_PRICE_1_1;

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.PriceRangeMismatch.selector);
        launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Skewed",
                symbol: "SKWD",
                totalSupply: 1_000_000e18,
                salt: bytes32(uint256(4)),
                pool: skewedPrice
            })
        );

        vm.startPrank(creator);
        FeeOnTransferMock skimToken = new FeeOnTransferMock(1_000_000e18, creator);
        skimToken.approve(address(launchpad), type(uint256).max);

        vm.expectRevert(TimberlineLaunchpad.FeeOnTransferUnsupported.selector);
        launchpad.launchExistingToken{value: 0.5 ether}(
            TimberlineLaunchpad.ExistingTokenLaunchParams({
                token: address(skimToken),
                totalSupply: 1_000_000e18,
                pool: _defaultEthPoolConfig()
            })
        );
        vm.stopPrank();
    }

    function testFork_RevertWhen_DirectCallerBypassesLaunchpad() public {
        vm.prank(attacker);
        vm.expectRevert(TimberlineTokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deployToken(
            TimberlineTokenDeployer.Blueprint.STANDARD,
            "Rogue",
            "RGUE",
            1_000_000e18,
            attacker,
            attacker,
            bytes32(0)
        );

        PoolKey memory dummyKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(USDC_ADDR),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.prank(attacker);
        vm.expectRevert(TimberlineHook.OnlyFactory.selector);
        hook.registerPoolConfig(dummyKey, attacker, true, 3_000, TimberlineHook.SnipePreset.STANDARD, 1 ether);
    }
}
