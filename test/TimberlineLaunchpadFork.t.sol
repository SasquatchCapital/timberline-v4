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
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TimberlineHook} from "../src/TimberlineHook.sol";
import {TimberlineTokenDeployer, TimberlineGovernanceToken} from "../src/TimberlineTokens.sol";
import {TimberlineLaunchpad} from "../src/TimberlineLaunchpad.sol";

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

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_PRICE_05ETH_1M = 112045541949572279837463876454916;
    uint160 constant SQRT_PRICE_1000USDC_1M = 2505414483750479311864138015696;

    TimberlineHook hook;
    TimberlineTokenDeployer tokenDeployer;
    TimberlineLaunchpad launchpad;
    PoolSwapTest swapRouter;

    address creator = makeAddr("ectsCreator");
    address coFounder = makeAddr("coFounder");
    address treasuryWallet = makeAddr("projectTreasury");
    address attacker = makeAddr("attacker");
    address trader = makeAddr("ectsTrader");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        uint64 nonce = vm.getNonce(address(this));
        address predictedLaunchpad = vm.computeCreateAddress(address(this), nonce + 2);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address expectedHook, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(TimberlineHook).creationCode,
            abi.encode(POOL_MANAGER_ADDR, predictedLaunchpad, VAULT_ADDR)
        );

        hook = new TimberlineHook{salt: salt}(IPoolManager(POOL_MANAGER_ADDR), predictedLaunchpad, VAULT_ADDR);
        tokenDeployer = new TimberlineTokenDeployer(predictedLaunchpad);
        launchpad = new TimberlineLaunchpad(
            IPoolManager(POOL_MANAGER_ADDR),
            IPositionManager(POSM_ADDR),
            IAllowanceTransfer(PERMIT2_ADDR),
            hook,
            tokenDeployer,
            VAULT_ADDR,
            USDC_ADDR
        );

        require(address(hook) == expectedHook, "HOOK_ADDR_MISMATCH");
        require(address(launchpad) == predictedLaunchpad, "LAUNCHPAD_ADDR_MISMATCH");

        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER_ADDR));
        vm.deal(creator, 50 ether);
        vm.deal(attacker, 50 ether);
        vm.deal(trader, 50 ether);
    }

    function _defaultEthPoolConfig() internal view returns (TimberlineLaunchpad.PoolLaunchConfig memory cfg) {
        address[] memory recipients = new address[](2);
        recipients[0] = creator;
        recipients[1] = coFounder;

        uint16[] memory shares = new uint16[](2);
        shares[0] = 7_000;
        shares[1] = 3_000;

        cfg = TimberlineLaunchpad.PoolLaunchConfig({
            quoteToken: address(0),
            poolTokenAmount: 1_000_000e18,
            quoteTokenAmount: 0.5 ether,
            sqrtPriceX96: SQRT_PRICE_05ETH_1M,
            tickLower: -887220,
            tickUpper: 887220,
            snipePreset: TimberlineHook.SnipePreset.HIGH_GUARD,
            proLvrEnabled: true,
            maxBlockQuoteVolume: 0,
            lpLockDuration: 30 days,
            vestingBeneficiary: address(0),
            cliffDuration: 0,
            vestingDuration: 0,
            devBuyQuoteAmount: 0,
            minDevBuyTokensOut: 0,
            devBuyRecipient: address(0),
            feeRecipients: recipients,
            feeSharesBps: shares
        });
    }

    // =========================================================================
    // 1. CORE LIFECYCLE & FEATURE TESTS
    // =========================================================================

    function testFork_StandardEthLaunchLockFeeHarvestAndUnlock() public {
        uint256 vaultBefore = VAULT_ADDR.balance;

        vm.prank(creator);
        (uint256 launchId, address token, PoolId poolId, uint256 lpTokenId) = launchpad.launchNewToken{
            value: 0.5057 ether
        }(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Timberline Alpha",
                symbol: "TALP",
                totalSupply: 1_000_000e18,
                pool: _defaultEthPoolConfig()
            })
        );

        assertEq(VAULT_ADDR.balance - vaultBefore, 0.0057 ether, "Pro LVR fee must reach Timberlinevault");
        assertEq(IERC721Owner(POSM_ADDR).ownerOf(lpTokenId), address(launchpad), "LP NFT must be locked in launchpad");

        TimberlineLaunchpad.ProvenanceCertificate memory cert = launchpad.getLaunchCertificateByToken(token);
        assertEq(cert.launchId, launchId);
        assertEq(PoolId.unwrap(cert.poolId), PoolId.unwrap(poolId));
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

        vm.prank(trader);
        swapRouter.swap{value: 0.01 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        (uint256 earned0,) = launchpad.harvestLpFees(launchId);
        assertGt(earned0, 0, "LP must accrue swap fees");

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        uint256 creatorClaimed = launchpad.claimFees(launchId, CurrencyLibrary.ADDRESS_ZERO);
        assertApproxEqAbs(creatorClaimed, (earned0 * 7_000) / 10_000, 2);
        assertEq(creator.balance - creatorBefore, creatorClaimed);

        uint256 coFounderBefore = coFounder.balance;
        vm.prank(coFounder);
        uint256 coFounderClaimed = launchpad.claimFees(launchId, CurrencyLibrary.ADDRESS_ZERO);
        assertApproxEqAbs(coFounderClaimed, (earned0 * 3_000) / 10_000, 2);
        assertEq(coFounder.balance - coFounderBefore, coFounderClaimed);

        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(creator);
        launchpad.unlockLp(launchId, creator);
        assertEq(IERC721Owner(POSM_ADDR).ownerOf(lpTokenId), creator, "LP NFT must transfer after lock expires");
    }

    function testFork_ZeroFreeFloatLinearVestingAndCliff() public {
        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.poolTokenAmount = 700_000e18;
        // 0.5 ETH : 700,000 tokens => price = 1,400,000 => sqrt(1,400,000) * 2^96
        cfg.sqrtPriceX96 = 93744028492578283401476445896704;
        cfg.vestingBeneficiary = coFounder;
        cfg.cliffDuration = 14 days;
        cfg.vestingDuration = 60 days;

        vm.prank(creator);
        (uint256 launchId, address token,,) = launchpad.launchNewToken{value: 0.5057 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.BURNABLE,
                name: "Timberline Burn",
                symbol: "TBRN",
                totalSupply: 1_000_000e18,
                pool: cfg
            })
        );

        assertEq(IERC20(token).balanceOf(creator), 0, "Zero free-float at launch");
        assertEq(launchpad.getClaimableVested(launchId), 0, "Nothing claimable before cliff");

        vm.expectRevert(TimberlineLaunchpad.NothingToClaim.selector);
        launchpad.claimVestedTokens(launchId);

        vm.warp(block.timestamp + 14 days + 30 days);
        assertApproxEqAbs(launchpad.getClaimableVested(launchId), 150_000e18, 2_000, "Half unlocked at midpoint");

        launchpad.claimVestedTokens(launchId);
        assertApproxEqAbs(IERC20(token).balanceOf(coFounder), 150_000e18, 2_000);

        vm.warp(block.timestamp + 31 days);
        launchpad.claimVestedTokens(launchId);
        assertApproxEqAbs(IERC20(token).balanceOf(coFounder), 300_000e18, 2_000, "Full vested allocation claimed");
    }

    function testFork_GovernanceUsdcPairWithAtomicDevBuy() public {
        deal(USDC_ADDR, creator, 2_000e6);

        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.quoteToken = USDC_ADDR;
        cfg.poolTokenAmount = 1_000_000e6;
        cfg.quoteTokenAmount = 1_000e6;
        cfg.sqrtPriceX96 = SQRT_PRICE_1000USDC_1M;
        cfg.proLvrEnabled = false;
        cfg.devBuyQuoteAmount = 10e6;
        cfg.minDevBuyTokensOut = 1;
        cfg.devBuyRecipient = creator;

        vm.startPrank(creator);
        IERC20(USDC_ADDR).approve(address(launchpad), type(uint256).max);
        (, address token,,) = launchpad.launchNewToken(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.GOVERNANCE,
                name: "Timberline Gov",
                symbol: "TGOV",
                totalSupply: 1_000_000e6,
                pool: cfg
            })
        );

        uint256 bought = IERC20(token).balanceOf(creator);
        assertGt(bought, 0, "Atomic dev buy must deliver tokens in launch tx");

        TimberlineGovernanceToken(token).delegate(creator);
        assertEq(TimberlineGovernanceToken(token).getVotes(creator), bought);
        vm.stopPrank();
    }

    function testFork_CleanByotTokenLaunchAndTierTwoSeal() public {
        vm.startPrank(creator);
        CleanExternalToken cleanToken = new CleanExternalToken(1_000_000e18, creator);
        cleanToken.approve(address(launchpad), type(uint256).max);
        (uint256 byotId,,) = launchpad.launchExistingToken{value: 0.5057 ether}(
            TimberlineLaunchpad.ExistingTokenLaunchParams({
                token: address(cleanToken),
                totalSupply: 1_000_000e18,
                vestedTokenAmount: 0,
                pool: _defaultEthPoolConfig()
            })
        );
        vm.stopPrank();

        TimberlineLaunchpad.ProvenanceCertificate memory cert = launchpad.getLaunchCertificate(byotId);
        assertFalse(cert.isNativeBlueprint, "BYOT must display Tier II external ERC-20 status");
        assertEq(cert.launchToken, address(cleanToken));
    }

    function testFork_FourWayFeeSplitRoundingAndRevertingRecipientIsolation() public {
        RevertingReceiver brokenWallet = new RevertingReceiver();

        address[] memory recipients = new address[](4);
        recipients[0] = creator;
        recipients[1] = coFounder;
        recipients[2] = treasuryWallet;
        recipients[3] = address(brokenWallet);

        uint16[] memory shares = new uint16[](4);
        shares[0] = 3_333;
        shares[1] = 3_333;
        shares[2] = 3_333;
        shares[3] = 1; // Sum = 10,000 bps; recipient #4 reverts on ETH receive

        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.feeRecipients = recipients;
        cfg.feeSharesBps = shares;
        cfg.proLvrEnabled = false;

        vm.prank(creator);
        (uint256 launchId, address token,,) = launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "FourSplit",
                symbol: "FSPL",
                totalSupply: 1_000_000e18,
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

        vm.prank(trader);
        swapRouter.swap{value: 0.01 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        // Harvesting succeeds even though recipient #4 is a reverting contract
        (uint256 earned0,) = launchpad.harvestLpFees(launchId);
        assertGt(earned0, 0);

        // Healthy recipients #1, #2, #3 claim cleanly without interference
        vm.prank(creator);
        uint256 c1 = launchpad.claimFees(launchId, CurrencyLibrary.ADDRESS_ZERO);
        vm.prank(coFounder);
        uint256 c2 = launchpad.claimFees(launchId, CurrencyLibrary.ADDRESS_ZERO);
        vm.prank(treasuryWallet);
        uint256 c3 = launchpad.claimFees(launchId, CurrencyLibrary.ADDRESS_ZERO);

        assertGt(c1, 0);
        assertEq(c1, c2);
        assertEq(c2, c3);
    }

    function testFork_ExtendLpLockAndPermanentLock() public {
        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.proLvrEnabled = false;

        vm.prank(creator);
        (uint256 launchId,,,) = launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "LockExtend",
                symbol: "LEXT",
                totalSupply: 1_000_000e18,
                pool: cfg
            })
        );

        uint64 initialUnlock = launchpad.getLaunchCertificate(launchId).lpUnlockTime;

        // Shortening lock must revert
        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.LockMustIncrease.selector);
        launchpad.extendLpLock(launchId, initialUnlock - 1);

        // Extending to permanent lock succeeds and blocks unlock even 100 years later
        vm.prank(creator);
        launchpad.extendLpLock(launchId, type(uint64).max);
        assertEq(launchpad.getLaunchCertificate(launchId).lpUnlockTime, type(uint64).max);

        vm.warp(block.timestamp + 36500 days);
        vm.prank(creator);
        vm.expectRevert();
        launchpad.unlockLp(launchId, creator);
    }

    // =========================================================================
    // 2. DEDICATED ADVERSARIAL & GUARDRAIL REVERT TESTS
    // =========================================================================

    function testFork_RevertWhen_SeedBelowMinimum() public {
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
                pool: lowEth
            })
        );

        TimberlineLaunchpad.PoolLaunchConfig memory lowUsdc = _defaultEthPoolConfig();
        lowUsdc.quoteToken = USDC_ADDR;
        lowUsdc.poolTokenAmount = 1_000_000e6;
        lowUsdc.quoteTokenAmount = 999e6;
        lowUsdc.proLvrEnabled = false;

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InsufficientSeedLiquidity.selector);
        launchpad.launchNewToken(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "LowUsdc",
                symbol: "LUSD",
                totalSupply: 1_000_000e6,
                pool: lowUsdc
            })
        );
    }

    function testFork_RevertWhen_LpLockBelow30Days() public {
        TimberlineLaunchpad.PoolLaunchConfig memory shortLock = _defaultEthPoolConfig();
        shortLock.lpLockDuration = 30 days - 1;

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InvalidLpLockDuration.selector);
        launchpad.launchNewToken{value: 0.51 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "ShortLock",
                symbol: "SLCK",
                totalSupply: 1_000_000e18,
                pool: shortLock
            })
        );
    }

    function testFork_RevertWhen_PoolAllocationBelow50Percent() public {
        TimberlineLaunchpad.PoolLaunchConfig memory lowPool = _defaultEthPoolConfig();
        lowPool.poolTokenAmount = 499_999e18;
        lowPool.vestingBeneficiary = coFounder;
        lowPool.cliffDuration = 14 days;
        lowPool.vestingDuration = 30 days;

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InsufficientPoolAllocation.selector);
        launchpad.launchNewToken{value: 0.51 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "LowPool",
                symbol: "LPOL",
                totalSupply: 1_000_000e18,
                pool: lowPool
            })
        );
    }

    function testFork_RevertWhen_VestingCliffBelow14DaysOrZeroBeneficiary() public {
        TimberlineLaunchpad.PoolLaunchConfig memory badCliff = _defaultEthPoolConfig();
        badCliff.poolTokenAmount = 700_000e18;
        badCliff.vestingBeneficiary = coFounder;
        badCliff.cliffDuration = 13 days;
        badCliff.vestingDuration = 30 days;

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InvalidVestingConfig.selector);
        launchpad.launchNewToken{value: 0.51 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "BadCliff",
                symbol: "BCLF",
                totalSupply: 1_000_000e18,
                pool: badCliff
            })
        );

        badCliff.cliffDuration = 14 days;
        badCliff.vestingBeneficiary = address(0);

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InvalidVestingConfig.selector);
        launchpad.launchNewToken{value: 0.51 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "NoBeneficiary",
                symbol: "NBEN",
                totalSupply: 1_000_000e18,
                pool: badCliff
            })
        );
    }

    function testFork_RevertWhen_PriceRangeMismatch() public {
        TimberlineLaunchpad.PoolLaunchConfig memory skewedPrice = _defaultEthPoolConfig();
        skewedPrice.sqrtPriceX96 = SQRT_PRICE_1_1; // 1:1 price only absorbs 0.5 tokens of 1,000,000

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.PriceRangeMismatch.selector);
        launchpad.launchNewToken{value: 0.51 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "Skewed",
                symbol: "SKWD",
                totalSupply: 1_000_000e18,
                pool: skewedPrice
            })
        );
    }

    function testFork_RevertWhen_FeeOnTransferByot() public {
        vm.startPrank(creator);
        FeeOnTransferMock skimToken = new FeeOnTransferMock(1_000_000e18, creator);
        skimToken.approve(address(launchpad), type(uint256).max);

        vm.expectRevert(TimberlineLaunchpad.FeeOnTransferUnsupported.selector);
        launchpad.launchExistingToken{value: 0.51 ether}(
            TimberlineLaunchpad.ExistingTokenLaunchParams({
                token: address(skimToken),
                totalSupply: 1_000_000e18,
                vestedTokenAmount: 0,
                pool: _defaultEthPoolConfig()
            })
        );
        vm.stopPrank();
    }

    function testFork_RevertWhen_DuplicateByotLaunch() public {
        vm.startPrank(creator);
        CleanExternalToken cleanToken = new CleanExternalToken(2_000_000e18, creator);
        cleanToken.approve(address(launchpad), type(uint256).max);

        launchpad.launchExistingToken{value: 0.51 ether}(
            TimberlineLaunchpad.ExistingTokenLaunchParams({
                token: address(cleanToken),
                totalSupply: 2_000_000e18,
                vestedTokenAmount: 0,
                pool: _defaultEthPoolConfig()
            })
        );

        vm.expectRevert(TimberlineLaunchpad.TokenAlreadyLaunched.selector);
        launchpad.launchExistingToken{value: 0.51 ether}(
            TimberlineLaunchpad.ExistingTokenLaunchParams({
                token: address(cleanToken),
                totalSupply: 2_000_000e18,
                vestedTokenAmount: 0,
                pool: _defaultEthPoolConfig()
            })
        );
        vm.stopPrank();
    }

    function testFork_RevertWhen_InvalidFeeSplit() public {
        TimberlineLaunchpad.PoolLaunchConfig memory badSplit = _defaultEthPoolConfig();
        badSplit.feeSharesBps[1] = 2_999; // Sum = 9,999 != 10,000

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.InvalidFeeSplit.selector);
        launchpad.launchNewToken{value: 0.51 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "BadSplit",
                symbol: "BSPL",
                totalSupply: 1_000_000e18,
                pool: badSplit
            })
        );
    }

    function testFork_RevertWhen_DevBuySlippageExceededOrBlockCapBreached() public {
        // 1. Unrealistic minDevBuyTokensOut triggers SlippageExceeded
        TimberlineLaunchpad.PoolLaunchConfig memory highSlip = _defaultEthPoolConfig();
        highSlip.proLvrEnabled = false;
        highSlip.devBuyQuoteAmount = 0.005 ether;
        highSlip.minDevBuyTokensOut = 500_000e18; // Impossible at 0.5 ETH : 1M pool depth

        vm.prank(creator);
        vm.expectRevert(TimberlineLaunchpad.SlippageExceeded.selector);
        launchpad.launchNewToken{value: 0.505 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "HighSlip",
                symbol: "HSLP",
                totalSupply: 1_000_000e18,
                pool: highSlip
            })
        );

        // 2. Dev buy exceeding 2.5% Block-1 cap (0.0125 ETH on 0.5 ETH seed) reverts inside hook
        TimberlineLaunchpad.PoolLaunchConfig memory overCap = _defaultEthPoolConfig();
        overCap.proLvrEnabled = false;
        overCap.devBuyQuoteAmount = 0.02 ether;
        overCap.minDevBuyTokensOut = 1;

        vm.prank(creator);
        vm.expectRevert();
        launchpad.launchNewToken{value: 0.52 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "OverCap",
                symbol: "OCAP",
                totalSupply: 1_000_000e18,
                pool: overCap
            })
        );
    }

    function testFork_RevertWhen_UnauthorizedLpUnlockOrEarlyUnlock() public {
        TimberlineLaunchpad.PoolLaunchConfig memory cfg = _defaultEthPoolConfig();
        cfg.proLvrEnabled = false;

        vm.prank(creator);
        (uint256 launchId,,,) = launchpad.launchNewToken{value: 0.5 ether}(
            TimberlineLaunchpad.NewTokenLaunchParams({
                blueprint: TimberlineTokenDeployer.Blueprint.STANDARD,
                name: "GuardUnlock",
                symbol: "GULK",
                totalSupply: 1_000_000e18,
                pool: cfg
            })
        );

        uint64 unlockTime = launchpad.getLaunchCertificate(launchId).lpUnlockTime;

        // Early unlock by creator reverts with LpStillLocked
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(TimberlineLaunchpad.LpStillLocked.selector, unlockTime, uint64(block.timestamp))
        );
        launchpad.unlockLp(launchId, creator);

        // Unlock by non-creator after timer expires reverts with OnlyCreator
        vm.warp(unlockTime + 1);
        vm.prank(attacker);
        vm.expectRevert(TimberlineLaunchpad.OnlyCreator.selector);
        launchpad.unlockLp(launchId, attacker);
    }

    function testFork_RevertWhen_DirectCallerBypassesLaunchpad() public {
        vm.prank(attacker);
        vm.expectRevert(TimberlineTokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deployToken(
            TimberlineTokenDeployer.Blueprint.STANDARD,
            "Rogue",
            "RGUE",
            1_000_000e18,
            attacker
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
        hook.registerPoolConfig(dummyKey, attacker, true, TimberlineHook.SnipePreset.STANDARD, false, 1 ether);
    }
}
