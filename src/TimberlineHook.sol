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
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title TimberlineHook
/// @notice Immutable Uniswap v4 hook providing Block-1 anti-snipe fee decay,
///         permanent single-block volume caps, and an optional EMA LVR shield.
contract TimberlineHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint24 public constant BASE_LP_FEE_PIPS = 3_000;            // 30 bps (0.30%)
    uint24 public constant BASE_HOOK_FEE_PIPS = 1_500;          // 15 bps (0.15%)
    uint24 public constant MAX_LVR_LP_FEE_PIPS = 25_000;        // 250 bps (2.50%)
    uint256 public constant FEE_DENOMINATOR = 1_000_000;        // 100% in pips
    uint256 public constant SNIPER_HOOK_SHARE_BPS = 1_500;      // 15.00% of Sniper Guard fee to Treasury
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint24 public constant STANDARD_START_FEE_PIPS = 50_000;    // 500 bps (5.00%)
    uint40 public constant STANDARD_DECAY_BLOCKS = 500;         // ~100s at 200ms Base Denim blocks
    uint24 public constant HIGH_GUARD_START_FEE_PIPS = 100_000; // 1,000 bps (10.00%)
    uint40 public constant HIGH_GUARD_DECAY_BLOCKS = 1_000;     // ~200s at 200ms Base Denim blocks

    uint256 public constant EMA_ALPHA_BPS = 100;                // 1% weight per 200ms active block (~20s time constant)
    uint256 public constant LVR_DEADBAND_BPS = 50;              // 0.50% spot price drift deadband
    uint256 public constant LVR_SLOPE_MULTIPLIER = 40;          // Scales drift bps into pips

    address public immutable TREASURY;
    address public immutable FACTORY;

    enum SnipePreset {
        STANDARD,
        HIGH_GUARD
    }

    struct PoolConfig {
        bool initialized;
        bool quoteIsCurrency0;
        bool proLvrEnabled;
        uint24 startSniperFeePips;
        uint40 launchBlock;
        uint40 decayBlocks;
        uint128 maxBlockQuoteVolume;
    }

    struct PoolRuntime {
        uint40 activeBlock;
        uint128 blockQuoteVolume;
        uint160 emaSqrtPriceX96;
        uint40 lastEmaBlock;
    }

    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => PoolRuntime) public poolRuntimes;
    mapping(PoolId => uint24) private _pendingUnspecifiedHookFeePips;

    event PoolProtected(
        PoolId indexed poolId,
        address indexed creator,
        SnipePreset preset,
        bool proLvrEnabled,
        uint128 maxBlockQuoteVolume
    );
    event HookFeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeesSwept(Currency indexed currency, address indexed treasury, uint256 amount);

    error OnlyFactory();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error InvalidDynamicFeeFlag();
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
            beforeAddLiquidity: false,
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
        SnipePreset preset,
        bool proLvrEnabled,
        uint128 maxBlockQuoteVolume
    ) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert InvalidDynamicFeeFlag();

        PoolId id = key.toId();
        if (poolConfigs[id].initialized) revert PoolAlreadyRegistered();

        uint24 startFee = preset == SnipePreset.HIGH_GUARD
            ? HIGH_GUARD_START_FEE_PIPS
            : STANDARD_START_FEE_PIPS;
        uint40 decay = preset == SnipePreset.HIGH_GUARD
            ? HIGH_GUARD_DECAY_BLOCKS
            : STANDARD_DECAY_BLOCKS;

        poolConfigs[id] = PoolConfig({
            initialized: true,
            quoteIsCurrency0: quoteIsCurrency0,
            proLvrEnabled: proLvrEnabled,
            startSniperFeePips: startFee,
            launchBlock: uint40(block.number),
            decayBlocks: decay,
            maxBlockQuoteVolume: maxBlockQuoteVolume
        });

        emit PoolProtected(id, creator, preset, proLvrEnabled, maxBlockQuoteVolume);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != FACTORY) revert OnlyFactory();
        PoolId id = key.toId();
        if (!poolConfigs[id].initialized) revert PoolNotRegistered();

        poolRuntimes[id] = PoolRuntime({
            activeBlock: uint40(block.number),
            blockQuoteVolume: 0,
            emaSqrtPriceX96: sqrtPriceX96,
            lastEmaBlock: uint40(block.number)
        });

        return BaseHook.beforeInitialize.selector;
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

        (uint160 spotSqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (cfg.proLvrEnabled && uint40(block.number) > rt.lastEmaBlock && rt.emaSqrtPriceX96 > 0) {
            uint256 weightedNew = uint256(spotSqrtPriceX96) * EMA_ALPHA_BPS;
            uint256 weightedOld = uint256(rt.emaSqrtPriceX96) * (BPS_DENOMINATOR - EMA_ALPHA_BPS);
            rt.emaSqrtPriceX96 = uint160((weightedNew + weightedOld) / BPS_DENOMINATOR);
            rt.lastEmaBlock = uint40(block.number);
        }

        (uint24 lpFeePips, uint24 hookFeePips) = _computeActiveFees(cfg, rt, spotSqrtPriceX96, params.zeroForOne);

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) ? params.zeroForOne : !params.zeroForOne;
        bool quoteIsSpecified = (specifiedIsCurrency0 == cfg.quoteIsCurrency0);

        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        if (quoteIsSpecified) {
            uint256 absSpecified = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);

            _recordAndEnforceBlockCap(rt, cfg.maxBlockQuoteVolume, absSpecified);

            uint256 hookFeeAmount = (absSpecified * hookFeePips) / FEE_DENOMINATOR;
            if (hookFeeAmount > 0) {
                Currency quoteCurrency = cfg.quoteIsCurrency0 ? key.currency0 : key.currency1;
                poolManager.take(quoteCurrency, address(this), hookFeeAmount);
                delta = toBeforeSwapDelta(hookFeeAmount.toInt128(), 0);
                emit HookFeeCollected(id, quoteCurrency, hookFeeAmount);
            }
            _pendingUnspecifiedHookFeePips[id] = 0;
        } else {
            _pendingUnspecifiedHookFeePips[id] = hookFeePips;
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
        uint256 absQuoteVolume = rawQuoteDelta < 0
            ? uint256(uint128(-rawQuoteDelta))
            : uint256(uint128(rawQuoteDelta));

        _recordAndEnforceBlockCap(poolRuntimes[id], cfg.maxBlockQuoteVolume, absQuoteVolume);

        uint24 hookFeePips = _pendingUnspecifiedHookFeePips[id];
        _pendingUnspecifiedHookFeePips[id] = 0;

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
        bool zeroForOne
    ) internal view returns (uint24 lpFeePips, uint24 hookFeePips) {
        uint40 currentBlock = uint40(block.number);
        uint40 endSnipeBlock = cfg.launchBlock + cfg.decayBlocks;

        if (currentBlock < endSnipeBlock) {
            uint256 remainingBlocks = endSnipeBlock - currentBlock;
            uint256 floorTotalPips = uint256(BASE_LP_FEE_PIPS) + uint256(BASE_HOOK_FEE_PIPS);
            uint256 startTotalPips = cfg.startSniperFeePips;

            uint256 decayedTotalPips = floorTotalPips
                + ((startTotalPips - floorTotalPips) * remainingBlocks) / cfg.decayBlocks;

            uint256 hookCut = (decayedTotalPips * SNIPER_HOOK_SHARE_BPS) / BPS_DENOMINATOR;
            if (hookCut < BASE_HOOK_FEE_PIPS) {
                hookCut = BASE_HOOK_FEE_PIPS;
            }
            hookFeePips = uint24(hookCut);
            lpFeePips = uint24(decayedTotalPips - hookCut);
            return (lpFeePips, hookFeePips);
        }

        hookFeePips = BASE_HOOK_FEE_PIPS;
        lpFeePips = BASE_LP_FEE_PIPS;

        if (cfg.proLvrEnabled && rt.emaSqrtPriceX96 > 0 && spotSqrtPriceX96 != rt.emaSqrtPriceX96) {
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
                    uint256 dynamicLp = uint256(BASE_LP_FEE_PIPS) + surcharge;
                    lpFeePips = dynamicLp > MAX_LVR_LP_FEE_PIPS
                        ? MAX_LVR_LP_FEE_PIPS
                        : uint24(dynamicLp);
                }
            }
        }
    }

    function _recordAndEnforceBlockCap(PoolRuntime storage rt, uint128 cap, uint256 quoteVolume) internal {
        uint40 currentBlock = uint40(block.number);
        if (rt.activeBlock != currentBlock) {
            rt.activeBlock = currentBlock;
            rt.blockQuoteVolume = 0;
        }
        uint256 newVolume = uint256(rt.blockQuoteVolume) + quoteVolume;
        if (newVolume > cap) {
            revert SingleBlockVolumeCapExceeded(newVolume, cap);
        }
        rt.blockQuoteVolume = uint128(newVolume);
    }

    function withdrawFees(Currency currency) external {
        if (currency.isAddressZero()) {
            uint256 bal = address(this).balance;
            if (bal == 0) revert ZeroAmountToSweep();
            (bool ok,) = TREASURY.call{value: bal}("");
            if (!ok) revert EthTransferFailed();
            emit FeesSwept(currency, TREASURY, bal);
        } else {
            address token = Currency.unwrap(currency);
            uint256 bal = IERC20Minimal(token).balanceOf(address(this));
            if (bal == 0) revert ZeroAmountToSweep();
            require(IERC20Minimal(token).transfer(TREASURY, bal), "ERC20_TRANSFER_FAILED");
            emit FeesSwept(currency, TREASURY, bal);
        }
    }
}
