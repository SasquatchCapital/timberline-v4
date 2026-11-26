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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
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

/// @title TimberlineLaunchpad v2
/// @notice Unified, non-custodial Exclusive Concierge Token Service (ECTS) for Uniswap v4 on Base.
///         Deploys deterministic CREATE2 zero-admin ERC-20 blueprints (or validates external ERC-20s),
///         initializes TimberlineHook-protected v4 pools above a skin-in-the-game seed floor,
///         time-locks LP principal (cliff, linear unlock, or permanent) with auto-compounding and
///         multi-recipient fee splits, enforces multi-tranche cap-table vesting, supports Safe
///         multisig creators with two-step handoffs, and compiles single-call Provenance Seals.
contract TimberlineLaunchpad is ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

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
    address public immutable TREASURY;
    address public immutable USDC;

    struct VestingTrancheInput {
        address beneficiary;
        uint256 amount;
        uint64 cliffDuration;
        uint64 vestingDuration;
    }

    struct VestingTranche {
        address beneficiary;
        uint256 totalAmount;
        uint256 claimedAmount;
        uint64 cliffEnd;
        uint64 vestingEnd;
    }

    struct DisclosureRecord {
        bytes32 docHash;
        string label;
        uint64 timestamp;
    }

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
        VestingTrancheInput[] vestingTranches; // Up to 4 cap-table vesting schedules
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
        address creator;
        TimberlineTokenDeployer.Blueprint blueprint;
        bool isNativeBlueprint;
        bool lpUnlocked;
        uint24 baseLpFeePips;
        int24 tickLower;
        int24 tickUpper;
        TimberlineHook.SnipePreset snipePreset;
        uint256 totalSupply;
        uint256 poolTokenAmount;
        uint256 initialQuoteAmount;
        uint128 initialLiquidity;
        uint128 liquidityWithdrawn;
        uint64 lpUnlockTime;
        uint64 lpVestingEnd;
        uint256 vestedTotal;
        uint256 devBuyQuoteAmount;
        uint256 devBuyTokensBought;
    }

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
        address treasuryAddress;
        address[] feeRecipients;
        uint16[] feeSharesBps;
        VestingTranche[] vestingTranches;
        DisclosureRecord[] disclosures;
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
    mapping(uint256 => PoolKey) private _poolKeys;
    mapping(uint256 => address[]) private _feeRecipients;
    mapping(uint256 => uint16[]) private _feeSharesBps;
    mapping(uint256 => VestingTranche[]) private _vestingTranches;
    mapping(uint256 => DisclosureRecord[]) private _disclosures;
    mapping(uint256 => address) public pendingCreator;
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
    event LpFeesCompounded(uint256 indexed launchId, uint128 addedLiquidity, uint256 amount0Used, uint256 amount1Used);
    event LpFeesClaimed(uint256 indexed launchId, address indexed recipient, Currency indexed currency, uint256 amount);
    event LpLockExtended(uint256 indexed launchId, uint64 newUnlockTime);
    event LinearLpWithdrawn(uint256 indexed launchId, address indexed recipient, uint128 liquidityRemoved);
    event LpUnlocked(uint256 indexed launchId, address indexed recipient, uint256 lpTokenId);
    event VestedTokensClaimed(uint256 indexed launchId, uint256 indexed trancheIndex, address indexed beneficiary, uint256 amount);
    event CreatorProposed(uint256 indexed launchId, address indexed currentCreator, address indexed proposedCreator);
    event CreatorAccepted(uint256 indexed launchId, address indexed previousCreator, address indexed newCreator);
    event DisclosureAnchored(uint256 indexed launchId, bytes32 indexed docHash, string label);

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
    error OnlyCreator();
    error OnlyPendingCreator();
    error InvalidCreatorAddress();
    error LpStillLocked(uint64 unlockTime, uint64 currentTime);
    error LpAlreadyUnlocked();
    error LinearLpNotConfigured();
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

    /// @notice Atomically deploys a deterministic CREATE2 zero-admin ERC-20 blueprint, seeds & locks
    ///         a TimberlineHook-protected v4 pool, and locks all unpooled supply into vesting tranches.
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
        uint256 sumTranches = _validateLaunchConfig(params.totalSupply, params.pool.poolTokenAmount, params.pool);
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

    /// @notice Launches a pre-existing audited ERC-20 under Timberline's exact same seed floor,
    ///         multi-tranche vesting rules, minimum 30-day LP lock, and TimberlineHook protection.
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

        uint256 sumTranches = _validateLaunchConfig(params.totalSupply, params.pool.poolTokenAmount, params.pool);
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

    /// @notice Collects accrued Uniswap v4 LP swap fees without unlocking principal liquidity and
    ///         credits each configured recipient's pull-based fee balance.
    function harvestLpFees(uint256 launchId) external nonReentrant returns (uint256 earned0, uint256 earned1) {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();
        return _harvestLpFees(launchId);
    }

    /// @notice Permissionlessly harvests accrued LP swap fees and compounds them directly back into
    ///         the locked Position NFT via INCREASE_LIQUIDITY (Protocol-Owned Liquidity mode).
    function compoundLpFees(uint256 launchId)
        external
        nonReentrant
        returns (uint128 addedLiquidity, uint256 amount0Used, uint256 amount1Used)
    {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();

        PoolKey memory key = _poolKeys[launchId];
        uint256 bal0Before = _currencyBalance(key.currency0);
        uint256 bal1Before = _currencyBalance(key.currency1);

        // Step 1: Collect accrued fees from PositionManager to this contract
        bytes memory collectActions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory collectParams = new bytes[](2);
        collectParams[0] = abi.encode(rec.lpTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        collectParams[1] = abi.encode(key.currency0, key.currency1, address(this));
        POSITION_MANAGER.modifyLiquidities(abi.encode(collectActions, collectParams), block.timestamp);

        uint256 earned0 = _currencyBalance(key.currency0) - bal0Before;
        uint256 earned1 = _currencyBalance(key.currency1) - bal1Before;
        if (earned0 == 0 && earned1 == 0) revert NothingToClaim();

        // Step 2: Compute exact liquidity for collected fee balances at current slot0 price
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(rec.poolId);
        uint128 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(rec.tickLower),
            TickMath.getSqrtPriceAtTick(rec.tickUpper),
            earned0,
            earned1
        );
        if (liquidityToAdd == 0) revert NothingToClaim();

        if (!key.currency0.isAddressZero() && earned0 > 0) {
            _approvePermit2(Currency.unwrap(key.currency0), earned0);
        }
        if (!key.currency1.isAddressZero() && earned1 > 0) {
            _approvePermit2(Currency.unwrap(key.currency1), earned1);
        }

        uint128 liqBefore = POSITION_MANAGER.getPositionLiquidity(rec.lpTokenId);
        bool hasNativeEth = key.currency0.isAddressZero();

        bytes memory incActions = hasNativeEth
            ? abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));

        bytes[] memory incParams = new bytes[](hasNativeEth ? 3 : 2);
        incParams[0] = abi.encode(rec.lpTokenId, uint256(liquidityToAdd), uint128(earned0), uint128(earned1), bytes(""));
        incParams[1] = abi.encode(key.currency0, key.currency1);
        if (hasNativeEth) {
            incParams[2] = abi.encode(key.currency0, address(this));
        }

        POSITION_MANAGER.modifyLiquidities{value: hasNativeEth ? earned0 : 0}(
            abi.encode(incActions, incParams),
            block.timestamp
        );

        uint128 liqAfter = POSITION_MANAGER.getPositionLiquidity(rec.lpTokenId);
        addedLiquidity = liqAfter > liqBefore ? liqAfter - liqBefore : 0;
        rec.initialLiquidity += addedLiquidity;

        uint256 rem0 = _currencyBalance(key.currency0) - bal0Before;
        uint256 rem1 = _currencyBalance(key.currency1) - bal1Before;
        amount0Used = earned0 - rem0;
        amount1Used = earned1 - rem1;

        // Credit any unpairable leftover fee dust to configured feeRecipients
        if (rem0 > 0) _creditCurrency(launchId, key.currency0, rem0);
        if (rem1 > 0) _creditCurrency(launchId, key.currency1, rem1);

        emit LpFeesCompounded(launchId, addedLiquidity, amount0Used, amount1Used);
    }

    /// @notice Pull-based withdrawal of harvested LP fees for `msg.sender`.
    function claimFees(uint256 launchId, Currency currency) external nonReentrant returns (uint256 amount) {
        amount = claimableFees[launchId][msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        claimableFees[launchId][msg.sender][currency] = 0;
        _sendCurrency(currency, msg.sender, amount);

        emit LpFeesClaimed(launchId, msg.sender, currency, amount);
    }

    /// @notice Allows the creator/Safe to extend the LP lock duration (or permanently lock via uint64.max).
    function extendLpLock(uint256 launchId, uint64 newUnlockTime) external {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();
        if (newUnlockTime <= rec.lpUnlockTime) revert LockMustIncrease();

        rec.lpUnlockTime = newUnlockTime;
        if (newUnlockTime == type(uint64).max) {
            rec.lpVestingEnd = 0;
        } else if (rec.lpVestingEnd != 0 && rec.lpVestingEnd < newUnlockTime) {
            rec.lpVestingEnd = newUnlockTime;
        }
        emit LpLockExtended(launchId, newUnlockTime);
    }

    /// @notice Withdraws linearly unlocked LP principal between `lpUnlockTime` and `lpVestingEnd`
    ///         when a staged linear LP unlock schedule was configured at launch.
    function withdrawLinearLp(uint256 launchId, address recipient) external nonReentrant returns (uint128 toRemove) {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();
        if (rec.lpVestingEnd == 0) revert LinearLpNotConfigured();
        if (block.timestamp < rec.lpUnlockTime) {
            revert LpStillLocked(rec.lpUnlockTime, uint64(block.timestamp));
        }

        uint128 activeLiq = POSITION_MANAGER.getPositionLiquidity(rec.lpTokenId);
        uint128 totalTracked = activeLiq + rec.liquidityWithdrawn;

        uint256 unlockedTotal;
        if (block.timestamp >= rec.lpVestingEnd) {
            unlockedTotal = totalTracked;
        } else {
            uint256 elapsed = block.timestamp - rec.lpUnlockTime;
            uint256 duration = rec.lpVestingEnd - rec.lpUnlockTime;
            unlockedTotal = (uint256(totalTracked) * elapsed) / duration;
        }

        if (unlockedTotal <= rec.liquidityWithdrawn) revert NothingToClaim();
        toRemove = uint128(unlockedTotal - rec.liquidityWithdrawn);
        if (toRemove > activeLiq) toRemove = activeLiq;
        if (toRemove == 0) revert NothingToClaim();

        // Harvest accrued fees first so feeRecipients receive their exact share
        _harvestLpFees(launchId);

        rec.liquidityWithdrawn += toRemove;
        address to = recipient == address(0) ? rec.creator : recipient;
        PoolKey memory key = _poolKeys[launchId];

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory unlockParams = new bytes[](2);
        unlockParams[0] = abi.encode(rec.lpTokenId, uint256(toRemove), uint128(0), uint128(0), bytes(""));
        unlockParams[1] = abi.encode(key.currency0, key.currency1, to);

        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, unlockParams), block.timestamp);
        emit LinearLpWithdrawn(launchId, to, toRemove);
    }

    /// @notice Auto-harvests all remaining LP fees for co-recipients and releases the Uniswap v4
    ///         Position NFT to `recipient` once the mandatory lock (and any linear LP vest) expires.
    function unlockLp(uint256 launchId, address recipient) external nonReentrant {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();

        uint64 effectiveUnlock = rec.lpVestingEnd > rec.lpUnlockTime ? rec.lpVestingEnd : rec.lpUnlockTime;
        if (block.timestamp < effectiveUnlock) {
            revert LpStillLocked(effectiveUnlock, uint64(block.timestamp));
        }

        // Auto-harvest accrued fees so co-recipients cannot be bypassed at unlock
        _harvestLpFees(launchId);

        rec.lpUnlocked = true;
        address to = recipient == address(0) ? rec.creator : recipient;
        IERC721Transfer(address(POSITION_MANAGER)).transferFrom(address(this), to, rec.lpTokenId);

        emit LpUnlocked(launchId, to, rec.lpTokenId);
    }

    /// @notice Step 1 of two-step creator/Safe transfer (e.g., upgrading 1/1 wallet to 2/3 or 3/5 Safe).
    function proposeCreator(uint256 launchId, address newCreator) external {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (newCreator == address(0)) revert InvalidCreatorAddress();

        pendingCreator[launchId] = newCreator;
        emit CreatorProposed(launchId, rec.creator, newCreator);
    }

    /// @notice Step 2 of two-step creator/Safe transfer; must be signed by the proposed Safe/wallet.
    function acceptCreator(uint256 launchId) external {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (msg.sender != pendingCreator[launchId]) revert OnlyPendingCreator();

        address previous = rec.creator;
        rec.creator = msg.sender;
        delete pendingCreator[launchId];

        emit CreatorAccepted(launchId, previous, msg.sender);
    }

    /// @notice Anchors an immutable audit, tokenomics, or legal disclosure hash onto the Provenance Seal.
    function addDisclosureHash(uint256 launchId, bytes32 docHash, string calldata label) external {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (docHash == bytes32(0) || bytes(label).length == 0) revert InvalidTokenParams();

        _disclosures[launchId].push(
            DisclosureRecord({docHash: docHash, label: label, timestamp: uint64(block.timestamp)})
        );
        emit DisclosureAnchored(launchId, docHash, label);
    }

    /// @notice Claims unlocked tokens from a specific cap-table vesting tranche.
    function claimVestedTokens(uint256 launchId, uint256 trancheIndex)
        external
        nonReentrant
        returns (uint256 claimable)
    {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        VestingTranche[] storage tranches = _vestingTranches[launchId];
        if (trancheIndex >= tranches.length) revert InvalidVestingConfig();

        claimable = getClaimableVested(launchId, trancheIndex);
        if (claimable == 0) revert NothingToClaim();

        VestingTranche storage t = tranches[trancheIndex];
        t.claimedAmount += claimable;
        IERC20(rec.launchToken).safeTransfer(t.beneficiary, claimable);

        emit VestedTokensClaimed(launchId, trancheIndex, t.beneficiary, claimable);
    }

    /// @notice Claims unlocked tokens across all cap-table vesting tranches for `msg.sender`.
    function claimAllVestedTokens(uint256 launchId) external nonReentrant returns (uint256 totalClaimed) {
        LaunchRecord storage rec = _launches[launchId];
        if (rec.launchId == 0) revert InvalidTokenParams();
        VestingTranche[] storage tranches = _vestingTranches[launchId];

        for (uint256 i = 0; i < tranches.length; ++i) {
            if (tranches[i].beneficiary != msg.sender) continue;
            uint256 claimable = getClaimableVested(launchId, i);
            if (claimable > 0) {
                tranches[i].claimedAmount += claimable;
                totalClaimed += claimable;
                emit VestedTokensClaimed(launchId, i, msg.sender, claimable);
            }
        }
        if (totalClaimed == 0) revert NothingToClaim();
        IERC20(rec.launchToken).safeTransfer(msg.sender, totalClaimed);
    }

    /// @notice Returns currently claimable vested tokens for a specific tranche.
    function getClaimableVested(uint256 launchId, uint256 trancheIndex) public view returns (uint256) {
        VestingTranche[] storage tranches = _vestingTranches[launchId];
        if (trancheIndex >= tranches.length) return 0;
        VestingTranche storage t = tranches[trancheIndex];
        if (t.totalAmount == 0 || block.timestamp < t.cliffEnd) return 0;

        uint256 unlocked;
        if (block.timestamp >= t.vestingEnd) {
            unlocked = t.totalAmount;
        } else {
            uint256 elapsed = block.timestamp - t.cliffEnd;
            uint256 duration = t.vestingEnd - t.cliffEnd;
            unlocked = (t.totalAmount * elapsed) / duration;
        }
        return unlocked - t.claimedAmount;
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
            pendingCreator: pendingCreator[launchId],
            blueprint: rec.blueprint,
            isNativeBlueprint: rec.isNativeBlueprint,
            lpUnlocked: rec.lpUnlocked,
            baseLpFeePips: rec.baseLpFeePips,
            snipePreset: rec.snipePreset,
            totalSupply: rec.totalSupply,
            poolTokenAmount: rec.poolTokenAmount,
            initialQuoteAmount: rec.initialQuoteAmount,
            pairedSupplyBps: pairedBps,
            initialLiquidity: rec.initialLiquidity,
            liquidityWithdrawn: rec.liquidityWithdrawn,
            lpUnlockTime: rec.lpUnlockTime,
            lpVestingEnd: rec.lpVestingEnd,
            vestedTotal: rec.vestedTotal,
            devBuyQuoteAmount: rec.devBuyQuoteAmount,
            devBuyTokensBought: rec.devBuyTokensBought,
            hookAddress: address(HOOK),
            treasuryAddress: TREASURY,
            feeRecipients: _feeRecipients[launchId],
            feeSharesBps: _feeSharesBps[launchId],
            vestingTranches: _vestingTranches[launchId],
            disclosures: _disclosures[launchId]
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
        _pendingDevBuy.tokensBought = tokensBought;
        emit DevBuyExecuted(buy.key.toId(), buy.recipient, buy.quoteAmountIn, tokensBought);
        return bytes("");
    }

    function _validateLaunchConfig(
        uint256 totalSupply,
        uint256 poolTokenAmount,
        PoolLaunchConfig calldata cfg
    ) internal view returns (uint256 totalVested) {
        if (poolTokenAmount == 0) revert InsufficientPoolAllocation();
        if (poolTokenAmount * BPS_DENOMINATOR < totalSupply * MIN_POOL_ALLOCATION_BPS) {
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
            VestingTrancheInput calldata t = cfg.vestingTranches[i];
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

        // Snapshot pre-existing contract balances so refunds only ever return caller's exact unused delta
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

        // Effects: record launch metadata and vesting tranches before external interactions
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
            creator: creatorAddr,
            blueprint: blueprint,
            isNativeBlueprint: isNativeBlueprint,
            lpUnlocked: false,
            baseLpFeePips: cfg.baseLpFeePips,
            tickLower: cfg.tickLower,
            tickUpper: cfg.tickUpper,
            snipePreset: cfg.snipePreset,
            totalSupply: totalSupply,
            poolTokenAmount: cfg.poolTokenAmount,
            initialQuoteAmount: cfg.quoteTokenAmount,
            initialLiquidity: liquidity,
            liquidityWithdrawn: 0,
            lpUnlockTime: lpUnlockTime,
            lpVestingEnd: lpVestingEnd,
            vestedTotal: totalVested,
            devBuyQuoteAmount: cfg.devBuyQuoteAmount,
            devBuyTokensBought: 0
        });

        _poolKeys[launchId] = poolKey;
        launchIdByToken[launchToken] = launchId;
        launchIdByPool[poolId] = launchId;

        if (cfg.feeRecipients.length == 0) {
            _feeRecipients[launchId].push(creatorAddr);
            _feeSharesBps[launchId].push(uint16(BPS_DENOMINATOR));
        } else {
            for (uint256 i = 0; i < cfg.feeRecipients.length; ++i) {
                _feeRecipients[launchId].push(cfg.feeRecipients[i]);
                _feeSharesBps[launchId].push(cfg.feeSharesBps[i]);
            }
        }

        for (uint256 i = 0; i < cfg.vestingTranches.length; ++i) {
            VestingTrancheInput calldata t = cfg.vestingTranches[i];
            uint64 cliffEnd = nowTs + t.cliffDuration;
            _vestingTranches[launchId].push(
                VestingTranche({
                    beneficiary: t.beneficiary,
                    totalAmount: t.amount,
                    claimedAmount: 0,
                    cliffEnd: cliffEnd,
                    vestingEnd: cliffEnd + t.vestingDuration
                })
            );
        }

        // Interactions
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

        // Enforce >= 99% of both poolTokenAmount and quoteTokenAmount actually settled into PoolManager
        uint256 remLaunchToken = IERC20(launchToken).balanceOf(address(this));
        if (remLaunchToken < totalVested) revert PriceRangeMismatch();
        uint256 unusedPoolTokens = remLaunchToken - totalVested;
        uint256 actualPooledTokens = cfg.poolTokenAmount - unusedPoolTokens;
        if (actualPooledTokens * BPS_DENOMINATOR < cfg.poolTokenAmount * 9_900) {
            revert PriceRangeMismatch();
        }

        if (isNativeEth) {
            uint256 ethAfterMint = address(this).balance;
            uint256 ethSpentOnLp = (ethBalStart + msg.value) - ethAfterMint;
            if (ethSpentOnLp * BPS_DENOMINATOR < cfg.quoteTokenAmount * 9_900) {
                revert PriceRangeMismatch();
            }
        } else {
            uint256 usdcAfterMint = IERC20(USDC).balanceOf(address(this));
            uint256 usdcSpentOnLp = (usdcBalStart + cfg.quoteTokenAmount + cfg.devBuyQuoteAmount) - usdcAfterMint;
            if (usdcSpentOnLp * BPS_DENOMINATOR < cfg.quoteTokenAmount * 9_900) {
                revert PriceRangeMismatch();
            }
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

        // Return exact unused deposit deltas only (never pre-existing contract balances)
        if (unusedPoolTokens > 0) {
            if (isNativeBlueprint && _vestingTranches[launchId].length > 0) {
                _vestingTranches[launchId][0].totalAmount += unusedPoolTokens;
                _launches[launchId].vestedTotal += unusedPoolTokens;
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

    function _harvestLpFees(uint256 launchId) internal returns (uint256 earned0, uint256 earned1) {
        LaunchRecord storage rec = _launches[launchId];
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
