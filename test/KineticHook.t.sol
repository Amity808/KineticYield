// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {KineticHook} from "../src/KineticHook.sol";

/// @title KineticHookTest
/// @notice Comprehensive Foundry test for the KineticYield autonomous LP rebalancer hook.
///
///   Test cases:
///     1. testYieldTracking           — swaps accumulate volume + swap count correctly.
///     2. testYieldVelocityView       — yieldVelocity() returns a non-zero value after swaps.
///     3. testReactiveRebalanceTrigger — REACTIVE_SENDER can trigger a rebalance and
///                                       liquidity is removed + BridgeInitiated emitted.
///     4. testUnauthorizedCannotRebalance — random address cannot call handleReactiveRebalance.
///     5. testEmergencyPausePreventsRebalance — owner pause blocks reactive triggers.
///     6. testEmergencyPauseToggle    — owner can pause AND unpause.
///     7. testSetReactiveSenderOnlyOwner — only owner can change sender address.
///     8. testTransferOwnership       — ownership can be transferred.
contract KineticHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    KineticHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    uint128 constant INITIAL_LIQUIDITY = 100e18;

    // The simulated Reactive Network callback address
    address constant REACTIVE_SENDER = address(0x0000000000000000000000000000000000000001);
    address constant RANDOM_ATTACKER = address(0x0000000000000000000000000000000000000002);

    // ─────────────────────────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy Uniswap v4 core contracts (PoolManager, PositionManager, routers)
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        // ── Deploy KineticHook at a deterministic address that encodes its permissions ──
        // Permissions: beforeSwap + afterSwap
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x7777 << 144) // Namespace to avoid collisions
        );

        bytes memory constructorArgs = abi.encode(poolManager, REACTIVE_SENDER);
        deployCodeTo("KineticHook.sol:KineticHook", constructorArgs, flags);
        hook = KineticHook(flags);

        // ── Initialize pool ──────────────────────────────────────────────
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // ── Provide initial full-range liquidity ─────────────────────────
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            INITIAL_LIQUIDITY
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            INITIAL_LIQUIDITY,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Simulation 1 — Yield Tracking
    // ─────────────────────────────────────────────────────────────

    /// @notice After N swaps, cumulativeVolume and swapCount should be non-zero.
    function testYieldTracking() public {
        assertEq(hook.swapCount(poolId), 0, "Initial swapCount should be 0");
        assertEq(hook.cumulativeVolume(poolId), 0, "Initial volume should be 0");

        uint256 amountIn = 1e18;

        // Perform 3 swaps
        for (uint256 i = 0; i < 3; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: amountIn,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        assertEq(hook.swapCount(poolId), 3, "swapCount should be 3 after 3 swaps");
        assertGt(hook.cumulativeVolume(poolId), 0, "cumulativeVolume should be > 0 after swaps");

        console2.log("swapCount:        ", hook.swapCount(poolId));
        console2.log("cumulativeVolume: ", hook.cumulativeVolume(poolId));
    }

    /// @notice yieldVelocity() should return a non-zero value once swaps have occurred.
    function testYieldVelocityView() public {
        // Do a swap to generate volume
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 velocity = hook.yieldVelocity(poolKey);
        assertGt(velocity, 0, "yieldVelocity should be > 0 after a swap");

        console2.log("yieldVelocity: ", velocity);
    }

    // ─────────────────────────────────────────────────────────────
    //  Simulation 2 — Reactive Trigger
    // ─────────────────────────────────────────────────────────────

    /// @notice REACTIVE_SENDER can trigger a rebalance; both events must be emitted.
    /// @dev In the signal-only architecture, the hook does NOT directly modify liquidity.
    ///      It emits RebalanceTriggered + BridgeInitiated so a companion vault contract
    ///      (off-hook) listens and executes the actual withdrawal + bridge transfer.
    function testReactiveRebalanceTrigger() public {
        // Do a swap first to accumulate yield data
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.swapCount(poolId), 1, "Should have 1 swap tracked");

        bytes memory bridgeData = abi.encode(uint32(42161), address(this), uint256(1e18));
        uint128 rebalanceLiquidity = 1e15;

        // 1. RebalanceTriggered must be emitted
        vm.expectEmit(true, false, false, true, address(hook));
        emit KineticHook.RebalanceTriggered(poolId, rebalanceLiquidity, bridgeData);

        // 2. BridgeInitiated must follow
        vm.expectEmit(false, false, false, true, address(hook));
        emit KineticHook.BridgeInitiated(bridgeData);

        // Prank as the authorized Reactive Network sender
        vm.prank(REACTIVE_SENDER);
        hook.handleReactiveRebalance(poolKey, rebalanceLiquidity, tickLower, tickUpper, bridgeData);

        // In signal-mode, pool liquidity is unchanged (vault executes the actual withdrawal off-hook)
        uint128 liqAfter = poolManager.getLiquidity(poolId);
        assertGt(liqAfter, 0, "Pool should still hold liquidity (vault not called in test)");

        console2.log("swapCount after trigger: ", hook.swapCount(poolId));
        console2.log("Pool liquidity (unchanged): ", liqAfter);
    }

    // ─────────────────────────────────────────────────────────────
    //  Security Tests
    // ─────────────────────────────────────────────────────────────

    /// @notice A random address must NOT be able to call handleReactiveRebalance.
    function testUnauthorizedCannotRebalance() public {
        bytes memory bridgeData = abi.encode(uint32(42161), address(this), uint256(1e18));
        uint128 liq = poolManager.getLiquidity(poolId);

        vm.prank(RANDOM_ATTACKER);
        vm.expectRevert(KineticHook.Unauthorized.selector);
        hook.handleReactiveRebalance(poolKey, liq / 10, tickLower, tickUpper, bridgeData);
    }

    /// @notice When the hook is paused, REACTIVE_SENDER cannot trigger a rebalance.
    function testEmergencyPausePreventsRebalance() public {
        // Owner pauses the hook
        // Note: owner is the test contract (msg.sender during setUp)
        vm.expectEmit(false, false, false, true, address(hook));
        emit KineticHook.EmergencyPauseToggled(true);
        hook.setEmergencyPause(true);

        assertTrue(hook.paused(), "Hook should be paused");

        bytes memory bridgeData = abi.encode(uint32(42161), address(this), uint256(1e18));
        uint128 liq = poolManager.getLiquidity(poolId);

        vm.prank(REACTIVE_SENDER);
        vm.expectRevert(KineticHook.ReactivePaused.selector);
        hook.handleReactiveRebalance(poolKey, liq / 10, tickLower, tickUpper, bridgeData);
    }

    /// @notice After pausing, the owner can unpause and REACTIVE_SENDER can trigger again.
    function testEmergencyPauseToggle() public {
        hook.setEmergencyPause(true);
        assertTrue(hook.paused(), "Should be paused");

        hook.setEmergencyPause(false);
        assertFalse(hook.paused(), "Should be unpaused");

        // Reactive sender should now work.
        // Use a small fixed amount that safely fits inside int128 for the modifyLiquidity call.
        bytes memory bridgeData = abi.encode(uint32(42161), address(this), uint256(1e18));
        uint128 smallLiquidity = 1e15; // well within both uint128 and int128 range

        vm.prank(REACTIVE_SENDER);
        // Should not revert
        hook.handleReactiveRebalance(poolKey, smallLiquidity, tickLower, tickUpper, bridgeData);
    }

    /// @notice Only the owner can update the Reactive sender. A random address must revert.
    function testSetReactiveSenderOnlyOwner() public {
        address newSender = address(0x0000000000000000000000000000000000000003);

        // Random attacker cannot update
        vm.prank(RANDOM_ATTACKER);
        vm.expectRevert(KineticHook.Unauthorized.selector);
        hook.setReactiveSender(newSender);

        // Owner can update
        vm.expectEmit(true, true, false, false, address(hook));
        emit KineticHook.ReactiveSenderUpdated(REACTIVE_SENDER, newSender);
        hook.setReactiveSender(newSender);

        assertEq(hook.reactiveSender(), newSender, "Reactive sender should be updated");
    }

    /// @notice Ownership can be transferred; old owner loses privileges.
    function testTransferOwnership() public {
        address newOwner = address(0x0000000000000000000000000000000000000004);
        hook.transferOwnership(newOwner);

        assertEq(hook.owner(), newOwner, "Owner should have changed");

        // Old owner should now be unauthorized
        vm.expectRevert(KineticHook.Unauthorized.selector);
        hook.setEmergencyPause(true);
    }
}
