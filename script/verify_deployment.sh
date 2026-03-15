#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# KineticYield — Verify Deployment Script
# ═══════════════════════════════════════════════════════════════════════════════
#
# Run this script to independently confirm both contracts are deployed and
# working correctly on Sepolia and Reactive Lasna.
#
# Usage:
#   cd /Users/amityclev/Documents/dev/uniswap/UI9/kineticYield
#   chmod +x script/verify_deployment.sh
#   ./script/verify_deployment.sh
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail
source .env

# ──────────────────────────────────────────────────────────────────────────────
#  Deployed Addresses (from deployment on 2026-03-14)
# ──────────────────────────────────────────────────────────────────────────────
CALLBACK_ADDR="0x0898E1099B5063BAA5E694F5b8C6c5DA5Cc49C36"
SCOUT_ADDR="0x6f3cf8b8E37d510a58956CEEc3Da0d62217b5DbE"
DEPLOYER="0x8822F2965090Ddc102F7de354dfd6E642C090269"

PASS=0
FAIL=0

check() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    
    # Normalize: lowercase and strip leading zeros for comparison
    local norm_expected=$(echo "$expected" | tr '[:upper:]' '[:lower:]')
    local norm_actual=$(echo "$actual" | tr '[:upper:]' '[:lower:]')
    
    if echo "$norm_actual" | grep -qi "$norm_expected"; then
        echo "  ✅ $label"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $label"
        echo "     Expected: $expected"
        echo "     Got:      $actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════════════════════════════════════"
echo " KineticYield — Deployment Verification"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo " KineticCallback: $CALLBACK_ADDR"
echo " YieldScout:      $SCOUT_ADDR"
echo " Deployer:        $DEPLOYER"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
echo "── 1. Verify KineticCallback on Sepolia ─────────────────────────────────"
# ──────────────────────────────────────────────────────────────────────────────

echo "  Checking contract exists (bytecode)..."
CODE=$(cast code $CALLBACK_ADDR --rpc-url $SEPOLIA_RPC)
if [ "$CODE" != "0x" ] && [ -n "$CODE" ]; then
    echo "  ✅ Contract has bytecode (deployed)"
    PASS=$((PASS + 1))
else
    echo "  ❌ No bytecode found — contract not deployed!"
    FAIL=$((FAIL + 1))
fi

echo "  Checking rebalanceCount()..."
RESULT=$(cast call $CALLBACK_ADDR "rebalanceCount()" --rpc-url $SEPOLIA_RPC)
check "rebalanceCount() = 0" "0x0000000000000000000000000000000000000000000000000000000000000000" "$RESULT"

echo "  Checking lastSourceChainId()..."
RESULT=$(cast call $CALLBACK_ADDR "lastSourceChainId()" --rpc-url $SEPOLIA_RPC)
check "lastSourceChainId() = 0" "0x0000000000000000000000000000000000000000000000000000000000000000" "$RESULT"

echo ""

# ──────────────────────────────────────────────────────────────────────────────
echo "── 2. Verify YieldScout on Reactive Lasna ───────────────────────────────"
# ──────────────────────────────────────────────────────────────────────────────

echo "  Checking contract exists (bytecode)..."
CODE=$(cast code $SCOUT_ADDR --rpc-url $REACTIVE_RPC)
if [ "$CODE" != "0x" ] && [ -n "$CODE" ]; then
    echo "  ✅ Contract has bytecode (deployed)"
    PASS=$((PASS + 1))
else
    echo "  ❌ No bytecode found — contract not deployed!"
    FAIL=$((FAIL + 1))
fi

echo "  Checking kineticCallback()..."
RESULT=$(cast call $SCOUT_ADDR "kineticCallback()" --rpc-url $REACTIVE_RPC)
check "kineticCallback() = $CALLBACK_ADDR" "0898e1099b5063baa5e694f5b8c6c5da5cc49c36" "$RESULT"

echo "  Checking destinationChainId()..."
RESULT=$(cast call $SCOUT_ADDR "destinationChainId()" --rpc-url $REACTIVE_RPC)
check "destinationChainId() = 11155111 (0xaa36a7)" "aa36a7" "$RESULT"

echo "  Checking yieldThreshold()..."
RESULT=$(cast call $SCOUT_ADDR "yieldThreshold()" --rpc-url $REACTIVE_RPC)
check "yieldThreshold() = 15000 (0x3a98)" "3a98" "$RESULT"

echo "  Checking minConfidenceScore()..."
RESULT=$(cast call $SCOUT_ADDR "minConfidenceScore()" --rpc-url $REACTIVE_RPC)
check "minConfidenceScore() = 80 (0x50)" "50" "$RESULT"

echo "  Checking owner()..."
RESULT=$(cast call $SCOUT_ADDR "owner()" --rpc-url $REACTIVE_RPC)
check "owner() = deployer" "8822f2965090ddc102f7de354dfd6e642c090269" "$RESULT"

echo ""

# ──────────────────────────────────────────────────────────────────────────────
echo "── 3. Verify Reactive Network Subscriptions ─────────────────────────────"
# ──────────────────────────────────────────────────────────────────────────────

echo "  Querying rnk_getSubscribers..."
SUBS=$(curl -s 'https://lasna-rpc.rnk.dev/' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"rnk_getSubscribers","params":["'"$DEPLOYER"'"],"id":1}')

# Check if our contract appears in the subscriptions
if echo "$SUBS" | grep -qi "6f3cf8b8e37d510a58956ceec3da0d62217b5dbe"; then
    echo "  ✅ YieldScout found in active subscriptions"
    PASS=$((PASS + 1))
else
    echo "  ❌ YieldScout NOT found in subscriptions"
    FAIL=$((FAIL + 1))
fi

# Check the Swap topic
if echo "$SUBS" | grep -qi "40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca2ac007aab8be0"; then
    echo "  ✅ Subscribed to Uniswap v4 Swap topic (0x40e9ce...)"
    PASS=$((PASS + 1))
else
    echo "  ❌ Swap topic subscription NOT found"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "  Full subscription response:"
echo "$SUBS" | python3 -m json.tool 2>/dev/null || echo "$SUBS"

echo ""

# ──────────────────────────────────────────────────────────────────────────────
echo "── 4. Verify Etherscan / Reactscan Links ────────────────────────────────"
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "  Open these in your browser to visually confirm:"
echo ""
echo "  KineticCallback (Sepolia Etherscan):"
echo "    https://sepolia.etherscan.io/address/$CALLBACK_ADDR"
echo ""
echo "  Deploy tx (Sepolia):"
echo "    https://sepolia.etherscan.io/tx/0x191170de17c6b0874594db5cfd7e1ecdbf360f0e42f81d65cd4211865c90f4cc"
echo ""
echo "  YieldScout (Reactscan):"
echo "    https://lasna.reactscan.net/address/$SCOUT_ADDR"
echo ""
echo "  Deploy tx (Lasna):"
echo "    https://lasna.reactscan.net/tx/0x994752c2e94cf67c150ab26be03df82971eff85bce2d40557386ff93e417a9a9"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════════"
echo " RESULTS: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════════════════"

if [ $FAIL -eq 0 ]; then
    echo " 🎉 ALL CHECKS PASSED — Deployment verified successfully!"
else
    echo " ⚠️  Some checks failed. Review the output above."
fi
echo ""
