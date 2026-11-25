// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

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
/// @notice Fixed-supply ERC-20 with EIP-2612 permit and historical on-chain voting checkpoints.
contract TimberlineGovernanceToken is ERC20, ERC20Permit, ERC20Votes {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(recipient_, totalSupply_);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

/// @title TimberlineTokenDeployer
/// @notice Immutable, stateless token blueprint factory callable solely by TimberlineLaunchpad.
contract TimberlineTokenDeployer {
    enum Blueprint {
        STANDARD,
        BURNABLE,
        GOVERNANCE
    }

    address public immutable LAUNCHPAD;

    error OnlyLaunchpad();

    constructor(address _launchpad) {
        require(_launchpad != address(0), "ZERO_ADDR");
        LAUNCHPAD = _launchpad;
    }

    function deployToken(
        Blueprint blueprint,
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        address recipient_
    ) external returns (address token) {
        if (msg.sender != LAUNCHPAD) revert OnlyLaunchpad();

        if (blueprint == Blueprint.STANDARD) {
            token = address(new TimberlineStandardToken(name_, symbol_, totalSupply_, recipient_));
        } else if (blueprint == Blueprint.BURNABLE) {
            token = address(new TimberlineBurnableToken(name_, symbol_, totalSupply_, recipient_));
        } else {
            token = address(new TimberlineGovernanceToken(name_, symbol_, totalSupply_, recipient_));
        }
    }
}
