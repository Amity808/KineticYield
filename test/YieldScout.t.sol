// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {YieldScout} from "../src/YieldScout.sol";
import {IReactive} from "@reactive-lib/interfaces/IReactive.sol";

/// @title YieldScoutTest
/// @notice Comprehensive Foundry test for the YieldScout Reactive Contract.
///
/// ── Test Architecture Note ────────────────────────────────────────────────────
/// YieldScout extends AbstractReactive. Its `react()` is gated by `vmOnly`,
/// which requires `vm == true`. In a Foundry test the system contract at
/// 0xfffFfF has no code, so `detectVm()` sets `vm = true`. This means
/// `react()` is callable in tests, while subscriptions in the constructor are
/// skipped (gated by `!vm`) — avoiding calls to the undeployed system contract.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Test Cases:
///   1.  testConstructorState              — Verify initial state is set correctly.
///   2.  testReactLocalSwapAccumulates     — react() updates localCumulativeVolume for local pool.
///   3.  testReactSourceSwapAccumulates    — react() updates cumulativeVolume for source pool.
///   4.  testNoTriggerBelowThreshold       — No Callback when source yield < threshold.
///   5.  testNoTriggerBelowMinSwapCount    — No Callback when source pool has < 3 swaps.
///   6.  testCallbackEmittedAboveThreshold — Callback emitted when source yield >> local.
///   7.  testSwapObservedEmitted           — SwapObserved event emitted on every react().
///   8.  testUpdateStrategy                — AI agent can update yield threshold + confidence.
///   9.  testUpdateStrategyOnlyOwner       — Random address cannot call updateStrategy.
///   10. testUpdateLocalPool              — Owner can update local pool reference.
///   11. testYieldVelocityComparison      — View function returns correct source/local ratio.
///   12. testWouldTriggerRebalance        — View predicts rebalance correctly.
///   13. testTransferOwnership            — Ownership transfer works correctly.
contract YieldScoutTest is Test {
    // ─────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────

    // Chain IDs
    uint256 constant UNICHAIN_CHAIN_ID = 130;
    uint256 constant ARBITRUM_CHAIN_ID = 42161;

    // Unichain pool serves as the LOCAL baseline
    address constant LOCAL_POOL  = address(0x1000000000000000000000000000000000000001);
    // Arbitrum pool serves as the HIGH-YIELD REMOTE source
    address constant REMOTE_POOL = address(0x2000000000000000000000000000000000000002);
    // Simulated KineticCallback address on Unichain
    address constant KINETIC_CALLBACK = address(0x3000000000000000000000000000000000000003);

    address constant OWNER        = address(0x4000000000000000000000000000000000000004);
    address constant RANDOM_ADDR  = address(0x5000000000000000000000000000000000000005);
    address constant NEW_OWNER    = address(0x6000000000000000000000000000000000000006);

    uint256 constant LOCAL_POOL_FEE  = 500;   // 0.05% Stable tier
    uint256 constant REMOTE_POOL_FEE = 3000;  // 0.30% Standard tier

    // 15000 bps = 1.5x improvement required to trigger rebalance
    uint256 constant YIELD_THRESHOLD = 15_000;

    uint256 public constant UNISWAP_V4_SWAP_TOPIC_0 =
        0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca2ac007aab8be0;

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    YieldScout scout;

    // ─────────────────────────────────────────────────────────────
    //  Helper: Build a LogRecord for a Uniswap v4 Swap event
    // ─────────────────────────────────────────────────────────────

    function _buildSwapLog(
        uint256 chainId,
        address pool,
        int128 amount0,
        uint128 liquidity,
        uint24 fee
    ) internal pure returns (IReactive.LogRecord memory log) {
        // Uniswap v4 Swap event data encoding:
        // (int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee, uint256 protocolFee)
        bytes memory data = abi.encode(
            amount0,
            int128(9_871_580_343_970_612),   // amount1 (arbitrary)
            uint160(79_228_162_514_264_337_593_543_950_336), // sqrtPriceX96 (1:1)
            liquidity,
            int24(0),                        // tick
            fee,
            uint256(0)                       // protocolFee
        );

        log = IReactive.LogRecord({
            chain_id:     chainId,
            _contract:    pool,
            topic_0:      UNISWAP_V4_SWAP_TOPIC_0,
            topic_1:      0,
            topic_2:      0,
            topic_3:      0,
            data:         data,
            block_number: 100,
            op_code:      0,
            block_hash:   0,
            tx_hash:      0,
            log_index:    0
        });
    }

    // ─────────────────────────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy from OWNER address so owner state is correctly set
        vm.prank(OWNER);
        scout = new YieldScout(
            KINETIC_CALLBACK,
            UNICHAIN_CHAIN_ID,
            YIELD_THRESHOLD,
            50,              // minConfidenceScore
            LOCAL_POOL,
            LOCAL_POOL_FEE
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  1. Constructor State
    // ─────────────────────────────────────────────────────────────

    function testConstructorState() public view {
        assertEq(scout.owner(), OWNER, "Owner should be set");
        assertEq(scout.kineticCallback(), KINETIC_CALLBACK, "KineticCallback should be set");
        assertEq(scout.destinationChainId(), UNICHAIN_CHAIN_ID, "Destination chain should be Unichain");
        assertEq(scout.yieldThreshold(), YIELD_THRESHOLD, "Yield threshold should match");
        assertEq(scout.minConfidenceScore(), 50, "Confidence score should be 50");
        assertEq(scout.localPool(), LOCAL_POOL, "Local pool should be set");
        assertEq(scout.localPoolFee(), LOCAL_POOL_FEE, "Local pool fee should match");
    }

    // ─────────────────────────────────────────────────────────────
    //  2. react() — Local pool accumulates localCumulativeVolume
    // ─────────────────────────────────────────────────────────────

    function testReactLocalSwapAccumulates() public {
        assertEq(scout.localCumulativeVolume(), 0);
        assertEq(scout.localSwapCount(), 0);

        int128 amount0 = -5e18;  // negative = tokens leaving pool
        IReactive.LogRecord memory log = _buildSwapLog(UNICHAIN_CHAIN_ID, LOCAL_POOL, amount0, 100e18, uint24(LOCAL_POOL_FEE));

        scout.react(log);

        assertEq(scout.localCumulativeVolume(), 5e18, "Local volume should accumulate");
        assertEq(scout.localSwapCount(), 1, "Local swap count should be 1");
        assertEq(scout.cumulativeVolume(LOCAL_POOL), 0, "Remote mapping should be 0 for local pool");

        console2.log("localCumulativeVolume:", scout.localCumulativeVolume());
    }

    // ─────────────────────────────────────────────────────────────
    //  3. react() — Remote pool accumulates cumulativeVolume
    // ─────────────────────────────────────────────────────────────

    function testReactSourceSwapAccumulates() public {
        IReactive.LogRecord memory log = _buildSwapLog(
            ARBITRUM_CHAIN_ID, REMOTE_POOL, int128(-2e18), uint128(50e18), uint24(REMOTE_POOL_FEE)
        );

        scout.react(log);

        assertEq(scout.cumulativeVolume(REMOTE_POOL), 2e18, "Remote volume should accumulate");
        assertEq(scout.swapCount(REMOTE_POOL), 1, "Remote swap count should be 1");
        assertEq(scout.poolChainId(REMOTE_POOL), ARBITRUM_CHAIN_ID, "Pool chainId should be Arbitrum");
        assertEq(scout.poolFee(REMOTE_POOL), REMOTE_POOL_FEE, "Pool fee should match");
    }

    // ─────────────────────────────────────────────────────────────
    //  4. No Callback when source yield < threshold
    // ─────────────────────────────────────────────────────────────

    function testNoTriggerBelowThreshold() public {
        // Seed local pool with high volume so local yield is high
        for (uint256 i = 0; i < 10; i++) {
            IReactive.LogRecord memory localLog = _buildSwapLog(
                UNICHAIN_CHAIN_ID, LOCAL_POOL, int128(-20e18), uint128(50e18), uint24(LOCAL_POOL_FEE)
            );
            scout.react(localLog);
        }

        // Remote pool has very low volume — yield ratio < threshold
        for (uint256 i = 0; i < 5; i++) {
            IReactive.LogRecord memory remoteLog = _buildSwapLog(
                ARBITRUM_CHAIN_ID, REMOTE_POOL, int128(-1e15), uint128(50e18), uint24(REMOTE_POOL_FEE)
            );
            // We expect NO Callback event — use vm.recordLogs() to verify
            scout.react(remoteLog);
        }

        // Verify no Callback was emitted (only SwapObserved events)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bool callbackFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                callbackFound = true;
                break;
            }
        }
        assertFalse(callbackFound, "No Callback should be emitted below yield threshold");
    }

    // ─────────────────────────────────────────────────────────────
    //  5. No Callback when source pool has < 3 swaps
    // ─────────────────────────────────────────────────────────────

    function testNoTriggerBelowMinSwapCount() public {
        // Local pool low volume
        IReactive.LogRecord memory localLog = _buildSwapLog(
            UNICHAIN_CHAIN_ID, LOCAL_POOL, int128(-1e15), uint128(100e18), uint24(LOCAL_POOL_FEE)
        );
        scout.react(localLog);

        // Remote pool: only 2 swaps (below minimum 3), but high yield
        vm.recordLogs();
        for (uint256 i = 0; i < 2; i++) {
            IReactive.LogRecord memory remoteLog = _buildSwapLog(
                ARBITRUM_CHAIN_ID, REMOTE_POOL, int128(-50e18), uint128(1e15), uint24(REMOTE_POOL_FEE)
            );
            scout.react(remoteLog);
        }

        // No Callback expected because swapCount[REMOTE_POOL] < 3
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bool callbackFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                callbackFound = true;
                break;
            }
        }
        assertFalse(callbackFound, "No Callback before 3 source swaps");
        assertLt(scout.swapCount(REMOTE_POOL), 3, "Swap count should be below minimum");
    }

    // ─────────────────────────────────────────────────────────────
    //  6. Callback emitted when source yield >> local yield
    // ─────────────────────────────────────────────────────────────

    function testCallbackEmittedAboveThreshold() public {
        uint128 lowLiquidity = 1e15;   // drive high yield velocity
        uint128 highLiquidity = 100e18;

        // Local pool: moderate volume, high liquidity → low yield velocity
        for (uint256 i = 0; i < 5; i++) {
            IReactive.LogRecord memory localLog = _buildSwapLog(
                UNICHAIN_CHAIN_ID, LOCAL_POOL, int128(-1e18), highLiquidity, uint24(LOCAL_POOL_FEE)
            );
            scout.react(localLog);
        }

        // Remote pool: large volume, very low liquidity → very high yield velocity
        // After 3 swaps the ratio will exceed YIELD_THRESHOLD (1.5x)
        vm.recordLogs();
        for (uint256 i = 0; i < 4; i++) {
            IReactive.LogRecord memory remoteLog = _buildSwapLog(
                ARBITRUM_CHAIN_ID, REMOTE_POOL, int128(-50e18), lowLiquidity, uint24(REMOTE_POOL_FEE)
            );
            scout.react(remoteLog);
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bool callbackFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                callbackFound = true;
                // Verify the callback targets the correct chain and contract
                uint256 targetChain = uint256(logs[i].topics[1]);
                address targetContract = address(uint160(uint256(logs[i].topics[2])));
                assertEq(targetChain, UNICHAIN_CHAIN_ID, "Callback must target Unichain");
                assertEq(targetContract, KINETIC_CALLBACK, "Callback must target KineticCallback");
                console2.log("Callback emitted to chainId:", targetChain);
                break;
            }
        }
        assertTrue(callbackFound, "Callback MUST be emitted when yield threshold exceeded");
    }

    // ─────────────────────────────────────────────────────────────
    //  7. SwapObserved emitted on every react() call
    // ─────────────────────────────────────────────────────────────

    function testSwapObservedEmitted() public {
        IReactive.LogRecord memory log = _buildSwapLog(
            ARBITRUM_CHAIN_ID, REMOTE_POOL, int128(-3e18), uint128(20e18), uint24(REMOTE_POOL_FEE)
        );

        vm.expectEmit(true, true, false, false, address(scout));
        emit YieldScout.SwapObserved(ARBITRUM_CHAIN_ID, REMOTE_POOL, 3e18, 0);

        scout.react(log);
    }

    // ─────────────────────────────────────────────────────────────
    //  8. AI Strategy Update
    // ─────────────────────────────────────────────────────────────

    function testUpdateStrategy() public {
        bytes32 modelHash = keccak256("ModelV2");
        uint256 newThreshold = 20_000; // 2.0x improvement required
        uint256 newConfidence = 75;

        vm.expectEmit(false, false, false, true, address(scout));
        emit YieldScout.StrategyUpdated(newThreshold, newConfidence, modelHash);

        vm.prank(OWNER);
        scout.updateStrategy(newThreshold, newConfidence, modelHash);

        assertEq(scout.yieldThreshold(), newThreshold, "Yield threshold should update");
        assertEq(scout.minConfidenceScore(), newConfidence, "Confidence score should update");
        assertEq(scout.aiModelHash(), modelHash, "AI model hash should update");

        console2.log("New yieldThreshold:", scout.yieldThreshold());
    }

    // ─────────────────────────────────────────────────────────────
    //  9. updateStrategy requires onlyOwner
    // ─────────────────────────────────────────────────────────────

    function testUpdateStrategyOnlyOwner() public {
        vm.prank(RANDOM_ADDR);
        vm.expectRevert(YieldScout.Unauthorized.selector);
        scout.updateStrategy(20_000, 80, keccak256("Attack"));
    }

    // ─────────────────────────────────────────────────────────────
    //  10. Owner can update local pool reference
    // ─────────────────────────────────────────────────────────────

    function testUpdateLocalPool() public {
        address newPool = address(0x7000000000000000000000000000000000000007);
        uint256 newFee = 100;

        // Seed some local data first
        IReactive.LogRecord memory log = _buildSwapLog(
            UNICHAIN_CHAIN_ID, LOCAL_POOL, int128(-5e18), uint128(100e18), uint24(LOCAL_POOL_FEE)
        );
        scout.react(log);
        assertGt(scout.localCumulativeVolume(), 0, "Local volume should be non-zero before reset");

        vm.expectEmit(false, false, false, true, address(scout));
        emit YieldScout.LocalPoolUpdated(newPool, newFee);

        vm.prank(OWNER);
        scout.updateLocalPool(newPool, newFee);

        assertEq(scout.localPool(), newPool, "Local pool should update");
        assertEq(scout.localPoolFee(), newFee, "Local fee should update");
        // Data should be reset
        assertEq(scout.localCumulativeVolume(), 0, "Local volume should reset after pool change");
        assertEq(scout.localSwapCount(), 0, "Local swap count should reset");
    }

    // ─────────────────────────────────────────────────────────────
    //  11. yieldVelocityComparison view function
    // ─────────────────────────────────────────────────────────────

    function testYieldVelocityComparison() public {
        uint128 liq = 100e18;

        // Seed local + remote volumes
        for (uint256 i = 0; i < 3; i++) {
            IReactive.LogRecord memory localLog = _buildSwapLog(
                UNICHAIN_CHAIN_ID, LOCAL_POOL, int128(-5e18), liq, uint24(LOCAL_POOL_FEE)
            );
            scout.react(localLog);

            IReactive.LogRecord memory remoteLog = _buildSwapLog(
                ARBITRUM_CHAIN_ID, REMOTE_POOL, int128(-15e18), liq, uint24(REMOTE_POOL_FEE)
            );
            scout.react(remoteLog);
        }

        (uint256 sourceYV, uint256 localYV, uint256 ratioBps) =
            scout.yieldVelocityComparison(REMOTE_POOL, liq);

        assertGt(sourceYV, 0, "Source YV should be > 0");
        assertGt(localYV, 0, "Local YV should be > 0");
        // Remote has 3x volume AND 6x higher fee than local: ratio should be high
        assertGt(ratioBps, 10_000, "Remote/Local ratio should be > 1.0x (10000 bps)");

        console2.log("sourceYV:", sourceYV);
        console2.log("localYV:", localYV);
        console2.log("ratioBps:", ratioBps);
    }

    // ─────────────────────────────────────────────────────────────
    //  12. wouldTriggerRebalance view
    // ─────────────────────────────────────────────────────────────

    function testWouldTriggerRebalance() public {
        uint128 lowLiq = 1e15;
        uint128 highLiq = 100e18;

        // Initially: no data — should be false
        assertFalse(scout.wouldTriggerRebalance(REMOTE_POOL, lowLiq), "No data -> no trigger");

        // Seed local with low yield
        for (uint256 i = 0; i < 3; i++) {
            scout.react(_buildSwapLog(UNICHAIN_CHAIN_ID, LOCAL_POOL, int128(-1e15), highLiq, uint24(LOCAL_POOL_FEE)));
        }

        // Seed remote with high yield (3 swaps minimum)
        for (uint256 i = 0; i < 3; i++) {
            scout.react(_buildSwapLog(ARBITRUM_CHAIN_ID, REMOTE_POOL, int128(-50e18), lowLiq, uint24(REMOTE_POOL_FEE)));
        }

        bool wouldTrigger = scout.wouldTriggerRebalance(REMOTE_POOL, lowLiq);
        assertTrue(wouldTrigger, "Should predict a trigger when source yield >> local");

        console2.log("wouldTriggerRebalance:", wouldTrigger);
    }

    // ─────────────────────────────────────────────────────────────
    //  13. Transfer ownership
    // ─────────────────────────────────────────────────────────────

    function testTransferOwnership() public {
        vm.prank(OWNER);
        scout.transferOwnership(NEW_OWNER);

        assertEq(scout.owner(), NEW_OWNER, "Owner should have changed");

        // Old owner should be unauthorized now
        vm.prank(OWNER);
        vm.expectRevert(YieldScout.Unauthorized.selector);
        scout.updateStrategy(20_000, 80, keccak256("Old"));

        // New owner should work
        vm.prank(NEW_OWNER);
        scout.updateStrategy(20_000, 80, keccak256("New")); // should not revert
    }
}
