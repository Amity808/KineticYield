// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractCallback} from "@reactive-lib/abstract-base/AbstractCallback.sol";

/// @title KineticCallback
/// @notice Simplified destination contract deployed on Sepolia (or any destination chain).
///         Receives reactive callbacks from the Reactive Network when YieldScout determines
///         that liquidity should be rebalanced.
///
///         This contract extends AbstractCallback which provides:
///         - `rvmIdOnly` modifier for callback authorization
///         - `pay()` / `coverDebt()` for Reactive Network payment handling
///         - Authorized sender management
///
///         In production, this logic would be merged into KineticHook.sol (the v4 Hook).
///         For testnet demonstration, this standalone receiver proves the cross-chain
///         reactive callback flow works end-to-end.
contract KineticCallback is AbstractCallback {

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    /// @notice Emitted when a rebalance callback is received from the Reactive Network.
    event RebalanceTriggered(
        address indexed sourcePool,
        uint128 liquidity,
        bytes bridgeData
    );

    /// @notice Emitted as a bridge intent stub.
    event BridgeInitiated(bytes bridgeData);

    /// @notice Emitted on any callback received (for testing/monitoring).
    event CallbackReceived(
        address indexed rvmId,
        address indexed sourcePool,
        uint256 sourceChainId
    );

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    /// @notice Count of rebalance callbacks received.
    uint256 public rebalanceCount;

    /// @notice Last source chain ID that triggered a rebalance.
    uint256 public lastSourceChainId;

    /// @notice Last source pool that triggered a rebalance.
    address public lastSourcePool;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /// @param _callback_sender The Callback Proxy address on this chain
    ///        (Sepolia: 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA)
    constructor(address _callback_sender) payable AbstractCallback(_callback_sender) {}

    // ─────────────────────────────────────────────────────────────
    //  Reactive Callback Handler
    // ─────────────────────────────────────────────────────────────

    /// @notice Called by the Reactive Network (via Callback Proxy) when YieldScout
    ///         determines a rebalance is needed.
    ///
    /// @dev Note: The first parameter `_rvm_id` is automatically injected by the
    ///      Reactive Network — it replaces whatever value was in the first 160 bits
    ///      of the callback payload with the deployer's ReactVM ID.
    ///
    /// @param _rvm_id           The ReactVM ID (injected by Reactive Network).
    /// @param sourcePool        The pool on the source chain with higher yield.
    /// @param liquidityAmount   Suggested liquidity to move (in v4 LP units).
    /// @param bridgeData        ABI-encoded bridge payload (source chain, pool, yield velocity).
    function handleReactiveRebalance(
        address _rvm_id,
        address sourcePool,
        uint128 liquidityAmount,
        bytes calldata bridgeData
    ) external rvmIdOnly(_rvm_id) {
        // Decode bridge data for logging
        (uint256 sourceChainId,,) = abi.decode(bridgeData, (uint256, address, uint256));

        // Update state
        rebalanceCount++;
        lastSourceChainId = sourceChainId;
        lastSourcePool = sourcePool;

        // Emit events — in production, a vault contract listens to these
        emit CallbackReceived(_rvm_id, sourcePool, sourceChainId);
        emit RebalanceTriggered(sourcePool, liquidityAmount, bridgeData);
        emit BridgeInitiated(bridgeData);
    }
}
