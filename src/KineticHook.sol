// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title KineticHook
/// @notice Uniswap v4 Hook that tracks per-pool "Yield Velocity" (swap fees generated per unit of liquidity)
///         and exposes a `handleReactiveRebalance` function that can only be called by an authorized
///         Reactive Network contract. When triggered, it withdraws liquidity from the current pool
///         so that the LP vault can bridge assets to a higher-yield destination chain.
///
///         Architecture:
///           ┌─────────────┐     (1) Swap events monitored     ┌─────────────────────┐
///           │  Uniswap v4 │ ─────────────────────────────────►│  Reactive Network    │
///           │  KineticHook│                                    │  (YieldScout.sol)   │
///           │             │ ◄───────────────────────────────── │  AI updates params  │
///           └─────────────┘  (2) handleReactiveRebalance()     └─────────────────────┘
///                |
///                | (3) modifyLiquidity (withdraw)
///                | (4) emit BridgeInitiated(bridgeData)
///                ▼
///           Bridge Provider (LayerZero / CCIP)
contract KineticHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    /// @notice Emitted whenever the Reactive Network triggers a rebalance.
    /// @param poolId        The pool liquidity is being withdrawn from.
    /// @param liquidity     Amount of liquidity removed.
    /// @param bridgeData    Encoded calldata forwarded to the bridge provider.
    event RebalanceTriggered(PoolId indexed poolId, uint128 liquidity, bytes bridgeData);

    /// @notice Emitted when the bridge call stub fires. Replace with real bridge in production.
    /// @param bridgeData    The raw bridge payload (destination chain, recipient, amount, etc.).
    event BridgeInitiated(bytes bridgeData);

    /// @notice Emitted when the owner toggles the emergency pause.
    event EmergencyPauseToggled(bool paused);

    /// @notice Emitted when the Reactive sender address is updated.
    event ReactiveSenderUpdated(address indexed oldSender, address indexed newSender);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    /// @notice The owner of the hook — can update the Reactive sender and toggle pause.
    address public owner;

    /// @notice The ONLY address authorized to call `handleReactiveRebalance`.
    ///         This should be the Reactive Network callback proxy contract.
    address public reactiveSender;

    /// @notice When true, AI-reactive triggers are suspended and only the owner can resume.
    bool public paused;

    // ── Per-pool yield-velocity state ──────────────────────────────

    /// @notice Cumulative swap volume (token0 units) observed by this hook per pool.
    mapping(PoolId => uint256) public cumulativeVolume;

    /// @notice Number of swaps tracked per pool — used with liquidity depth for a simple
    ///         "Yield Velocity" approximation ( swapCount / sqrt(liquidity) ).
    mapping(PoolId => uint256) public swapCount;

    /// @notice The fee tier of the pool (basis points). Stored on first swap.
    mapping(PoolId => uint24) public poolFee;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────

    error Unauthorized();
    error ReactivePaused();
    error ZeroAddress();
    error LiquidityWithdrawFailed();
    error SafeCastOverflow();

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyReactive() {
        if (msg.sender != reactiveSender) revert Unauthorized();
        if (paused) revert ReactivePaused();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /// @param _poolManager         Uniswap v4 PoolManager.
    /// @param _reactiveSender      The Reactive Network callback proxy authorized to call rebalance.
    constructor(IPoolManager _poolManager, address _reactiveSender) BaseHook(_poolManager) {
        if (_reactiveSender == address(0)) revert ZeroAddress();
        owner = msg.sender;
        reactiveSender = _reactiveSender;
    }

    // ─────────────────────────────────────────────────────────────
    //  Hook Permissions
    // ─────────────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,  // Capture fee tier on first swap
            afterSwap: true,   // Accumulate volume + swap count for yield tracking
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────
    //  Hook Callbacks (internal overrides)
    // ─────────────────────────────────────────────────────────────

    /// @dev beforeSwap — stores fee tier if not already set.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (poolFee[id] == 0) {
            // fee encoded in PoolKey.fee (uint24)
            poolFee[id] = key.fee;
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev afterSwap — accumulates volume and swap count for Yield Velocity calculation.
    ///      Uses the absolute value of the BalanceDelta.amount0() to measure volume.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        unchecked {
            // amount0 is negative for exact-input swaps (tokens leaving the pool)
            int128 a0 = delta.amount0();
            cumulativeVolume[id] += a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
            swapCount[id]++;
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    // ─────────────────────────────────────────────────────────────
    //  Yield Velocity View
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns a simple "Yield Velocity" proxy: cumulative fee income per unit of liquidity.
    ///         yieldVelocity = (cumulativeVolume * fee) / (currentLiquidity + 1)
    ///         The off-chain AI agent and YieldScout.sol use this value to compare pools.
    /// @param key  The PoolKey to query.
    function yieldVelocity(PoolKey calldata key) external view returns (uint256) {
        PoolId id = key.toId();
        uint128 liq = poolManager.getLiquidity(id);
        uint24 fee = poolFee[id] == 0 ? key.fee : poolFee[id];
        // Scale: volume * fee (in bps) / liquidity
        return (cumulativeVolume[id] * uint256(fee)) / (uint256(liq) + 1);
    }

    // ─────────────────────────────────────────────────────────────
    //  Reactive Callback — The Heart of KineticYield
    // ─────────────────────────────────────────────────────────────

    /// @notice Called exclusively by the authorized Reactive Network contract when it determines
    ///         that liquidity should be moved to a higher-yield pool on another chain.
    ///
    /// @dev Architecture note: This function acts as a pure "Signal & Bridge" mechanism.
    ///      In production, a companion vault contract listens to `RebalanceTriggered` and
    ///      calls `IPositionManager.decreaseLiquidity` + `bridge.send(...)` autonomously.
    ///      This separation cleanly decouples the hook's signaling role from vault execution.
    ///
    /// @param key              The PoolKey describing the pool to rebalance.
    /// @param liquidityAmount  How much liquidity (in v4 LP units) the vault should remove.
    /// @param bridgeData       ABI-encoded payload for the bridge provider.
    function handleReactiveRebalance(
        PoolKey calldata key,
        uint128 liquidityAmount,
        int24 /* tickLower */,
        int24 /* tickUpper */,
        bytes calldata bridgeData
    ) external onlyReactive {
        PoolId id = key.toId();

        // 1. Emit the on-chain signal — the vault contract (external) listens for this
        //    and executes the actual decreaseLiquidity + bridge transfer.
        emit RebalanceTriggered(id, liquidityAmount, bridgeData);

        // 2. Emit the bridge intent stub.
        //    In production: the vault calls LayerZero `endpoint.send(...)` or
        //                   Chainlink CCIP `router.ccipSend(...)` using bridgeData.
        emit BridgeInitiated(bridgeData);
    }

    /// @notice Internal helper for direct hook-level liquidity withdrawal.
    ///         Called via `poolManager.unlock(...)` when the hook itself holds LP positions
    ///         (i.e., when operated as a self-custodial vault rather than a signal-only hook).
    /// @dev NOT called by `handleReactiveRebalance` in the default architecture.
    ///      Exposed here for production integrators who need it via a custom unlock path.
    function _executeLiquidityWithdrawal(
        PoolKey memory key,
        uint128 liquidityAmount,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (int128 delta0, int128 delta1) {
        if (liquidityAmount > uint128(type(int128).max)) revert SafeCastOverflow();

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int128(liquidityAmount),
            salt: bytes32(0)
        });

        (, BalanceDelta feeDelta) = poolManager.modifyLiquidity(key, params, bytes(""));

        delta0 = feeDelta.amount0();
        delta1 = feeDelta.amount1();

        if (delta0 > 0) poolManager.take(key.currency0, address(this), uint128(delta0));
        if (delta1 > 0) poolManager.take(key.currency1, address(this), uint128(delta1));
    }

    /// @dev Called by PoolManager during an `unlock` for self-custodial vault mode.
    ///      Not used in signal-only mode.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();

        (PoolKey memory key, uint128 liquidityAmount, int24 tickLower, int24 tickUpper) =
            abi.decode(data, (PoolKey, uint128, int24, int24));

        (int128 delta0, int128 delta1) = _executeLiquidityWithdrawal(key, liquidityAmount, tickLower, tickUpper);
        return abi.encode(delta0, delta1);
    }

    // ─────────────────────────────────────────────────────────────
    //  Emergency Manual Mode (Owner-Only)
    // ─────────────────────────────────────────────────────────────

    /// @notice Pause/unpause AI-reactive triggers. Only the owner can call this.
    ///         When paused, `handleReactiveRebalance` will revert, giving the owner
    ///         time to audit state or upgrade the Reactive contract.
    function setEmergencyPause(bool _paused) external onlyOwner {
        paused = _paused;
        emit EmergencyPauseToggled(_paused);
    }

    /// @notice Update the authorized Reactive Network sender. Use with caution.
    function setReactiveSender(address _newSender) external onlyOwner {
        if (_newSender == address(0)) revert ZeroAddress();
        emit ReactiveSenderUpdated(reactiveSender, _newSender);
        reactiveSender = _newSender;
    }

    /// @notice Transfer ownership of the hook.
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        owner = _newOwner;
    }
}
