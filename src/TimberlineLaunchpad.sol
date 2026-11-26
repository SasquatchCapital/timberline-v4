// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimberlineHook} from "./TimberlineHook.sol";
import {TimberlineTokenDeployer} from "./TimberlineTokens.sol";
import {TimberlineVault} from "./TimberlineVault.sol";

/// @title TimberlineLaunchpad v2
/// @notice Unified, non-custodial Exclusive Concierge Token Service (ECTS) factory for Uniswap v4
///         on Base. Atomically deploys deterministic CREATE2 zero-admin ERC-20 blueprints (or
///         validates external ERC-20s), initializes TimberlineHook-protected v4 pools above a
///         skin-in-the-game seed floor, locks LP NFTs and multi-tranche vesting supplies directly
///         into TimberlineVault, executes optional disclosed atomic dev buys, and issues
///         delta-tracked excess refunds.
contract TimberlineLaunchpad is ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant MIN_ETH_SEED = 0.5 ether;
    uint256 public constant MIN_USDC_SEED = 1_000e6;
    uint64 public constant MIN_LP_LOCK_DURATION = 30 days;
    uint64 public constant MIN_CLIFF_DURATION = 14 days;
    uint64 public constant MIN_VESTING_DURATION = 1 days;
    uint256 public constant MIN_POOL_ALLOCATION_BPS = 5_000; // >= 50.00% paired in locked pool
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_RECIPIENTS = 4;
    uint256 public constant MAX_VESTING_TRANCHES = 4;
    int24 public constant DEFAULT_TICK_SPACING = 60;
    uint256 public constant DEFAULT_BLOCK_CAP_BPS = 500; // 5.00% of initial quote per block during launch window

    IPoolManager public immutable POOL_MANAGER;
    IPositionManager public immutable POSITION_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;
    TimberlineHook public immutable HOOK;
    TimberlineTokenDeployer public immutable TOKEN_DEPLOYER;
    TimberlineVault public immutable VAULT;
    address public immutable TREASURY;
    address public immutable USDC;

    struct PoolLaunchConfig {
        address creator;                // Explicit creator / Safe multisig (address(0) = msg.sender)
        address quoteToken;             // address(0) for Native ETH, or USDC
        uint256 poolTokenAmount;        // Tokens paired in Uniswap v4 pool
        uint256 quoteTokenAmount;       // ETH or USDC paired in Uniswap v4 pool
        uint160 sqrtPriceX96;           // Initial pool sqrtPriceX96
        int24 tickLower;                // Position lower tick
        int24 tickUpper;                // Position upper tick
        uint24 baseLpFeePips;           // Creator base LP fee tier: 3_000, 5_000, or 10_000
        TimberlineHook.SnipePreset snipePreset;
        uint128 maxBlockQuoteVolume;    // Launch-window block cap (0 = default 5.00% of quoteTokenAmount)
        uint64 lpLockDuration;          // Must be >= 30 days (use type(uint64).max for permanent)
        uint64 lpVestingDuration;       // 0 = full NFT release at lpUnlockTime; > 0 = linear principal unlock
        TimberlineVault.VestingTrancheInput[] vestingTranches; // Up to 4 cap-table vesting schedules
        uint256 devBuyQuoteAmount;      // Optional atomic initial buy in quote asset
        uint256 minDevBuyTokensOut;     // Slippage floor for atomic initial buy
        address devBuyRecipient;        // Recipient of atomic initial buy (defaults to creator)
        address[] feeRecipients;        // Optional split recipients (1..4); empty = 100% creator
        uint16[] feeSharesBps;          // Must sum to 10,000 bps if feeRecipients non-empty
    }

    struct NewTokenLaunchParams {
        TimberlineTokenDeployer.Blueprint blueprint;
        string name;
        string symbol;
        uint256 totalSupply;
        bytes32 salt;                   // User salt for deterministic CREATE2 token address
        PoolLaunchConfig pool;
    }

    struct ExistingTokenLaunchParams {
        address token;
        uint256 totalSupply;
        PoolLaunchConfig pool;
    }

    struct LaunchRecord {
        uint256 launchId;
        address launchToken;
        address quoteToken;
        PoolId poolId;
        uint256 lpTokenId;
        TimberlineTokenDeployer.Blueprint blueprint;
        bool isNativeBlueprint;
        uint24 baseLpFeePips;
        TimberlineHook.SnipePreset snipePreset;
        uint256 totalSupply;
        uint256 poolTokenAmount;
        uint256 initialQuoteAmount;
        uint256 devBuyQuoteAmount;
        uint256 devBuyTokensBought;
    }

    struct PendingDevBuy {
        bool active;
        PoolKey key;
        bool quoteIsCurrency0;
        uint256 quoteAmountIn;
        uint256 minTokensOut;
        address recipient;
        uint256 tokensBought;
    }

    uint256 public launchCount;
    mapping(uint256 => LaunchRecord) private _launches;
    mapping(address => uint256) public launchIdByToken;
    mapping(PoolId => uint256) public launchIdByPool;

    PendingDevBuy private _pendingDevBuy;

    event TimberlineLaunched(
        uint256 indexed launchId,
        PoolId indexed poolId,
        address indexed launchToken,
        address creator,
        address quoteToken,
        uint256 lpTokenId,
        bool isNativeBlueprint,
        uint64 lpUnlockTime
    );
    event DevBuyExecuted(PoolId indexed poolId, address indexed recipient, uint256 quoteAmountIn, uint256 tokensBought);

    error UnsupportedQuoteAsset();
    error InvalidTokenParams();
    error TokenAlreadyLaunched();
    error InsufficientSeedLiquidity();
    error InsufficientEthSent();
    error InvalidTickRange();
    error InvalidBaseLpFee();
    error InsufficientPoolAllocation();
    error InvalidVestingConfig();
    error InvalidLpLockDuration();
    error InvalidFeeSplit();
    error FeeOnTransferUnsupported();
    error ZeroLiquidityCalculated();
    error PriceRangeMismatch();
    error SlippageExceeded();
    error EthTransferFailed();
    error UnauthorizedCallback();

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2,
        TimberlineHook _hook,
        TimberlineTokenDeployer _tokenDeployer,
        TimberlineVault _vault,
        address _treasury,
        address _usdc
    ) {
        require(_treasury != address(0) && _usdc != address(0), "ZERO_ADDR");
        POOL_MANAGER = _poolManager;
        POSITION_MANAGER = _positionManager;
        PERMIT2 = _permit2;
        HOOK = _hook;
        TOKEN_DEPLOYER = _tokenDeployer;
        VAULT = _vault;
        TREASURY = _treasury;
        USDC = _usdc;
    }

    receive() external payable {}

    function launchNewToken(NewTokenLaunchParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 launchId, address launchToken, PoolId poolId, uint256 lpTokenId)
    {
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0 || params.totalSupply == 0) {
            revert InvalidTokenParams();
        }
        if (params.pool.poolTokenAmount > params.totalSupply) revert InvalidTokenParams();

        uint256 requiredVested = params.totalSupply - params.pool.poolTokenAmount;
        uint256 sumTranches = _validateLaunchConfig(params.totalSupply, params.pool);
        if (sumTranches != requiredVested) revert InvalidVestingConfig();

        address creatorAddr = params.pool.creator == address(0) ? msg.sender : params.pool.creator;

        launchToken = TOKEN_DEPLOYER.deployToken(
            params.blueprint,
            params.name,
            params.symbol,
            params.totalSupply,
            address(this),
            creatorAddr,
            params.salt
        );

        (launchId, poolId, lpTokenId) = _executeLaunch(
            launchToken,
            params.totalSupply,
            sumTranches,
            params.blueprint,
            true,
            creatorAddr,
            params.pool
        );
    }

    function launchExistingToken(ExistingTokenLaunchParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 launchId, PoolId poolId, uint256 lpTokenId)
    {
        if (params.token == address(0) || params.token == params.pool.quoteToken || params.totalSupply == 0) {
            revert InvalidTokenParams();
        }
        if (launchIdByToken[params.token] != 0) revert TokenAlreadyLaunched();
        if (IERC20(params.token).totalSupply() != params.totalSupply) revert InvalidTokenParams();

        uint256 sumTranches = _validateLaunchConfig(params.totalSupply, params.pool);
        if (params.pool.poolTokenAmount + sumTranches > params.totalSupply) revert InvalidVestingConfig();

        address creatorAddr = params.pool.creator == address(0) ? msg.sender : params.pool.creator;

        uint256 totalRequired = params.pool.poolTokenAmount + sumTranches;
        uint256 balBefore = IERC20(params.token).balanceOf(address(this));
        IERC20(params.token).safeTransferFrom(msg.sender, address(this), totalRequired);
        uint256 balAfter = IERC20(params.token).balanceOf(address(this));
        if (balAfter - balBefore != totalRequired) revert FeeOnTransferUnsupported();

        (launchId, poolId, lpTokenId) = _executeLaunch(
            params.token,
            params.totalSupply,
            sumTranches,
            TimberlineTokenDeployer.Blueprint.STANDARD,
            false,
            creatorAddr,
            params.pool
        );
    }

    function getLaunchRecord(uint256 launchId) external view returns (LaunchRecord memory) {
        return _launches[launchId];
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_pendingDevBuy.active) revert UnauthorizedCallback();

        PendingDevBuy memory buy = _pendingDevBuy;
        _pendingDevBuy.active = false;

        POOL_MANAGER.swap(
            buy.key,
            IPoolManager.SwapParams({
                zeroForOne: buy.quoteIsCurrency0,
                amountSpecified: -int256(buy.quoteAmountIn),
                sqrtPriceLimitX96: buy.quoteIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        int256 delta0 = POOL_MANAGER.currencyDelta(address(this), buy.key.currency0);
        int256 delta1 = POOL_MANAGER.currencyDelta(address(this), buy.key.currency1);

        uint256 tokensBought = 0;
        if (buy.quoteIsCurrency0) {
            if (delta0 < 0) _settleCurrency(buy.key.currency0, uint256(-delta0));
            if (delta1 > 0) {
                tokensBought = uint256(delta1);
                POOL_MANAGER.take(buy.key.currency1, buy.recipient, tokensBought);
            }
        } else {
            if (delta1 < 0) _settleCurrency(buy.key.currency1, uint256(-delta1));
            if (delta0 > 0) {
                tokensBought = uint256(delta0);
                POOL_MANAGER.take(buy.key.currency0, buy.recipient, tokensBought);
            }
        }

        if (tokensBought < buy.minTokensOut) revert SlippageExceeded();
        _pendingDevBuy.tokensBought = tokensBought;
        emit DevBuyExecuted(buy.key.toId(), buy.recipient, buy.quoteAmountIn, tokensBought);
        return bytes("");
    }

    function _validateLaunchConfig(uint256 totalSupply, PoolLaunchConfig calldata cfg)
        internal
        view
        returns (uint256 totalVested)
    {
        if (cfg.poolTokenAmount == 0) revert InsufficientPoolAllocation();
        if (cfg.poolTokenAmount * BPS_DENOMINATOR < totalSupply * MIN_POOL_ALLOCATION_BPS) {
            revert InsufficientPoolAllocation();
        }
        if (cfg.tickLower >= cfg.tickUpper) revert InvalidTickRange();
        if (cfg.lpLockDuration < MIN_LP_LOCK_DURATION) revert InvalidLpLockDuration();
        if (cfg.lpLockDuration == type(uint64).max && cfg.lpVestingDuration != 0) {
            revert InvalidLpLockDuration();
        }
        if (
            cfg.baseLpFeePips != HOOK.LP_FEE_30_BPS() &&
            cfg.baseLpFeePips != HOOK.LP_FEE_50_BPS() &&
            cfg.baseLpFeePips != HOOK.LP_FEE_100_BPS()
        ) {
            revert InvalidBaseLpFee();
        }

        bool isNativeEth = (cfg.quoteToken == address(0));
        if (!isNativeEth && cfg.quoteToken != USDC) revert UnsupportedQuoteAsset();

        uint256 minSeed = isNativeEth ? MIN_ETH_SEED : MIN_USDC_SEED;
        if (cfg.quoteTokenAmount < minSeed) revert InsufficientSeedLiquidity();

        if (isNativeEth && msg.value < cfg.quoteTokenAmount + cfg.devBuyQuoteAmount) {
            revert InsufficientEthSent();
        }

        uint256 trancheCount = cfg.vestingTranches.length;
        if (trancheCount > MAX_VESTING_TRANCHES) revert InvalidVestingConfig();
        bool invalidTranche = false;
        for (uint256 i = 0; i < trancheCount; ++i) {
            TimberlineVault.VestingTrancheInput calldata t = cfg.vestingTranches[i];
            if (
                t.beneficiary == address(0) ||
                t.amount == 0 ||
                t.cliffDuration < MIN_CLIFF_DURATION ||
                t.vestingDuration < MIN_VESTING_DURATION
            ) {
                invalidTranche = true;
            }
            totalVested += t.amount;
        }
        if (invalidTranche) revert InvalidVestingConfig();

        uint256 recipientCount = cfg.feeRecipients.length;
        if (recipientCount > MAX_FEE_RECIPIENTS || recipientCount != cfg.feeSharesBps.length) {
            revert InvalidFeeSplit();
        }
        if (recipientCount > 0) {
            uint256 totalBps = 0;
            bool invalidSplit = false;
            for (uint256 i = 0; i < recipientCount; ++i) {
                if (cfg.feeRecipients[i] == address(0) || cfg.feeSharesBps[i] == 0) {
                    invalidSplit = true;
                }
                totalBps += cfg.feeSharesBps[i];
            }
            if (invalidSplit || totalBps != BPS_DENOMINATOR) revert InvalidFeeSplit();
        }
    }

    function _executeLaunch(
        address launchToken,
        uint256 totalSupply,
        uint256 totalVested,
        TimberlineTokenDeployer.Blueprint blueprint,
        bool isNativeBlueprint,
        address creatorAddr,
        PoolLaunchConfig calldata cfg
    ) internal returns (uint256 launchId, PoolId poolId, uint256 lpTokenId) {
        bool isNativeEth = (cfg.quoteToken == address(0));
        bool quoteIsCurrency0 = uint160(cfg.quoteToken) < uint160(launchToken);

        uint256 ethBalStart = address(this).balance - msg.value;
        uint256 usdcBalStart = isNativeEth ? 0 : IERC20(USDC).balanceOf(address(this));

        (Currency currency0, Currency currency1, uint256 amount0Max, uint256 amount1Max) = quoteIsCurrency0
            ? (Currency.wrap(cfg.quoteToken), Currency.wrap(launchToken), cfg.quoteTokenAmount, cfg.poolTokenAmount)
            : (Currency.wrap(launchToken), Currency.wrap(cfg.quoteToken), cfg.poolTokenAmount, cfg.quoteTokenAmount);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(HOOK))
        });
        poolId = poolKey.toId();
        lpTokenId = POSITION_MANAGER.nextTokenId();

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            cfg.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(cfg.tickLower),
            TickMath.getSqrtPriceAtTick(cfg.tickUpper),
            amount0Max,
            amount1Max
        );
        if (liquidity == 0) revert ZeroLiquidityCalculated();

        launchId = ++launchCount;
        uint64 nowTs = uint64(block.timestamp);
        uint64 lpUnlockTime = cfg.lpLockDuration == type(uint64).max
            ? type(uint64).max
            : nowTs + cfg.lpLockDuration;
        uint64 lpVestingEnd = (lpUnlockTime != type(uint64).max && cfg.lpVestingDuration > 0)
            ? lpUnlockTime + cfg.lpVestingDuration
            : 0;

        _launches[launchId] = LaunchRecord({
            launchId: launchId,
            launchToken: launchToken,
            quoteToken: cfg.quoteToken,
            poolId: poolId,
            lpTokenId: lpTokenId,
            blueprint: blueprint,
            isNativeBlueprint: isNativeBlueprint,
            baseLpFeePips: cfg.baseLpFeePips,
            snipePreset: cfg.snipePreset,
            totalSupply: totalSupply,
            poolTokenAmount: cfg.poolTokenAmount,
            initialQuoteAmount: cfg.quoteTokenAmount,
            devBuyQuoteAmount: cfg.devBuyQuoteAmount,
            devBuyTokensBought: 0
        });

        launchIdByToken[launchToken] = launchId;
        launchIdByPool[poolId] = launchId;

        VAULT.registerLaunch(
            TimberlineVault.VaultInitParams({
                launchId: launchId,
                launchToken: launchToken,
                poolId: poolId,
                poolKey: poolKey,
                lpTokenId: lpTokenId,
                creator: creatorAddr,
                tickLower: cfg.tickLower,
                tickUpper: cfg.tickUpper,
                initialLiquidity: liquidity,
                lpUnlockTime: lpUnlockTime,
                lpVestingEnd: lpVestingEnd,
                vestedTotal: totalVested,
                vestingTranches: cfg.vestingTranches,
                feeRecipients: cfg.feeRecipients,
                feeSharesBps: cfg.feeSharesBps
            })
        );

        if (totalVested > 0) {
            IERC20(launchToken).safeTransfer(address(VAULT), totalVested);
        }

        if (!isNativeEth) {
            uint256 totalUsdcIn = cfg.quoteTokenAmount + cfg.devBuyQuoteAmount;
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), totalUsdcIn);
            if (IERC20(USDC).balanceOf(address(this)) - usdcBalStart != totalUsdcIn) {
                revert FeeOnTransferUnsupported();
            }
        }

        uint128 blockCap = cfg.maxBlockQuoteVolume > 0
            ? cfg.maxBlockQuoteVolume
            : uint128((cfg.quoteTokenAmount * DEFAULT_BLOCK_CAP_BPS) / BPS_DENOMINATOR);

        HOOK.registerPoolConfig(
            poolKey,
            creatorAddr,
            quoteIsCurrency0,
            cfg.baseLpFeePips,
            cfg.snipePreset,
            blockCap
        );
        POOL_MANAGER.initialize(poolKey, cfg.sqrtPriceX96);

        _approvePermit2(launchToken, cfg.poolTokenAmount);
        if (!isNativeEth) {
            _approvePermit2(USDC, cfg.quoteTokenAmount);
        }

        bytes memory actions = isNativeEth
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory unlockParams = new bytes[](isNativeEth ? 3 : 2);
        unlockParams[0] = abi.encode(
            poolKey,
            cfg.tickLower,
            cfg.tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            address(VAULT),
            bytes("")
        );
        unlockParams[1] = abi.encode(currency0, currency1);
        if (isNativeEth) {
            unlockParams[2] = abi.encode(currency0, address(this));
        }

        POSITION_MANAGER.modifyLiquidities{value: isNativeEth ? cfg.quoteTokenAmount : 0}(
            abi.encode(actions, unlockParams),
            block.timestamp
        );

        uint256 unusedPoolTokens = IERC20(launchToken).balanceOf(address(this));
        uint256 actualPooledTokens = cfg.poolTokenAmount - unusedPoolTokens;
        if (actualPooledTokens * BPS_DENOMINATOR < cfg.poolTokenAmount * 9_900) {
            revert PriceRangeMismatch();
        }

        uint256 quoteSpentOnLp = isNativeEth
            ? (ethBalStart + msg.value) - address(this).balance
            : (usdcBalStart + cfg.quoteTokenAmount + cfg.devBuyQuoteAmount) - IERC20(USDC).balanceOf(address(this));
        if (quoteSpentOnLp * BPS_DENOMINATOR < cfg.quoteTokenAmount * 9_900) {
            revert PriceRangeMismatch();
        }

        if (cfg.devBuyQuoteAmount > 0) {
            address buyRecipient = cfg.devBuyRecipient == address(0) ? creatorAddr : cfg.devBuyRecipient;
            _pendingDevBuy = PendingDevBuy({
                active: true,
                key: poolKey,
                quoteIsCurrency0: quoteIsCurrency0,
                quoteAmountIn: cfg.devBuyQuoteAmount,
                minTokensOut: cfg.minDevBuyTokensOut,
                recipient: buyRecipient,
                tokensBought: 0
            });
            POOL_MANAGER.unlock(bytes(""));
            _launches[launchId].devBuyTokensBought = _pendingDevBuy.tokensBought;
            _pendingDevBuy.tokensBought = 0;
        }

        if (unusedPoolTokens > 0) {
            if (isNativeBlueprint && cfg.vestingTranches.length > 0) {
                IERC20(launchToken).safeTransfer(address(VAULT), unusedPoolTokens);
                VAULT.addVestingDust(launchId, unusedPoolTokens);
            } else {
                IERC20(launchToken).safeTransfer(msg.sender, unusedPoolTokens);
            }
        }
        if (!isNativeEth) {
            uint256 usdcNow = IERC20(USDC).balanceOf(address(this));
            if (usdcNow > usdcBalStart) {
                IERC20(USDC).safeTransfer(msg.sender, usdcNow - usdcBalStart);
            }
        }
        uint256 ethNow = address(this).balance;
        if (ethNow > ethBalStart) {
            (bool refundOk,) = msg.sender.call{value: ethNow - ethBalStart}("");
            if (!refundOk) revert EthTransferFailed();
        }

        emit TimberlineLaunched(
            launchId,
            poolId,
            launchToken,
            creatorAddr,
            cfg.quoteToken,
            lpTokenId,
            isNativeBlueprint,
            lpUnlockTime
        );
    }

    function _settleCurrency(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            POOL_MANAGER.sync(currency);
            POOL_MANAGER.settle{value: amount}();
        } else {
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    function _approvePermit2(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(token, address(POSITION_MANAGER), uint160(amount), uint48(block.timestamp + 300));
    }
}
