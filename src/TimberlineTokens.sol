// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title IERC7802
/// @notice Minimal SuperchainERC20 cross-chain mint/burn interface (ERC-7802).
interface IERC7802 is IERC165 {
    event CrosschainMint(address indexed to, uint256 amount, address indexed sender);
    event CrosschainBurn(address indexed from, uint256 amount, address indexed sender);

    function crosschainMint(address _to, uint256 _amount) external;
    function crosschainBurn(address _from, uint256 _amount) external;
}

/// @title TimberlineStandardToken
/// @notice Fixed-supply ERC-20 with EIP-2612 gasless permit approvals and zero admin keys.
contract TimberlineStandardToken is ERC20, ERC20Permit {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(recipient_, totalSupply_);
    }
}

/// @title TimberlineBurnableToken
/// @notice Fixed-max-supply ERC-20 with EIP-2612 permit and holder-initiated burn support.
contract TimberlineBurnableToken is ERC20, ERC20Permit, ERC20Burnable {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(recipient_, totalSupply_);
    }
}

/// @title TimberlineGovernanceToken
/// @notice Fixed-supply ERC-20 with EIP-2612 permit and ERC-6372 timestamp-indexed voting power.
contract TimberlineGovernanceToken is ERC20, ERC20Permit, ERC20Votes {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(recipient_, totalSupply_);
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

/// @title TimberlineSuperchainToken
/// @notice Zero-admin SuperchainERC20 (ERC-7802) with EIP-2612 permit, restricted strictly to
///         the canonical OP Stack SuperchainTokenBridge predeploy (0x4200...0028).
contract TimberlineSuperchainToken is ERC20, ERC20Permit, IERC7802 {
    address public constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;

    error UnauthorizedSuperchainBridge();

    modifier onlySuperchainBridge() {
        if (msg.sender != SUPERCHAIN_TOKEN_BRIDGE) revert UnauthorizedSuperchainBridge();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(recipient_, totalSupply_);
    }

    function crosschainMint(address _to, uint256 _amount) external override onlySuperchainBridge {
        _mint(_to, _amount);
        emit CrosschainMint(_to, _amount, msg.sender);
    }

    function crosschainBurn(address _from, uint256 _amount) external override onlySuperchainBridge {
        _burn(_from, _amount);
        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC7802).interfaceId
            || interfaceId == type(IERC20).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

interface IBlueprintSubFactory {
    function deploy(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_,
        bytes32 salt_
    ) external returns (address);

    function initCodeHash(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_
    ) external pure returns (bytes32);
}

contract TimberlineStandardFactory is IBlueprintSubFactory {
    address public immutable DEPLOYER;

    error OnlyDeployer();

    constructor() {
        DEPLOYER = msg.sender;
    }

    function deploy(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_,
        bytes32 salt_
    ) external returns (address) {
        if (msg.sender != DEPLOYER) revert OnlyDeployer();
        return address(new TimberlineStandardToken{salt: salt_}(name_, symbol_, totalSupply_, recipient_));
    }

    function initCodeHash(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_
    ) external pure returns (bytes32) {
        return keccak256(
            bytes.concat(type(TimberlineStandardToken).creationCode, abi.encode(name_, symbol_, totalSupply_, recipient_))
        );
    }
}

contract TimberlineBurnableFactory is IBlueprintSubFactory {
    address public immutable DEPLOYER;

    error OnlyDeployer();

    constructor() {
        DEPLOYER = msg.sender;
    }

    function deploy(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_,
        bytes32 salt_
    ) external returns (address) {
        if (msg.sender != DEPLOYER) revert OnlyDeployer();
        return address(new TimberlineBurnableToken{salt: salt_}(name_, symbol_, totalSupply_, recipient_));
    }

    function initCodeHash(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_
    ) external pure returns (bytes32) {
        return keccak256(
            bytes.concat(type(TimberlineBurnableToken).creationCode, abi.encode(name_, symbol_, totalSupply_, recipient_))
        );
    }
}

contract TimberlineGovernanceFactory is IBlueprintSubFactory {
    address public immutable DEPLOYER;

    error OnlyDeployer();

    constructor() {
        DEPLOYER = msg.sender;
    }

    function deploy(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_,
        bytes32 salt_
    ) external returns (address) {
        if (msg.sender != DEPLOYER) revert OnlyDeployer();
        return address(new TimberlineGovernanceToken{salt: salt_}(name_, symbol_, totalSupply_, recipient_));
    }

    function initCodeHash(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_
    ) external pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                type(TimberlineGovernanceToken).creationCode, abi.encode(name_, symbol_, totalSupply_, recipient_)
            )
        );
    }
}

contract TimberlineSuperchainFactory is IBlueprintSubFactory {
    address public immutable DEPLOYER;

    error OnlyDeployer();

    constructor() {
        DEPLOYER = msg.sender;
    }

    function deploy(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_,
        bytes32 salt_
    ) external returns (address) {
        if (msg.sender != DEPLOYER) revert OnlyDeployer();
        return address(new TimberlineSuperchainToken{salt: salt_}(name_, symbol_, totalSupply_, recipient_));
    }

    function initCodeHash(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_
    ) external pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                type(TimberlineSuperchainToken).creationCode, abi.encode(name_, symbol_, totalSupply_, recipient_)
            )
        );
    }
}

/// @title TimberlineTokenDeployer v2
/// @notice Immutable, stateless deterministic CREATE2 token blueprint factory callable solely
///         by TimberlineLaunchpad.
contract TimberlineTokenDeployer {
    enum Blueprint {
        STANDARD,
        BURNABLE,
        GOVERNANCE,
        SUPERCHAIN
    }

    address public immutable LAUNCHPAD;
    IBlueprintSubFactory public immutable STANDARD_FACTORY;
    IBlueprintSubFactory public immutable BURNABLE_FACTORY;
    IBlueprintSubFactory public immutable GOVERNANCE_FACTORY;
    IBlueprintSubFactory public immutable SUPERCHAIN_FACTORY;

    error OnlyLaunchpad();
    error ZeroLaunchpad();

    constructor(address _launchpad) {
        if (_launchpad == address(0)) revert ZeroLaunchpad();
        LAUNCHPAD = _launchpad;
        STANDARD_FACTORY = new TimberlineStandardFactory();
        BURNABLE_FACTORY = new TimberlineBurnableFactory();
        GOVERNANCE_FACTORY = new TimberlineGovernanceFactory();
        SUPERCHAIN_FACTORY = new TimberlineSuperchainFactory();
    }

    function deployToken(
        Blueprint blueprint,
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_,
        address creator_,
        bytes32 userSalt_
    ) external returns (address token) {
        if (msg.sender != LAUNCHPAD) revert OnlyLaunchpad();
        bytes32 salt = keccak256(abi.encode(creator_, userSalt_));
        return _factoryFor(blueprint).deploy(name_, symbol_, totalSupply_, recipient_, salt);
    }

    /// @notice Precomputes the deterministic CREATE2 token address for a given creator and salt.
    function computeTokenAddress(
        Blueprint blueprint,
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address creator_,
        bytes32 userSalt_
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(creator_, userSalt_));
        IBlueprintSubFactory factory = _factoryFor(blueprint);
        bytes32 codeHash = factory.initCodeHash(name_, symbol_, totalSupply_, LAUNCHPAD);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash));
        return address(uint160(uint256(hash)));
    }

    function _factoryFor(Blueprint blueprint) internal view returns (IBlueprintSubFactory) {
        if (blueprint == Blueprint.STANDARD) return STANDARD_FACTORY;
        if (blueprint == Blueprint.BURNABLE) return BURNABLE_FACTORY;
        if (blueprint == Blueprint.GOVERNANCE) return GOVERNANCE_FACTORY;
        return SUPERCHAIN_FACTORY;
    }
}
