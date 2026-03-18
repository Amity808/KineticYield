// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {KineticHook} from "../src/KineticHook.sol";

/// @notice Mines the address and deploys the KineticHook contract
/// @dev Requires REACTIVE_SENDER env var — the Reactive Network callback proxy address.
///      Deploy on Unichain Sepolia (chain 1301):
///
///      forge script script/00_DeployHook.s.sol \
///        --rpc-url unichain_sepolia \
///        --account <YOUR_KEYSTORE_ACCOUNT> \
///        --sender  <YOUR_WALLET_ADDRESS> \
///        --broadcast \
///        --verify
contract DeployHookScript is BaseScript {
    function run() public {
        // KineticHook uses beforeSwap + afterSwap only
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        address reactiveSender = vm.envAddress("REACTIVE_SENDER");

        // Mine a salt that produces a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager, reactiveSender);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(KineticHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        KineticHook hook = new KineticHook{salt: salt}(poolManager, reactiveSender);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
