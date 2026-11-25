// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TimberlineHook v2
/// @notice Immutable, zero-admin Uniswap v4 hook providing timestamp-driven Block-1 anti-snipe
///         fee decay, Block-1 JIT liquidity blocking, expiring launch volume caps, selectable
///         creator LP fee tiers (30/50/100 bps), fixed 15 bps quote-only protocol fees, and
///         standard wall-clock exponential EMA Loss-Versus-Rebalancing (LVR) protection.
contract TimberlineHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    // Selectable creator base LP fee tiers (in pips, 1_000_000 = 100%)
    uint24 public constant LP_FEE_30_BPS = 3_000;               // 0.30%
    uint24 public constant LP_FEE_50_BPS = 5_000;               // 0.50%
    uint24 public constant LP_FEE_100_BPS = 10_000;             // 1.00%

    // Fixed protocol fee & LVR surcharge bounds
    uint24 public constant BASE_HOOK_FEE_PIPS = 1_500;          // 15 bps (0.15%) fixed
    uint24 public constant MAX_LVR_SURCHARGE_PIPS = 22_000;     // +220 bps (+2.20%) max above baseLpFeePips
    uint256 public constant FEE_DENOMINATOR = 1_000_000;        // 100% in pips
    uint256 public constant SNIPER_HOOK_SHARE_BPS = 1_500;      // 15.00% of Sniper Guard fee to Treasury
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // Anti-snipe presets (wall-clock seconds)
    uint24 public constant STANDARD_START_FEE_PIPS = 150_000;   // 1,500 bps (15.00%)
    uint40 public constant STANDARD_DECAY_SECONDS = 60;         // 60s linear decay
    uint24 public constant HIGH_GUARD_START_FEE_PIPS = 350_000; // 3,500 bps (35.00%)
    uint40 public constant HIGH_GUARD_DECAY_SECONDS = 180;      // 180s linear decay
    uint24 public constant FORTRESS_START_FEE_PIPS = 600_000;   // 6,000 bps (60.00%)
    uint40 public constant FORTRESS_DECAY_SECONDS = 300;        // 300s linear decay

    // Standard wall-clock LVR shield parameters
    uint256 public constant EMA_TAU_SECONDS = 60;               // 60s exponential EMA time constant
    uint256 public constant EMA_SNAP_SECONDS = 240;             // 4x tau: full convergence after 4m idle
    uint256 public constant LVR_DEADBAND_BPS = 50;              // 0.50% spot price drift deadband
    uint256 public constant LVR_SLOPE_MULTIPLIER = 40;          // Scales drift bps into pips

    // Cancun transient storage slot for unspecified-quote hook fee pips
    uint256 private constant _PENDING_HOOK_FEE_SLOT =
        uint256(keccak256("timberline.v2.pendingHookFeePips")) - 1;

    address public immutable TREASURY;
    address public immutable FACTORY;

    enum SnipePreset {
        STANDARD,
        HIGH_GUARD,
        FORTRESS
    }

    struct PoolConfig {
        bool initialized;
        bool genesisSeeded;
        bool quoteIsCurrency0;
        uint24 baseLpFeePips;
        uint24 startSniperFeePips;
        uint40 launchTime;
        uint40 decayDuration;
        uint128 maxBlockQuoteVolume;
    }

    struct PoolRuntime {
        uint40 activeBlock;
        uint128 blockQuoteVolume;
        uint160 emaSqrtPriceX96;
        uint40 lastEmaTime;
    }

    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => PoolRuntime) public poolRuntimes;

    event PoolProtected(
        PoolId indexed poolId,
        address indexed creator,
        uint24 baseLpFeePips,
        SnipePreset preset,
        uint128 maxBlockQuoteVolume
    );
    event HookFeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeesSwept(Currency indexed currency, address indexed treasury, uint256 amount);

    error OnlyFactory();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error InvalidDynamicFeeFlag();
    error InvalidBaseLpFee();
    error SniperWindowLiquidityLocked();
    error SingleBlockVolumeCapExceeded(uint256 attempted, uint256 cap);
    error ZeroAmountToSweep();
    error EthTransferFailed();

    constructor(IPoolManager _poolManager, address _factory, address _treasury) BaseHook(_poolManager) {
        require(_factory != address(0) && _treasury != address(0), "ZERO_ADDR");
        FACTORY = _factory;
        TREASURY = _treasury;
    }

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function registerPoolConfig(
        PoolKey calldata key,
        address creator,
        bool quoteIsCurrency0,
        uint24 baseLpFeePips,
        SnipePreset preset,
        uint128 maxBlockQuoteVolume
    ) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert InvalidDynamicFeeFlag();
        if (
            baseLpFeePips != LP_FEE_30_BPS &&
            baseLpFeePips != LP_FEE_50_BPS &&
            baseLpFeePips != LP_FEE_100_BPS
        ) {
            revert InvalidBaseLpFee();
        }

        PoolId id = key.toId();
        if (poolConfigs[id].initialized) revert PoolAlreadyRegistered();

        uint24 startFee;
        uint40 decay;
        if (preset == SnipePreset.FORTRESS) {
            startFee = FORTRESS_START_FEE_PIPS;
            decay = FORTRESS_DECAY_SECONDS;
        } else if (preset == SnipePreset.HIGH_GUARD) {
            startFee = HIGH_GUARD_START_FEE_PIPS;
            decay = HIGH_GUARD_DECAY_SECONDS;
        } else {
            startFee = STANDARD_START_FEE_PIPS;
            decay = STANDARD_DECAY_SECONDS;
        }

        poolConfigs[id] = PoolConfig({
            initialized: true,
            genesisSeeded: false,
            quoteIsCurrency0: quoteIsCurrency0,
            baseLpFeePips: baseLpFeePips,
            startSniperFeePips: startFee,
            launchTime: 0,
            decayDuration: decay,
            maxBlockQuoteVolume: maxBlockQuoteVolume
        });

        emit PoolProtected(id, creator, baseLpFeePips, preset, maxBlockQuoteVolume);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != FACTORY) revert OnlyFactory();
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfigs[id];
        if (!cfg.initialized) revert PoolNotRegistered();

        uint40 nowTs = uint40(block.timestamp);
        cfg.launchTime = nowTs;

        poolRuntimes[id] = PoolRuntime({
            activeBlock: uint40(block.number),
            blockQuoteVolume: 0,
            emaSqrtPriceX96: sqrtPriceX96,
            lastEmaTime: nowTs
        });

        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Allows the single genesis liquidity mint during launch, then blocks external JIT
    ///         liquidity additions until the Block-1 anti-snipe decay window completes.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfigs[id];
        if (!cfg.initialized) revert PoolNotRegistered();

        if (!cfg.genesisSeeded) {
            cfg.genesisSeeded = true;
            return BaseHook.beforeAddLiquidity.selector;
        }

        if (uint40(block.timestamp) < cfg.launchTime + cfg.decayDuration) {
            revert SniperWindowLiquidityLocked();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfigs[id];
        if (!cfg.initialized) revert PoolNotRegistered();

        PoolRuntime storage rt = poolRuntimes[id];
        uint40 nowTs = uint40(block.timestamp);

        (uint160 spotSqrtPriceX96,,,) = poolManager.getSlot0(id);

        // Update wall-clock exponential EMA once per distinct timestamp
        if (nowTs > rt.lastEmaTime && rt.emaSqrtPriceX96 > 0) {
            uint256 dt = uint256(nowTs - rt.lastEmaTime);
            if (dt >= EMA_SNAP_SECONDS) {
                rt.emaSqrtPriceX96 = spotSqrtPriceX96;
            } else {
                // Pade (1,1) approximation of (1 - e^(-dt/tau)) in bps
                uint256 alphaBps = (2 * dt * BPS_DENOMINATOR) / (2 * EMA_TAU_SECONDS + dt);
                if (alphaBps > BPS_DENOMINATOR) alphaBps = BPS_DENOMINATOR;
                uint256 weightedNew = uint256(spotSqrtPriceX96) * alphaBps;
                uint256 weightedOld = uint256(rt.emaSqrtPriceX96) * (BPS_DENOMINATOR - alphaBps);
                rt.emaSqrtPriceX96 = uint160((weightedNew + weightedOld) / BPS_DENOMINATOR);
            }
            rt.lastEmaTime = nowTs;
        }

        (uint24 lpFeePips, uint24 hookFeePips) = _computeActiveFees(cfg, rt, spotSqrtPriceX96, params.zeroForOne, nowTs);

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) ? params.zeroForOne : !params.zeroForOne;
        bool quoteIsSpecified = (specifiedIsCurrency0 == cfg.quoteIsCurrency0);

        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        if (quoteIsSpecified) {
            uint256 absSpecified = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);

            _enforceLaunchBlockCap(cfg, rt, absSpecified, nowTs);

            uint256 hookFeeAmount = (absSpecified * hookFeePips) / FEE_DENOMINATOR;
            if (hookFeeAmount > 0) {
                Currency quoteCurrency = cfg.quoteIsCurrency0 ? key.currency0 : key.currency1;
                poolManager.take(quoteCurrency, address(this), hookFeeAmount);
                delta = toBeforeSwapDelta(hookFeeAmount.toInt128(), 0);
                emit HookFeeCollected(id, quoteCurrency, hookFeeAmount);
            }
            _setTransientHookFeePips(0);
        } else {
            _setTransientHookFeePips(hookFeePips);
        }

        return (
            BaseHook.beforeSwap.selector,
            delta,
            lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfigs[id];

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) ? params.zeroForOne : !params.zeroForOne;
        bool quoteIsSpecified = (specifiedIsCurrency0 == cfg.quoteIsCurrency0);

        if (quoteIsSpecified) {
            return (BaseHook.afterSwap.selector, 0);
        }

        int128 rawQuoteDelta = cfg.quoteIsCurrency0 ? swapDelta.amount0() : swapDelta.amount1();
        require(rawQuoteDelta != type(int128).min, "DELTA_OVERFLOW");
        uint256 absQuoteVolume = rawQuoteDelta < 0
            ? uint256(uint128(-rawQuoteDelta))
            : uint256(uint128(rawQuoteDelta));

        _enforceLaunchBlockCap(cfg, poolRuntimes[id], absQuoteVolume, uint40(block.timestamp));

        uint24 hookFeePips = _getTransientHookFeePips();
        _setTransientHookFeePips(0);

        uint256 hookFeeAmount = (absQuoteVolume * hookFeePips) / FEE_DENOMINATOR;
        if (hookFeeAmount > 0) {
            Currency quoteCurrency = cfg.quoteIsCurrency0 ? key.currency0 : key.currency1;
            poolManager.take(quoteCurrency, address(this), hookFeeAmount);
            emit HookFeeCollected(id, quoteCurrency, hookFeeAmount);
            return (BaseHook.afterSwap.selector, hookFeeAmount.toInt128());
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _computeActiveFees(
        PoolConfig memory cfg,
        PoolRuntime storage rt,
        uint160 spotSqrtPriceX96,
        bool zeroForOne,
        uint40 nowTs
    ) internal view returns (uint24 lpFeePips, uint24 hookFeePips) {
        uint40 endSnipeTime = cfg.launchTime + cfg.decayDuration;

        // Phase 1: Timestamp-linear Block-1 Anti-Snipe Decay (85% locked LP / 15% Treasury)
        if (nowTs < endSnipeTime) {
            uint256 remainingTime = endSnipeTime - nowTs;
            uint256 floorTotalPips = uint256(cfg.baseLpFeePips) + uint256(BASE_HOOK_FEE_PIPS);
            uint256 startTotalPips = cfg.startSniperFeePips;

            uint256 decayedTotalPips = floorTotalPips
                + ((startTotalPips - floorTotalPips) * remainingTime) / cfg.decayDuration;

            uint256 hookCut = (decayedTotalPips * SNIPER_HOOK_SHARE_BPS) / BPS_DENOMINATOR;
            if (hookCut < BASE_HOOK_FEE_PIPS) {
                hookCut = BASE_HOOK_FEE_PIPS;
            }
            hookFeePips = uint24(hookCut);
            lpFeePips = uint24(decayedTotalPips - hookCut);
            return (lpFeePips, hookFeePips);
        }

        // Phase 2: Steady-State Base LP Tier + Standard Wall-Clock EMA LVR Shield
        hookFeePips = BASE_HOOK_FEE_PIPS;
        lpFeePips = cfg.baseLpFeePips;

        if (rt.emaSqrtPriceX96 > 0 && spotSqrtPriceX96 != rt.emaSqrtPriceX96) {
            bool isToxicDivergence = zeroForOne
                ? (spotSqrtPriceX96 < rt.emaSqrtPriceX96)
                : (spotSqrtPriceX96 > rt.emaSqrtPriceX96);

            if (isToxicDivergence) {
                uint256 diff = spotSqrtPriceX96 > rt.emaSqrtPriceX96
                    ? uint256(spotSqrtPriceX96 - rt.emaSqrtPriceX96)
                    : uint256(rt.emaSqrtPriceX96 - spotSqrtPriceX96);

                uint256 spotDriftBps = (diff * BPS_DENOMINATOR * 2) / uint256(rt.emaSqrtPriceX96);

                if (spotDriftBps > LVR_DEADBAND_BPS) {
                    uint256 surcharge = (spotDriftBps - LVR_DEADBAND_BPS) * LVR_SLOPE_MULTIPLIER;
                    uint256 dynamicLp = uint256(cfg.baseLpFeePips) + surcharge;
                    uint256 maxLvrLp = uint256(cfg.baseLpFeePips) + uint256(MAX_LVR_SURCHARGE_PIPS);
                    lpFeePips = dynamicLp > maxLvrLp ? uint24(maxLvrLp) : uint24(dynamicLp);
                }
            }
        }
    }

    /// @notice Enforces per-block quote volume cap strictly during the anti-snipe decay window.
    function _enforceLaunchBlockCap(
        PoolConfig memory cfg,
        PoolRuntime storage rt,
        uint256 quoteVolume,
        uint40 nowTs
    ) internal {
        if (cfg.maxBlockQuoteVolume == 0 || nowTs >= cfg.launchTime + cfg.decayDuration) {
            return;
        }

        uint40 currentBlock = uint40(block.number);
        if (rt.activeBlock != currentBlock) {
            rt.activeBlock = currentBlock;
            rt.blockQuoteVolume = 0;
        }
        uint256 newVolume = uint256(rt.blockQuoteVolume) + quoteVolume;
        if (newVolume > cfg.maxBlockQuoteVolume) {
            revert SingleBlockVolumeCapExceeded(newVolume, cfg.maxBlockQuoteVolume);
        }
        rt.blockQuoteVolume = uint128(newVolume);
    }

    function _setTransientHookFeePips(uint24 feePips) private {
        uint256 slot = _PENDING_HOOK_FEE_SLOT;
        assembly {
            tstore(slot, feePips)
        }
    }

    function _getTransientHookFeePips() private view returns (uint24 feePips) {
        uint256 slot = _PENDING_HOOK_FEE_SLOT;
        assembly {
            feePips := tload(slot)
        }
    }

    /// @notice Permissionless sweep of accumulated quote-currency protocol fees strictly to TREASURY.
    function withdrawFees(Currency currency) external {
        if (currency.isAddressZero()) {
            uint256 bal = address(this).balance;
            if (bal == 0) revert ZeroAmountToSweep();
            (bool ok,) = TREASURY.call{value: bal}("");
            if (!ok) revert EthTransferFailed();
            emit FeesSwept(currency, TREASURY, bal);
        } else {
            address token = Currency.unwrap(currency);
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) revert ZeroAmountToSweep();
            IERC20(token).safeTransfer(TREASURY, bal);
            emit FeesSwept(currency, TREASURY, bal);
        }
    }
}
