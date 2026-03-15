#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# KineticYield Deployment Script — Sepolia + Reactive Lasna Testnet
# ═══════════════════════════════════════════════════════════════════════════════
#
# Prerequisites:
#   1. Fund your deployer wallet with SepETH on Sepolia (https://sepoliafaucet.com/)
#   2. Get lREACT by running Step 1 below (send SepETH to the faucet on Sepolia)
#   3. Configure .env with PRIVATE_KEY, SEPOLIA_RPC, REACTIVE_RPC, etc.
#
# Usage:
#   cd /Users/amityclev/Documents/dev/uniswap/UI9/kineticYield
#   chmod +x script/deploy_sepolia.sh
#   ./script/deploy_sepolia.sh
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Load environment variables
source .env

echo "═══════════════════════════════════════════════════════════════════════════"
echo " KineticYield — Deployment to Sepolia + Reactive Lasna"
echo "═══════════════════════════════════════════════════════════════════════════"

# Derive deployer address from private key
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)
echo "Deployer address: $DEPLOYER"
echo ""

# ─── Step 1: Request lREACT from the faucet (run this once) ──────────────────
echo "Step 1: Requesting lREACT from faucet on Sepolia..."
echo "  Sending 0.1 SepETH to faucet at $REACT_FAUCET..."
echo "  You will receive ~10 lREACT on Reactive Lasna."
echo ""
echo "  Running: cast send $REACT_FAUCET --rpc-url \$SEPOLIA_RPC --private-key \$PRIVATE_KEY \"request(address)\" $DEPLOYER --value 0.1ether"
echo ""
read -p "  Press [Enter] to run, or [Ctrl+C] to skip if already funded..."
cast send $REACT_FAUCET \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  "request(address)" \
  $DEPLOYER \
  --value 0.1ether
echo "  ✓ Faucet request sent! lREACT should arrive on Lasna shortly."
echo ""

# ─── Step 2: Deploy KineticCallback to Sepolia ──────────────────────────────
echo "Step 2: Deploying KineticCallback to Sepolia..."
echo "  Constructor arg: callback_sender = $SEPOLIA_CALLBACK_PROXY"
echo ""

CALLBACK_DEPLOY=$(forge create \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  src/KineticCallback.sol:KineticCallback \
  --constructor-args $SEPOLIA_CALLBACK_PROXY \
  --value 0.01ether \
  2>&1)

echo "$CALLBACK_DEPLOY"

# Extract the deployed address
CALLBACK_ADDR=$(echo "$CALLBACK_DEPLOY" | grep "Deployed to:" | awk '{print $3}')
echo ""
echo "  ✓ KineticCallback deployed to: $CALLBACK_ADDR"
echo "  → Verify on Sepolia Etherscan: https://sepolia.etherscan.io/address/$CALLBACK_ADDR"
echo ""

# ─── Step 3: Deploy YieldScout to Reactive Lasna ────────────────────────────
echo "Step 3: Deploying YieldScout to Reactive Lasna..."
echo "  Constructor args:"
echo "    kineticCallback:    $CALLBACK_ADDR"
echo "    destinationChainId: $SEPOLIA_CHAIN_ID"
echo "    yieldThreshold:     15000 (1.5x)"
echo "    minConfidence:      80"
echo "    localPool:          $CALLBACK_ADDR (placeholder — update later)"
echo "    localPoolFee:       3000"
echo ""

SCOUT_DEPLOY=$(forge create \
  --rpc-url $REACTIVE_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  src/YieldScout.sol:YieldScout \
  --value 0.1ether \
  --constructor-args $CALLBACK_ADDR $SEPOLIA_CHAIN_ID 15000 80 $CALLBACK_ADDR 3000 \
  2>&1)

echo "$SCOUT_DEPLOY"

# Extract the deployed address
SCOUT_ADDR=$(echo "$SCOUT_DEPLOY" | grep "Deployed to:" | awk '{print $3}')
echo ""
echo "  ✓ YieldScout deployed to: $SCOUT_ADDR"
echo "  → Verify on Reactscan: https://lasna.reactscan.net/address/$SCOUT_ADDR"
echo ""

# ─── Summary ────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════════"
echo " DEPLOYMENT COMPLETE"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo " KineticCallback (Sepolia):        $CALLBACK_ADDR"
echo " YieldScout (Reactive Lasna):      $SCOUT_ADDR"
echo " Deployer (ReactVM ID):            $DEPLOYER"
echo ""
echo " Next Steps:"
echo "   1. Verify subscriptions: rnk_getSubscribers via RPC"
echo "   2. Trigger a Swap event on Sepolia and watch for the callback"
echo "   3. Check RebalanceTriggered events on Sepolia Etherscan"
echo ""
echo " Quick check — Get subscriptions (if YieldScout registered):"
echo "   curl -s 'https://lasna-rpc.rnk.dev/' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"jsonrpc\":\"2.0\",\"method\":\"rnk_getSubscribers\",\"params\":[\"$DEPLOYER\"],\"id\":1}' | jq"
echo "═══════════════════════════════════════════════════════════════════════════"
