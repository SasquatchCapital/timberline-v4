// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC721Transfer {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title TimberlineVault
/// @notice Non-custodial, immutable LP locker, fee splitter, auto-compounder, Safe creator
///         controller, and multi-tranche vesting vault for Timberline v2 launches.
contract TimberlineVault is ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    IPoolManager public immutable POOL_MANAGER;
    IPositionManager public immutable POSITION_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;
    address public immutable LAUNCHPAD;

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

    struct VaultInitParams {
        uint256 launchId;
        address launchToken;
        PoolId poolId;
        PoolKey poolKey;
        uint256 lpTokenId;
        address creator;
        int24 tickLower;
        int24 tickUpper;
        uint128 initialLiquidity;
        uint64 lpUnlockTime;
        uint64 lpVestingEnd;
        uint256 vestedTotal;
        VestingTrancheInput[] vestingTranches;
        address[] feeRecipients;
        uint16[] feeSharesBps;
    }

    struct VaultRecord {
        uint256 launchId;
        address launchToken;
        PoolId poolId;
        uint256 lpTokenId;
        address creator;
        bool lpUnlocked;
        int24 tickLower;
        int24 tickUpper;
        uint128 initialLiquidity;
        uint128 liquidityWithdrawn;
        uint64 lpUnlockTime;
        uint64 lpVestingEnd;
        uint256 vestedTotal;
    }

    mapping(uint256 => VaultRecord) private _vaults;
    mapping(uint256 => PoolKey) private _poolKeys;
    mapping(uint256 => address[]) private _feeRecipients;
    mapping(uint256 => uint16[]) private _feeSharesBps;
    mapping(uint256 => VestingTranche[]) private _vestingTranches;
    mapping(uint256 => DisclosureRecord[]) private _disclosures;
    mapping(uint256 => address) public pendingCreator;
    mapping(uint256 => mapping(address => mapping(Currency => uint256))) public claimableFees;

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

    error OnlyLaunchpad();
    error InvalidLaunchId();
    error InvalidParams();
    error OnlyCreator();
    error OnlyPendingCreator();
    error InvalidCreatorAddress();
    error LpStillLocked(uint64 unlockTime, uint64 currentTime);
    error LpAlreadyUnlocked();
    error LinearLpNotConfigured();
    error LockMustIncrease();
    error NothingToClaim();
    error EthTransferFailed();

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2,
        address _launchpad
    ) {
        require(_launchpad != address(0), "ZERO_ADDR");
        POOL_MANAGER = _poolManager;
        POSITION_MANAGER = _positionManager;
        PERMIT2 = _permit2;
        LAUNCHPAD = _launchpad;
    }

    receive() external payable {}

    function registerLaunch(VaultInitParams calldata p) external {
        if (msg.sender != LAUNCHPAD) revert OnlyLaunchpad();

        _vaults[p.launchId] = VaultRecord({
            launchId: p.launchId,
            launchToken: p.launchToken,
            poolId: p.poolId,
            lpTokenId: p.lpTokenId,
            creator: p.creator,
            lpUnlocked: false,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            initialLiquidity: p.initialLiquidity,
            liquidityWithdrawn: 0,
            lpUnlockTime: p.lpUnlockTime,
            lpVestingEnd: p.lpVestingEnd,
            vestedTotal: p.vestedTotal
        });

        _poolKeys[p.launchId] = p.poolKey;

        if (p.feeRecipients.length == 0) {
            _feeRecipients[p.launchId].push(p.creator);
            _feeSharesBps[p.launchId].push(uint16(BPS_DENOMINATOR));
        } else {
            for (uint256 i = 0; i < p.feeRecipients.length; ++i) {
                _feeRecipients[p.launchId].push(p.feeRecipients[i]);
                _feeSharesBps[p.launchId].push(p.feeSharesBps[i]);
            }
        }

        uint64 nowTs = uint64(block.timestamp);
        for (uint256 i = 0; i < p.vestingTranches.length; ++i) {
            VestingTrancheInput calldata t = p.vestingTranches[i];
            uint64 cliffEnd = nowTs + t.cliffDuration;
            _vestingTranches[p.launchId].push(
                VestingTranche({
                    beneficiary: t.beneficiary,
                    totalAmount: t.amount,
                    claimedAmount: 0,
                    cliffEnd: cliffEnd,
                    vestingEnd: cliffEnd + t.vestingDuration
                })
            );
        }
    }

    function addVestingDust(uint256 launchId, uint256 dustAmount) external {
        if (msg.sender != LAUNCHPAD) revert OnlyLaunchpad();
        if (_vestingTranches[launchId].length > 0 && dustAmount > 0) {
            _vestingTranches[launchId][0].totalAmount += dustAmount;
            _vaults[launchId].vestedTotal += dustAmount;
        }
    }

    function harvestLpFees(uint256 launchId) external nonReentrant returns (uint256 earned0, uint256 earned1) {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();
        return _harvestLpFees(launchId);
    }

    function compoundLpFees(uint256 launchId)
        external
        nonReentrant
        returns (uint128 addedLiquidity, uint256 amount0Used, uint256 amount1Used)
    {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();

        PoolKey memory key = _poolKeys[launchId];
        uint256 bal0Before = _currencyBalance(key.currency0);
        uint256 bal1Before = _currencyBalance(key.currency1);

        bytes memory collectActions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory collectParams = new bytes[](2);
        collectParams[0] = abi.encode(rec.lpTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        collectParams[1] = abi.encode(key.currency0, key.currency1, address(this));
        _modLiq(collectActions, collectParams, 0);

        uint256 earned0 = _currencyBalance(key.currency0) - bal0Before;
        uint256 earned1 = _currencyBalance(key.currency1) - bal1Before;
        if (earned0 == 0 && earned1 == 0) revert NothingToClaim();

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

        _modLiq(incActions, incParams, hasNativeEth ? earned0 : 0);

        uint128 liqAfter = POSITION_MANAGER.getPositionLiquidity(rec.lpTokenId);
        addedLiquidity = liqAfter > liqBefore ? liqAfter - liqBefore : 0;
        rec.initialLiquidity += addedLiquidity;

        uint256 rem0 = _currencyBalance(key.currency0) - bal0Before;
        uint256 rem1 = _currencyBalance(key.currency1) - bal1Before;
        amount0Used = earned0 - rem0;
        amount1Used = earned1 - rem1;

        if (rem0 > 0) _creditCurrency(launchId, key.currency0, rem0);
        if (rem1 > 0) _creditCurrency(launchId, key.currency1, rem1);

        emit LpFeesCompounded(launchId, addedLiquidity, amount0Used, amount1Used);
    }

    function claimFees(uint256 launchId, Currency currency) external nonReentrant returns (uint256 amount) {
        amount = claimableFees[launchId][msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        claimableFees[launchId][msg.sender][currency] = 0;
        _sendCurrency(currency, msg.sender, amount);

        emit LpFeesClaimed(launchId, msg.sender, currency, amount);
    }

    function extendLpLock(uint256 launchId, uint64 newUnlockTime) external {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
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

    function withdrawLinearLp(uint256 launchId, address recipient) external nonReentrant returns (uint128 toRemove) {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
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

        _harvestLpFees(launchId);

        rec.liquidityWithdrawn += toRemove;
        address to = recipient == address(0) ? rec.creator : recipient;
        PoolKey memory key = _poolKeys[launchId];

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory unlockParams = new bytes[](2);
        unlockParams[0] = abi.encode(rec.lpTokenId, uint256(toRemove), uint128(0), uint128(0), bytes(""));
        unlockParams[1] = abi.encode(key.currency0, key.currency1, to);

        _modLiq(actions, unlockParams, 0);
        emit LinearLpWithdrawn(launchId, to, toRemove);
    }

    function unlockLp(uint256 launchId, address recipient) external nonReentrant {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (rec.lpUnlocked) revert LpAlreadyUnlocked();

        uint64 effectiveUnlock = rec.lpVestingEnd > rec.lpUnlockTime ? rec.lpVestingEnd : rec.lpUnlockTime;
        if (block.timestamp < effectiveUnlock) {
            revert LpStillLocked(effectiveUnlock, uint64(block.timestamp));
        }

        _harvestLpFees(launchId);

        rec.lpUnlocked = true;
        address to = recipient == address(0) ? rec.creator : recipient;
        IERC721Transfer(address(POSITION_MANAGER)).transferFrom(address(this), to, rec.lpTokenId);

        emit LpUnlocked(launchId, to, rec.lpTokenId);
    }

    function proposeCreator(uint256 launchId, address newCreator) external {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (newCreator == address(0)) revert InvalidCreatorAddress();

        pendingCreator[launchId] = newCreator;
        emit CreatorProposed(launchId, rec.creator, newCreator);
    }

    function acceptCreator(uint256 launchId) external {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
        if (msg.sender != pendingCreator[launchId]) revert OnlyPendingCreator();

        address previous = rec.creator;
        rec.creator = msg.sender;
        delete pendingCreator[launchId];

        emit CreatorAccepted(launchId, previous, msg.sender);
    }

    function addDisclosureHash(uint256 launchId, bytes32 docHash, string calldata label) external {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
        if (msg.sender != rec.creator) revert OnlyCreator();
        if (docHash == bytes32(0) || bytes(label).length == 0) revert InvalidParams();

        _disclosures[launchId].push(
            DisclosureRecord({docHash: docHash, label: label, timestamp: uint64(block.timestamp)})
        );
        emit DisclosureAnchored(launchId, docHash, label);
    }

    function claimVestedTokens(uint256 launchId, uint256 trancheIndex)
        external
        nonReentrant
        returns (uint256 claimable)
    {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
        VestingTranche[] storage tranches = _vestingTranches[launchId];
        if (trancheIndex >= tranches.length) revert InvalidParams();

        claimable = getClaimableVested(launchId, trancheIndex);
        if (claimable == 0) revert NothingToClaim();

        VestingTranche storage t = tranches[trancheIndex];
        t.claimedAmount += claimable;
        IERC20(rec.launchToken).safeTransfer(t.beneficiary, claimable);

        emit VestedTokensClaimed(launchId, trancheIndex, t.beneficiary, claimable);
    }

    function claimAllVestedTokens(uint256 launchId) external nonReentrant returns (uint256 totalClaimed) {
        VaultRecord storage rec = _vaults[launchId];
        if (rec.launchId == 0) revert InvalidLaunchId();
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

    function getVaultRecord(uint256 launchId) external view returns (VaultRecord memory) {
        return _vaults[launchId];
    }

    function getFeeRecipients(uint256 launchId) external view returns (address[] memory) {
        return _feeRecipients[launchId];
    }

    function getFeeSharesBps(uint256 launchId) external view returns (uint16[] memory) {
        return _feeSharesBps[launchId];
    }

    function getVestingTranches(uint256 launchId) external view returns (VestingTranche[] memory) {
        return _vestingTranches[launchId];
    }

    function getDisclosures(uint256 launchId) external view returns (DisclosureRecord[] memory) {
        return _disclosures[launchId];
    }

    function _harvestLpFees(uint256 launchId) internal returns (uint256 earned0, uint256 earned1) {
        VaultRecord storage rec = _vaults[launchId];
        PoolKey memory key = _poolKeys[launchId];
        uint256 bal0Before = _currencyBalance(key.currency0);
        uint256 bal1Before = _currencyBalance(key.currency1);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory unlockParams = new bytes[](2);
        unlockParams[0] = abi.encode(rec.lpTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        unlockParams[1] = abi.encode(key.currency0, key.currency1, address(this));

        _modLiq(actions, unlockParams, 0);

        earned0 = _currencyBalance(key.currency0) - bal0Before;
        earned1 = _currencyBalance(key.currency1) - bal1Before;

        if (earned0 > 0) _creditCurrency(launchId, key.currency0, earned0);
        if (earned1 > 0) _creditCurrency(launchId, key.currency1, earned1);

        emit LpFeesHarvested(launchId, earned0, earned1);
    }

    function _modLiq(bytes memory actions, bytes[] memory params, uint256 ethVal) private {
        POSITION_MANAGER.modifyLiquidities{value: ethVal}(abi.encode(actions, params), block.timestamp);
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
