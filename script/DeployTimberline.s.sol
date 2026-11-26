// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {TimberlineHook} from "../src/TimberlineHook.sol";
import {TimberlineTokenDeployer} from "../src/TimberlineTokens.sol";
import {TimberlineVault} from "../src/TimberlineVault.sol";
import {TimberlineLaunchpad} from "../src/TimberlineLaunchpad.sol";
import {TimberlineProvenance} from "../src/TimberlineProvenance.sol";

contract DeployTimberline is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        (address poolManager, address positionManager, address usdc, string memory netName) =
            block.chainid == 8453
                ? (
                    0x498581fF718922c3f8e6A244956aF099B2652b2b,
                    0x7C5f5A4bBd8fD63184577525326123B519429bDc,
                    0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                    "Base Mainnet (8453)"
                )
                : (
                    0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                    0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80,
                    0x036CbD53842c5426634e7929541eC2318f3dCF7e,
                    "Base Sepolia Testnet (84532)"
                );

        uint64 baseNonce = vm.getNonce(deployer);
        address predictedVault = vm.computeCreateAddress(deployer, baseNonce + 1);
        address predictedTokenDeployer = vm.computeCreateAddress(deployer, baseNonce + 2);
        address predictedLaunchpad = vm.computeCreateAddress(deployer, baseNonce + 3);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address expectedHook, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(TimberlineHook).creationCode,
            abi.encode(poolManager, predictedLaunchpad, treasury)
        );

        vm.startBroadcast(deployerPk);
        TimberlineHook hook = new TimberlineHook{salt: salt}(IPoolManager(poolManager), predictedLaunchpad, treasury);
        TimberlineVault vault = new TimberlineVault(
            IPoolManager(poolManager),
            IPositionManager(positionManager),
            IAllowanceTransfer(PERMIT2),
            predictedLaunchpad
        );
        TimberlineTokenDeployer tokenDeployer = new TimberlineTokenDeployer(predictedLaunchpad);
        TimberlineLaunchpad launchpad = new TimberlineLaunchpad(
            IPoolManager(poolManager),
            IPositionManager(positionManager),
            IAllowanceTransfer(PERMIT2),
            hook,
            tokenDeployer,
            vault,
            treasury,
            usdc
        );
        TimberlineProvenance provenance = new TimberlineProvenance(launchpad, vault);
        vm.stopBroadcast();

        require(address(hook) == expectedHook, "HOOK_ADDR_MISMATCH");
        require(address(vault) == predictedVault, "VAULT_ADDR_MISMATCH");
        require(address(tokenDeployer) == predictedTokenDeployer, "TOKEN_DEPLOYER_MISMATCH");
        require(address(launchpad) == predictedLaunchpad, "LAUNCHPAD_ADDR_MISMATCH");

        console2.log("=== TIMBERLINE V2 ECTS DEPLOYED ON", netName, "===");
        console2.log("Deployer:               ", deployer);
        console2.log("Treasury:               ", treasury);
        console2.log("TimberlineHook v2:      ", address(hook));
        console2.log("TimberlineVault v2:     ", address(vault));
        console2.log("TimberlineTokenDeployer:", address(tokenDeployer));
        console2.log("TimberlineLaunchpad v2: ", address(launchpad));
        console2.log("TimberlineProvenance:   ", address(provenance));
        console2.log("USDC Asset:             ", usdc);
    }
}
