// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISubscriptionService
/// @notice Reactive Network system contract interface — used for event subscriptions.
interface ISubscriptionService {
    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;
}

interface ISystemContract is ISubscriptionService {}

/// @title IReactive
/// @notice Core interface implemented by all Reactive Contracts.
interface IReactive {
    struct LogRecord {
        uint256 chain_id;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
        bytes data;
        uint256 block_number;
        uint256 op_code;
        uint256 block_hash;
        uint256 tx_hash;
        uint256 log_index;
    }

    /// @notice Emitted to trigger a callback transaction on a destination chain.
    event Callback(
        uint256 indexed chain_id,
        address indexed _contract,
        uint64 indexed gas_limit,
        bytes payload
    );

    /// @notice Entry point for handling new event notifications from the Reactive Network.
    function react(LogRecord calldata log) external;
}
