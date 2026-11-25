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

interface IERC721Transfer {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title TimberlineLaunchpad
/// @notice Unified, non-custodial Exclusive Concierge Token Service (ECTS) for Uniswap v4 on Base.
///         Atomically deploys audited zero-admin ERC-20 blueprints (or validates external ERC-20s),
///         initializes TimberlineHook-protected v4 pools above a skin-in-the-game seed floor,
///         time-locks LP principal with pull-based multi-recipient fee harvesting, enforces zero
///         free-float time-linear vesting on unpooled tokens, and exposes single-call Provenance Seals.
contract TimberlineLaunchpad is ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant MIN_ETH_SEED = 0.5 ether;
    uint256 public constant MIN_USDC_SEED = 1_000e6;
    uint256 public constant PRO_LVR_FEE = 0.0057 ether;
    uint64 public constant MIN_LP_LOCK_DURATION = 30 days;
    uint64 public constant MIN_CLIFF_DURATION = 14 days;
    uint256 public constant MIN_POOL_ALLOCATION_BPS = 5_000; // >= 50.00% paired in locked pool
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_RECIPIENTS = 4;
    int24 public constant DEFAULT_TICK_SPACING = 60;
    uint256 public constant DEFAULT_BLOCK_CAP_BPS = 250; // 2.50% of initial quote per block

    IPoolManager public immutable POOL_MANAGER;
    IPositionManager public immutable POSITION_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;
    TimberlineHook public immutable HOOK;
    TimberlineTokenDeployer public immutable TOKEN_DEPLOYER;
    address public immutable TREASURY;
    address public immutable USDC;

    struct PoolLaunchConfig {
        address quoteToken;             // address(0) for Native ETH, or USDC
        uint256 poolTokenAmount;        // Tokens paired in Uniswap v4 pool
        uint256 quoteTokenAmount;       // ETH or USDC paired in Uniswap v4 pool
        uint160 sqrtPriceX96;           // Initial pool sqrtPriceX96
        int24 tickLower;                // Position lower tick
        int24 tickUpper;                // Position upper tick
        TimberlineHook.SnipePreset snipePreset;
        bool proLvrEnabled;
        uint128 maxBlockQuoteVolume;    // 0 = default 2.50% of quoteTokenAmount per block
        uint64 lpLockDuration;          // Must be >= 30 days (use type(uint64).max for permanent)
        address vestingBeneficiary;     // Required if unpooled tokens > 0
        uint64 cliffDuration;           // Must be >= 14 days if unpooled tokens > 0
        uint64 vestingDuration;         // Linear release duration after cliff
        uint256 devBuyQuoteAmount;      // Optional atomic initial buy in quote asset
        uint256 minDevBuyTokensOut;     // Slippage floor for atomic initial buy
        address devBuyRecipient;        // Recipient of atomic initial buy (defaults to msg.sender)
        address[] feeRecipients;        // Optional split recipients (1..4); empty = 100% creator
        uint16[] feeSharesBps;          // Must sum to 10,000 bps if feeRecipients non-empty
    }

    struct NewTokenLaunchParams {
        TimberlineTokenDeployer.Blueprint blueprint;
        string name;
        string symbol;
        uint256 totalSupply;
        PoolLaunchConfig pool;
    }

    struct ExistingTokenLaunchParams {
        address token;
        uint256 totalSupply;
        uint256 vestedTokenAmount;
        PoolLaunchConfig pool;
    }

    struct LaunchRecord {
        uint256 launchId;
        address launchToken;
        address quoteToken;
        PoolId poolId;
        uint256 lpTokenId;
        address creator;
        TimberlineTokenDeployer.Blueprint blueprint;
        bool isNativeBlueprint;
        bool lpUnlocked;
        bool proLvrEnabled;
        TimberlineHook.SnipePreset snipePreset;
        uint256 totalSupply;
        uint256 poolTokenAmount;
        uint256 initialQuoteAmount;
        uint64 lpUnlockTime;
        address vestingBeneficiary;
        uint256 vestedTotal;
        uint256 vestedClaimed;
        uint64 cliffEnd;
        uint64 vestingEnd;
    }

    struct ProvenanceCertificate {
        uint256 launchId;
        address launchToken;
        address quoteToken;
        PoolId poolId;
        uint256 lpTokenId;
        address creator;
        TimberlineTokenDeployer.Blueprint blueprint;
        bool isNativeBlueprint;
        bool lpUnlocked;
        bool proLvrEnabled;
        TimberlineHook.SnipePreset snipePreset;
        uint256 totalSupply;
        uint256 poolTokenAmount;
        uint256 initialQuoteAmount;
        uint256 pairedSupplyBps;
        uint64 lpUnlockTime;
        address vestingBeneficiary;
        uint256 vestedTotal;
        uint256 vestedClaimed;
        uint64 cliffEnd;
        uint64 vestingEnd;
        address hookAddress;
        address treasuryAddress;
        address[] feeRecipients;
        uint16[] feeSharesBps;
    }

    struct PendingDevBuy {
        bool active;
        PoolKey key;
        bool quoteIsCurrency0;
        uint256 quoteAmountIn;
        uint256 minTokensOut;
        address recipient;
    }

    uint256 public launchCount;
    mapping(uint256 => LaunchRecord) private _launches;
    mapping(uint256 => PoolKey) private _poolKeys;
    mapping(uint256 => address[]) private _feeRecipients;
    mapping(uint256 => uint16[]) private _feeSharesBps;
    mapping(uint256 => mapping(address => mapping(Currency => uint256))) public claimableFees;
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
    event LpFeesHarvested(uint256 indexed launchId, uint256 amount0, uint256 amount1);
    event LpFeesClaimed(uint256 indexed launchId, address indexed recipient, Currency indexed currency, uint256 amount);
    event LpLockExtended(uint256 indexed launchId, uint64 newUnlockTime);
    event LpUnlocked(uint256 indexed launchId, address indexed recipient, uint256 lpTokenId);
    event VestedTokensClaimed(uint256 indexed launchId, address indexed beneficiary, uint256 amount);

    error UnsupportedQuoteAsset();
    error InvalidTokenParams();
    error TokenAlreadyLaunched();
    error InsufficientSeedLiquidity();
    error InsufficientEthSent();
    error InvalidTickRange();
    error InsufficientPoolAllocation();
    error InvalidVestingConfig();
    error InvalidLpLockDuration();
    error InvalidFeeSplit();
    error FeeOnTransferUnsupported();
    error ZeroLiquidityCalculated();
    error PriceRangeMismatch();
    error SlippageExceeded();
    error OnlyCreator();
    error LpStillLocked(uint64 unlockTime, uint64 currentTime);
    error LpAlreadyUnlocked();
    error LockMustIncrease();
    error NothingToClaim();
    error EthTransferFailed();
    error UnauthorizedCallback();

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2,
        TimberlineHook _hook,
        TimberlineTokenDeployer _tokenDeployer,
        address _treasury,
        address _usdc
    ) {
        require(_treasury != address(0) && _usdc != address(0), "ZERO_ADDR");
        POOL_MANAGER = _poolManager;
        POSITION_MANAGER = _positionManager;
        PERMIT2 = _permit2;
        HOOK = _hook;
        TOKEN_DEPLOYER = _tokenDeployer;
        TREASURY = _treasury;
        USDC = _usdc;
    }

    receive() external payable {}

    /// @notice Atomically deploys a curated zero-admin OZ v5 ERC-20 blueprint, seeds & locks a
    ///         TimberlineHook-protected v4 pool, and locks any unpooled supply into linear vesting.
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

        uint256 vestedAmount = params.totalSupply - params.pool.poolTokenAmount;
        _validateLaunchConfig(params.totalSupply, params.pool.poolTokenAmount, vestedAmount, params.pool);

        launchToken = TOKEN_DEPLOYER.deployToken(
            params.blueprint,
            params.name,
            params.symbol,
            params.totalSupply,
            address(this)
        );

        (launchId, poolId, lpTokenId) = _executeLaunch(
            launchToken,
            params.totalSupply,
            vestedAmount,
            params.blueprint,
            true,
            params.pool
        );
    }

    /// @notice Launches a pre-existing audited ERC-20 under Timberline's exact same seed floor,
    ///         zero free-float vesting rule, 30-day minimum LP lock, and TimberlineHook protection.
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

        _validateLaunchConfig(params.totalSupply, params.pool.poolTokenAmount, params.vestedTokenAmount, params.pool);

        uint256 totalRequired = params.pool.poolTokenAmount + params.vestedTokenAmount;
        uint256 balBefore = IERC20(params.token).balanceOf(address(this));
        IERC20(params.token).safeTransferFrom(msg.sender, address(this), totalRequired);
        uint256 balAfter = IERC20(params.token).balanceOf(address(this));
        if (balAfter - balBefore != totalRequired) revert FeeOnTransferUnsupported();

        (launchId, poolId, lpTokenId) = _executeLaunch(
            params.token,
            params.totalSupply,
            params.vestedTokenAmount,
            TimberlineTokenDeployer.Blueprint.STANDARD,
            false,
            params.pool
        );
    }

    /// @notice Collects accrued Uniswap v4 LP swap fees without unlocking principal liquidity and
    ///         credits each configured recipient's pull-based fee balance.
    function harvestLpFees(uint256 launchId) external nonReentrant returns (uint256 earned0, uint256 earned1) {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();

        PoolKey memory key = _poolKeys[launchId];
        uint256 bal0Before = _currencyBalance(key.currency0);
        uint256 bal1Before = _currencyBalance(key.currency1);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory unlockParams = new bytes[](2);
        unlockParams[0] = abi.encode(rec.lpTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        unlockParams[1] = abi.encode(key.currency0, key.currency1, address(this));

        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, unlockParams), block.timestamp);

        earned0 = _currencyBalance(key.currency0) - bal0Before;
        earned1 = _currencyBalance(key.currency1) - bal1Before;

        if (earned0 > 0) _creditCurrency(launchId, key.currency0, earned0);
        if (earned1 > 0) _creditCurrency(launchId, key.currency1, earned1);

        emit LpFeesHarvested(launchId, earned0, earned1);
    }

    /// @notice Pull-based withdrawal of harvested LP fees for `msg.sender`.
    function claimFees(uint256 launchId, Currency currency) external nonReentrant returns (uint256 amount) {
        amount = claimableFees[launchId][msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        claimableFees[launchId][msg.sender][currency] = 0;
        _sendCurrency(currency, msg.sender, amount);

        emit LpFeesClaimed(launchId, msg.sender, currency, amount);
    }

    /// @notice Allows the creator to extend the LP lock duration (or permanently lock via uint64.max).
    function extendLpLock(uint256 launchId, uint64 newUnlockTime) external {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();
        if (newUnlockTime <= rec.lpUnlockTime) revert LockMustIncrease();

        rec.lpUnlockTime = newUnlockTime;
        emit LpLockExtended(launchId, newUnlockTime);
    }

    /// @notice Releases the Uniswap v4 LP NFT to `recipient` once the mandatory lock timer expires.
    function unlockLp(uint256 launchId, address recipient) external nonReentrant {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();
        if (block.timestamp < rec.lpUnlockTime) {
            revert LpStillLocked(rec.lpUnlockTime, uint64(block.timestamp));
        }

        rec.lpUnlocked = true;
        address to = recipient == address(0) ? rec.creator : recipient;
        IERC721Transfer(address(POSITION_MANAGER)).transferFrom(address(this), to, rec.lpTokenId);

        emit LpUnlocked(launchId, to, rec.lpTokenId);
    }

    /// @notice Claims unlocked tokens from the timestamp-linear team/treasury vesting schedule.
    function claimVestedTokens(uint256 launchId) external nonReentrant returns (uint256 claimable) {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();

        claimable = getClaimableVested(launchId);
        if (claimable == 0) revert NothingToClaim();

        rec.vestedClaimed += claimable;
        IERC20(rec.launchToken).safeTransfer(rec.vestingBeneficiary, claimable);

        emit VestedTokensClaimed(launchId, rec.vestingBeneficiary, claimable);
    }

    /// @notice Returns currently claimable vested tokens for a launch.
    function getClaimableVested(uint256 launchId) public view returns (uint256) {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.vestedTotal == 0 || block.timestamp < rec.cliffEnd) return 0;

        uint256 unlocked = 0;
        if (block.timestamp >= rec.vestingEnd) {
            unlocked = rec.vestedTotal;
        } else {
            uint256 elapsed = block.timestamp - rec.cliffEnd;
            uint256 duration = rec.vestingEnd - rec.cliffEnd;
            unlocked = (rec.vestedTotal * elapsed) / duration;
        }
        return unlocked - rec.vestedClaimed;
    }

    /// @notice Single-call on-chain Timberline Provenance Seal returning full launch verification data.
    function getLaunchCertificate(uint256 launchId) public view returns (ProvenanceCertificate memory cert) {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();

        uint256 pairedBps = (rec.poolTokenAmount * BPS_DENOMINATOR) / rec.totalSupply;
        cert = ProvenanceCertificate({
            launchId: rec.launchId,
            launchToken: rec.launchToken,
            quoteToken: rec.quoteToken,
            poolId: rec.poolId,
            lpTokenId: rec.lpTokenId,
            creator: rec.creator,
            blueprint: rec.blueprint,
            isNativeBlueprint: rec.isNativeBlueprint,
            lpUnlocked: rec.lpUnlocked,
            proLvrEnabled: rec.proLvrEnabled,
            snipePreset: rec.snipePreset,
            totalSupply: rec.totalSupply,
            poolTokenAmount: rec.poolTokenAmount,
            initialQuoteAmount: rec.initialQuoteAmount,
            pairedSupplyBps: pairedBps,
            lpUnlockTime: rec.lpUnlockTime,
            vestingBeneficiary: rec.vestingBeneficiary,
            vestedTotal: rec.vestedTotal,
            vestedClaimed: rec.vestedClaimed,
            cliffEnd: rec.cliffEnd,
            vestingEnd: rec.vestingEnd,
            hookAddress: address(HOOK),
            treasuryAddress: TREASURY,
            feeRecipients: _feeRecipients[launchId],
            feeSharesBps: _feeSharesBps[launchId]
        });
    }

    /// @notice Convenience lookup returning the Provenance Seal directly by token address.
    function getLaunchCertificateByToken(address token) external view returns (ProvenanceCertificate memory) {
        uint256 id = launchIdByToken[token];
        if (id == 0) revert InvalidTokenParams();
        return getLaunchCertificate(id);
    }

    /// @notice PoolManager unlock callback used strictly for the atomic initial dev buy.
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
        emit DevBuyExecuted(buy.key.toId(), buy.recipient, buy.quoteAmountIn, tokensBought);
        return bytes("");
    }

    function _validateLaunchConfig(
        uint256 totalSupply,
        uint256 poolTokenAmount,
        uint256 vestedAmount,
        PoolLaunchConfig calldata cfg
    ) internal view {
        if (poolTokenAmount == 0) revert InsufficientPoolAllocation();
        if (poolTokenAmount * BPS_DENOMINATOR < totalSupply * MIN_POOL_ALLOCATION_BPS) {
            revert InsufficientPoolAllocation();
        }
        if (cfg.tickLower >= cfg.tickUpper) revert InvalidTickRange();
        if (cfg.lpLockDuration < MIN_LP_LOCK_DURATION) revert InvalidLpLockDuration();

        bool isNativeEth = (cfg.quoteToken == address(0));
        if (!isNativeEth && cfg.quoteToken != USDC) revert UnsupportedQuoteAsset();

        uint256 minSeed = isNativeEth ? MIN_ETH_SEED : MIN_USDC_SEED;
        if (cfg.quoteTokenAmount < minSeed) revert InsufficientSeedLiquidity();

        uint256 requiredProFee = cfg.proLvrEnabled ? PRO_LVR_FEE : 0;
        if (isNativeEth) {
            if (msg.value < cfg.quoteTokenAmount + cfg.devBuyQuoteAmount + requiredProFee) {
                revert InsufficientEthSent();
            }
        } else {
            if (msg.value < requiredProFee) revert InsufficientEthSent();
        }

        if (vestedAmount > 0) {
            if (cfg.vestingBeneficiary == address(0)) revert InvalidVestingConfig();
            if (cfg.cliffDuration < MIN_CLIFF_DURATION || cfg.vestingDuration == 0) {
                revert InvalidVestingConfig();
            }
        }

        uint256 recipientCount = cfg.feeRecipients.length;
        if (recipientCount > MAX_FEE_RECIPIENTS || recipientCount != cfg.feeSharesBps.length) {
            revert InvalidFeeSplit();
        }
        if (recipientCount > 0) {
            uint256 totalBps = 0;
            for (uint256 i = 0; i < recipientCount; ++i) {
                if (cfg.feeRecipients[i] == address(0) || cfg.feeSharesBps[i] == 0) {
                    revert InvalidFeeSplit();
                }
                totalBps += cfg.feeSharesBps[i];
            }
            if (totalBps != BPS_DENOMINATOR) revert InvalidFeeSplit();
        }
    }

    function _executeLaunch(
        address launchToken,
        uint256 totalSupply,
        uint256 vestedAmount,
        TimberlineTokenDeployer.Blueprint blueprint,
        bool isNativeBlueprint,
        PoolLaunchConfig calldata cfg
    ) internal returns (uint256 launchId, PoolId poolId, uint256 lpTokenId) {
        bool isNativeEth = (cfg.quoteToken == address(0));
        bool quoteIsCurrency0 = uint160(cfg.quoteToken) < uint160(launchToken);

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

        // Effects: finalize all state records before any external contract call
        launchId = ++launchCount;
        uint64 lpUnlockTime = cfg.lpLockDuration == type(uint64).max
            ? type(uint64).max
            : uint64(block.timestamp) + cfg.lpLockDuration;
        uint64 cliffEnd = vestedAmount > 0 ? uint64(block.timestamp) + cfg.cliffDuration : 0;
        uint64 vestingEnd = vestedAmount > 0 ? cliffEnd + cfg.vestingDuration : 0;

        _launches[launchId] = LaunchRecord({
            launchId: launchId,
            launchToken: launchToken,
            quoteToken: cfg.quoteToken,
            poolId: poolId,
            lpTokenId: lpTokenId,
            creator: msg.sender,
            blueprint: blueprint,
            isNativeBlueprint: isNativeBlueprint,
            lpUnlocked: false,
            proLvrEnabled: cfg.proLvrEnabled,
            snipePreset: cfg.snipePreset,
            totalSupply: totalSupply,
            poolTokenAmount: cfg.poolTokenAmount,
            initialQuoteAmount: cfg.quoteTokenAmount,
            lpUnlockTime: lpUnlockTime,
            vestingBeneficiary: vestedAmount > 0 ? cfg.vestingBeneficiary : address(0),
            vestedTotal: vestedAmount,
            vestedClaimed: 0,
            cliffEnd: cliffEnd,
            vestingEnd: vestingEnd
        });

        _poolKeys[launchId] = poolKey;
        launchIdByToken[launchToken] = launchId;
        launchIdByPool[poolId] = launchId;

        if (cfg.feeRecipients.length == 0) {
            _feeRecipients[launchId].push(msg.sender);
            _feeSharesBps[launchId].push(uint16(BPS_DENOMINATOR));
        } else {
            for (uint256 i = 0; i < cfg.feeRecipients.length; ++i) {
                _feeRecipients[launchId].push(cfg.feeRecipients[i]);
                _feeSharesBps[launchId].push(cfg.feeSharesBps[i]);
            }
        }

        // Interactions
        if (cfg.proLvrEnabled) {
            (bool feeOk,) = TREASURY.call{value: PRO_LVR_FEE}("");
            if (!feeOk) revert EthTransferFailed();
        }

        if (!isNativeEth) {
            uint256 totalUsdcIn = cfg.quoteTokenAmount + cfg.devBuyQuoteAmount;
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), totalUsdcIn);
            if (IERC20(USDC).balanceOf(address(this)) - usdcBefore != totalUsdcIn) {
                revert FeeOnTransferUnsupported();
            }
        }

        uint128 blockCap = cfg.maxBlockQuoteVolume > 0
            ? cfg.maxBlockQuoteVolume
            : uint128((cfg.quoteTokenAmount * DEFAULT_BLOCK_CAP_BPS) / BPS_DENOMINATOR);

        HOOK.registerPoolConfig(poolKey, msg.sender, quoteIsCurrency0, cfg.snipePreset, cfg.proLvrEnabled, blockCap);
        POOL_MANAGER.initialize(poolKey, cfg.sqrtPriceX96);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            cfg.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(cfg.tickLower),
            TickMath.getSqrtPriceAtTick(cfg.tickUpper),
            amount0Max,
            amount1Max
        );
        if (liquidity == 0) revert ZeroLiquidityCalculated();

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
            address(this),
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

        if (cfg.devBuyQuoteAmount > 0) {
            address buyRecipient = cfg.devBuyRecipient == address(0) ? msg.sender : cfg.devBuyRecipient;
            _pendingDevBuy = PendingDevBuy({
                active: true,
                key: poolKey,
                quoteIsCurrency0: quoteIsCurrency0,
                quoteAmountIn: cfg.devBuyQuoteAmount,
                minTokensOut: cfg.minDevBuyTokensOut,
                recipient: buyRecipient
            });
            POOL_MANAGER.unlock(bytes(""));
        }

        uint256 remLaunchToken = IERC20(launchToken).balanceOf(address(this));
        uint256 unusedPoolTokens = remLaunchToken - vestedAmount;
        uint256 actualPooledTokens = cfg.poolTokenAmount - unusedPoolTokens;
        if (actualPooledTokens * BPS_DENOMINATOR < cfg.poolTokenAmount * 9_900) {
            revert PriceRangeMismatch();
        }
        if (unusedPoolTokens > 0) {
            if (isNativeBlueprint && vestedAmount > 0) {
                _launches[launchId].vestedTotal += unusedPoolTokens;
            } else {
                IERC20(launchToken).safeTransfer(msg.sender, unusedPoolTokens);
            }
        }
        if (!isNativeEth) {
            uint256 remUsdc = IERC20(USDC).balanceOf(address(this));
            if (remUsdc > 0) {
                IERC20(USDC).safeTransfer(msg.sender, remUsdc);
            }
        }
        uint256 excessEth = address(this).balance;
        if (excessEth > 0) {
            (bool refundOk,) = msg.sender.call{value: excessEth}("");
            if (!refundOk) revert EthTransferFailed();
        }

        emit TimberlineLaunched(
            launchId,
            poolId,
            launchToken,
            msg.sender,
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

    function _currencyBalance(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) return address(this).balance;
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function _creditCurrency(uint256 launchId, Currency currency, uint256 totalAmount) internal {
        address[] storage recipients = _feeRecipients[launchId];
        uint16[] storage shares = _feeSharesBps[launchId];
        uint256 count = recipients.length;
        uint256 distributed = 0;

        for (uint256 i = 0; i < count; ++i) {
            uint256 slice = (i == count - 1)
                ? (totalAmount - distributed)
                : (totalAmount * shares[i]) / BPS_DENOMINATOR;
            distributed += slice;
            if (slice > 0) {
                claimableFees[launchId][recipients[i]][currency] += slice;
            }
        }
    }

    function _sendCurrency(Currency currency, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }
}
