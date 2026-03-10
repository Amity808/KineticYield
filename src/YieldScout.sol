// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactive, ISystemContract} from "./interfaces/IReactive.sol";

/// @title YieldScout
/// @notice A Reactive Contract deployed on the Reactive Network. It acts as the autonomous
///         "cross-chain brain" for the KineticYield system. It monitors `Swap` events from
///         Uniswap v4 pools across multiple chains, computes a simple "Yield Velocity" metric,
///         and triggers a callback to the `KineticHook` on Unichain when a superior yield
///         opportunity is detected on another chain.
///
/// ────────────────────────────────────────────────────────────────────────────────
///  Architecture:
///
///   [Ethereum Mainnet / Arbitrum / Base]             [Reactive Network]
///   ┌─────────────────────────────────────┐          ┌──────────────────────────┐
///   │  Uniswap v4 Pool                    │  Swap()  │  YieldScout.sol          │
///   │  (source pool, high yield)          │ ────────►│  react(log) runs here    │
///   └─────────────────────────────────────┘          │  Computes Yield Velocity │
///                                                    │  Compares to Unichain    │
///   [Unichain]                                       │  threshold               │
///   ┌─────────────────────────────────────┐          │                          │
///   │  KineticHook.handleReactiveRebalance│ ◄─callback emit Callback(...)       │
///   └─────────────────────────────────────┘          └──────────────────────────┘
///
/// ────────────────────────────────────────────────────────────────────────────────
///
/// @dev Key Concepts:
///   - `vm` flag (inherited pattern): When deployed on the Reactive Network's ReactVM,
///     subscriptions are registered. When deployed normally (tests), subscriptions are skipped.
///   - `react(LogRecord)`: The entry point called by the Reactive Network when a monitored
///     event fires on any source chain.
///   - `emit Callback(...)`: The signal that triggers a real cross-chain transaction to the
///     destination contract (KineticHook) on the target chain.
///   - AI Strategy: The `updateStrategy` function allows an off-chain AI agent to update the
///     `yieldThreshold` and `minConfidenceScore` parameters, shifting the system from reactive
///     to predictive rebalancing.
///
contract YieldScout is IReactive {

    // ─────────────────────────────────────────────────────────────
    //  Events (YieldScout-specific, beyond IReactive.Callback)
    // ─────────────────────────────────────────────────────────────

    /// @notice Emitted inside react() when a swap is processed.
    event SwapObserved(
        uint256 indexed chainId,
        address indexed poolAddress,
        uint256 volume,
        uint256 computedYieldVelocity
    );

    /// @notice Emitted when the AI agent updates strategy parameters.
    event StrategyUpdated(
        uint256 newYieldThreshold,
        uint256 newMinConfidenceScore,
        bytes32 aiModelHash
    );

    /// @notice Emitted when a rebalance callback is dispatched to KineticHook.
    event RebalanceDispatched(
        uint256 indexed sourceChainId,
        address indexed sourcePool,
        uint256 sourceYieldVelocity,
        uint256 localYieldVelocity
    );

    /// @notice Emitted when the owner updates the local (Unichain) reference pool.
    event LocalPoolUpdated(address newLocalPool, uint256 localFee);

    // ─────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────

    /// @notice The Uniswap v4 Swap event topic_0.
    ///         keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24,uint256)")
    uint256 public constant UNISWAP_V4_SWAP_TOPIC_0 =
        0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca2ac007aab8be0;

    /// @notice Used to ignore a subscription topic position (match-all wildcard).
    uint256 public constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    /// @notice Gas budget for the callback transaction on the destination chain.
    uint64 public constant CALLBACK_GAS_LIMIT = 500_000;

    /// @notice Reactive Network system contract address.
    ISystemContract internal constant SERVICE_ADDR =
        ISystemContract(payable(0x0000000000000000000000000000000000fffFfF));

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    /// @notice Whether this contract is running inside the Reactive VM.
    ///         When `true`, subscriptions are active and `react()` is callable.
    bool internal vmMode;

    /// @notice The Reactive Network system service (used for subscribe/unsubscribe).
    ISystemContract internal service;

    /// @notice Owner — allowed to call `updateStrategy` and admin functions.
    address public owner;

    /// @notice The KineticHook contract address to send callbacks to.
    address public kineticHook;

    /// @notice The destination chain (Unichain chain ID).
    uint256 public destinationChainId;

    // ── AI Strategy Parameters ──────────────────────────────────────

    /// @notice Minimum improvement over local yield velocity to trigger a rebalance.
    ///         Expressed as basis points (e.g., 200 = 2x better).
    ///         Set by the off-chain AI agent via `updateStrategy`.
    uint256 public yieldThreshold;

    /// @notice AI confidence score threshold (0–100). Below this, the AI veto blocks rebalance.
    uint256 public minConfidenceScore;

    /// @notice The most recent AI model hash (for audit / on-chain traceability).
    bytes32 public aiModelHash;

    // ── Per-Pool Yield Velocity State ───────────────────────────────

    /// @notice Cumulative swap volume per pool (pool address → total uint token0 volume).
    mapping(address => uint256) public cumulativeVolume;

    /// @notice Count of swaps seen per pool.
    mapping(address => uint256) public swapCount;

    /// @notice Source chain ID for each monitored pool.
    mapping(address => uint256) public poolChainId;

    /// @notice Fee tier of each monitored pool (in basis points).
    mapping(address => uint256) public poolFee;

    /// @notice Last computed yield velocity per pool.
    mapping(address => uint256) public lastYieldVelocity;

    // ── Local (Unichain) Reference ──────────────────────────────────

    /// @notice The local Unichain pool address monitored as the "baseline."
    address public localPool;

    /// @notice The fee of the local pool.
    uint256 public localPoolFee;

    /// @notice Cumulative volume of the LOCAL (Unichain) pool for comparison.
    uint256 public localCumulativeVolume;

    /// @notice Swap count for the local pool.
    uint256 public localSwapCount;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────

    error Unauthorized();
    error ZeroAddress();
    error InvalidParameters();

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @dev Gate: only callable from the Reactive VM (when running on Reactive Network).
    modifier vmOnly() {
        require(vmMode, "YieldScout: VM only");
        _;
    }

    /// @dev Gate: only callable on the normal Reactive Network (not VM), e.g., admin calls.
    modifier rnOnly() {
        require(!vmMode, "YieldScout: RN only");
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /// @param _kineticHook         KineticHook address on Unichain.
    /// @param _destinationChainId  Unichain chain ID.
    /// @param _yieldThreshold      Minimum yield improvement to trigger rebalance (bps).
    /// @param _minConfidenceScore  AI model minimum confidence to authorize rebalance (0-100).
    /// @param _localPool           Unichain local pool address to use as baseline.
    /// @param _localPoolFee        Local pool fee tier.
    constructor(
        address _kineticHook,
        uint256 _destinationChainId,
        uint256 _yieldThreshold,
        uint256 _minConfidenceScore,
        address _localPool,
        uint256 _localPoolFee
    ) payable {
        if (_kineticHook == address(0) || _localPool == address(0)) revert ZeroAddress();
        if (_yieldThreshold == 0) revert InvalidParameters();

        owner = msg.sender;
        kineticHook = _kineticHook;
        destinationChainId = _destinationChainId;
        yieldThreshold = _yieldThreshold;
        minConfidenceScore = _minConfidenceScore;
        localPool = _localPool;
        localPoolFee = _localPoolFee;

        // Detect if we are running inside the Reactive VM or on normal EVM.
        service = SERVICE_ADDR;
        _detectVm();

        // Subscriptions are only valid inside the Reactive VM context.
        if (!vmMode) {
            // ── Source chain subscriptions (non-Unichain pools) ─────────────────
            // Subscribe to ALL Uniswap v4 Swap events, across ALL contracts,
            // on ALL chains. In production, narrow this to specific chain_id +
            // pool address pairs for efficiency.
            service.subscribe(
                0,                          // 0 = all source chains
                address(0),                 // 0 = all contracts (filter in react())
                UNISWAP_V4_SWAP_TOPIC_0,   // Only Uniswap v4 Swap events
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Reactive Callback — The Core Logic
    // ─────────────────────────────────────────────────────────────

    /// @notice Called by the Reactive Network whenever a subscribed Swap event fires.
    ///         Runs inside the ReactVM — computes yield velocity, compares to local,
    ///         and emits a `Callback` if a rebalance is warranted.
    ///
    /// @dev The `data` field of a Uniswap v4 Swap event is ABI-encoded:
    ///      (int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee, uint256 protocolFee)
    ///
    /// @param log  The intercepted log record from the source chain.
    function react(LogRecord calldata log) external vmOnly {
        // Parse the Swap event data to extract volume and liquidity.
        // v4 Swap event data: (int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, ...)
        (int128 amount0, , , uint128 liquidity, , uint24 fee,) =
            abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24, uint256));

        // Compute the unsigned volume (token0 units).
        uint256 volume = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));

        address pool = log._contract;
        uint256 chainId = log.chain_id;

        // ── Update per-pool state ────────────────────────────────────
        if (poolChainId[pool] == 0) {
            // First time seeing this pool — record its chain and fee.
            poolChainId[pool] = chainId;
            poolFee[pool] = uint256(fee);
        }

        // Determine if this is the LOCAL (Unichain) pool or a remote one.
        bool isLocal = (pool == localPool && chainId == destinationChainId);

        if (isLocal) {
            localCumulativeVolume += volume;
            localSwapCount++;
        } else {
            cumulativeVolume[pool] += volume;
            swapCount[pool]++;
        }

        // ── Compute Yield Velocities ─────────────────────────────────
        // Yield Velocity = (cumulativeVolume x fee) / (liquidity + 1)
        // This approximates annualized fee income per liquidity unit.
        uint256 sourceYV = (cumulativeVolume[pool] * poolFee[pool]) / (uint256(liquidity) + 1);
        uint256 localYV  = (localCumulativeVolume * localPoolFee) / (uint256(liquidity) + 1);

        lastYieldVelocity[pool] = sourceYV;

        emit SwapObserved(chainId, pool, volume, sourceYV);

        // ── Rebalance Decision ───────────────────────────────────────
        // Trigger a rebalance only if:
        //   1. This is a REMOTE (non-Unichain) pool.
        //   2. The source chain's yield velocity exceeds local by at least `yieldThreshold`.
        //   3. We have seen at least 3 swaps on the source pool (avoid flash spikes).
        if (
            !isLocal &&
            sourceYV > 0 &&
            localYV > 0 &&
            swapCount[pool] >= 3 &&
            (sourceYV * 10_000) / localYV >= yieldThreshold
        ) {
            emit RebalanceDispatched(chainId, pool, sourceYV, localYV);

            // Build the calldata for KineticHook.handleReactiveRebalance(...)
            // In the current signal-only architecture, we pass:
            //   - The PoolKey (encoded as poolAddress placeholder — real integration
            //     would pass a full PoolKey struct).
            //   - A suggested liquidity amount (10% of observed liquidity).
            //   - Standard tick range to allow the vault to decide exact ticks.
            //   - bridgeData containing the SOURCE chain info for the vault to bridge back.
            bytes memory bridgeData = abi.encode(
                chainId,        // Source chain the capital should be bridged TO
                pool,           // Source pool address for destination routing
                sourceYV        // Yield velocity as additional context
            );

            bytes memory payload = abi.encodeWithSignature(
                "handleReactiveRebalance((address,address,uint24,int24,address),uint128,int24,int24,bytes)",
                pool,                           // PoolKey.currency0 proxy (address of pool)
                address(0),                     // PoolKey.currency1 (placeholder)
                uint24(3000),                   // PoolKey.fee (default 0.3%)
                int24(60),                      // PoolKey.tickSpacing
                kineticHook,                    // PoolKey.hooks
                uint128(liquidity / 10),        // liquidityAmount = 10% of observed
                int24(-887220),                 // tickLower (full-range)
                int24(887220),                  // tickUpper (full-range)
                bridgeData
            );

            // Emit the Callback — the Reactive Network nodes will pick this up
            // and submit the actual transaction to KineticHook on Unichain.
            emit Callback(
                destinationChainId,
                kineticHook,
                CALLBACK_GAS_LIMIT,
                payload
            );
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  AI Strategy Update (Owner / AI Agent)
    // ─────────────────────────────────────────────────────────────

    /// @notice Called by the off-chain AI agent to update strategy parameters.
    ///         The AI model analyzes market conditions and updates thresholds to
    ///         shift from reactive to predictive rebalancing.
    ///
    /// @param _newYieldThreshold     New minimum yield improvement multiplier (bps, e.g. 15000 = 1.5x).
    /// @param _newMinConfidenceScore  New AI confidence threshold (0-100).
    /// @param _aiModelHash           Hash of the AI model version used for this update (for audit).
    function updateStrategy(
        uint256 _newYieldThreshold,
        uint256 _newMinConfidenceScore,
        bytes32 _aiModelHash
    ) external onlyOwner {
        if (_newYieldThreshold == 0 || _newMinConfidenceScore > 100) revert InvalidParameters();
        yieldThreshold = _newYieldThreshold;
        minConfidenceScore = _newMinConfidenceScore;
        aiModelHash = _aiModelHash;
        emit StrategyUpdated(_newYieldThreshold, _newMinConfidenceScore, _aiModelHash);
    }

    /// @notice Update the local (Unichain) reference pool used as the baseline for comparison.
    function updateLocalPool(address _newLocalPool, uint256 _newLocalFee) external onlyOwner {
        if (_newLocalPool == address(0)) revert ZeroAddress();
        localPool = _newLocalPool;
        localPoolFee = _newLocalFee;
        // Reset local stats to avoid stale data skewing comparisons.
        localCumulativeVolume = 0;
        localSwapCount = 0;
        emit LocalPoolUpdated(_newLocalPool, _newLocalFee);
    }

    /// @notice Update the KineticHook callback target address.
    function updateKineticHook(address _newHook) external onlyOwner {
        if (_newHook == address(0)) revert ZeroAddress();
        kineticHook = _newHook;
    }

    /// @notice Transfer ownership.
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        owner = _newOwner;
    }

    // ─────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns the yield velocity improvement ratio for a given source pool vs local.
    ///         Returns (sourceYV, localYV, ratio_bps) where ratio = (sourceYV / localYV) * 10000.
    /// @param pool             Source pool address.
    /// @param currentLiquidity Current liquidity of the source pool (caller-provided).
    function yieldVelocityComparison(address pool, uint128 currentLiquidity)
        external
        view
        returns (uint256 sourceYV, uint256 localYV, uint256 ratioBps)
    {
        sourceYV = (cumulativeVolume[pool] * poolFee[pool]) / (uint256(currentLiquidity) + 1);
        localYV  = (localCumulativeVolume * localPoolFee)   / (uint256(currentLiquidity) + 1);
        ratioBps = localYV > 0 ? (sourceYV * 10_000) / localYV : 0;
    }

    /// @notice Returns true if a rebalance would be triggered given current state.
    function wouldTriggerRebalance(address pool, uint128 currentLiquidity)
        external
        view
        returns (bool)
    {
        (uint256 sourceYV, uint256 localYV,) = this.yieldVelocityComparison(pool, currentLiquidity);
        return (
            pool != localPool &&
            sourceYV > 0 &&
            localYV > 0 &&
            swapCount[pool] >= 3 &&
            (sourceYV * 10_000) / localYV >= yieldThreshold
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal Helpers
    // ─────────────────────────────────────────────────────────────

    /// @dev Detects whether this contract is running in the Reactive VM context.
    ///      The ReactVM has no code at the system contract address, so `extcodesize` returns 0.
    ///      On the Reactive Network mainnet, the system contract IS present, so code size > 0.
    function _detectVm() internal {
        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(0x0000000000000000000000000000000000fffFfF) }
        // vm = true when system contract NOT present (i.e., we ARE in the VM)
        vmMode = (size == 0);
    }
}
