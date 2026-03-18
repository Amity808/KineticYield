# KineticYield Deployment Output — 2026-03-18

## Deployer
- **Address:** `0x8822F2965090Ddc102F7de354dfd6E642C090269`
- **Private Key:** (in .env)

---

## Step 1: Faucet Request (lREACT on Lasna)

**Command:**
```
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
  --rpc-url https://sepolia.infura.io/v3/709bdd438a58422b891043c58e636a64 \
  --private-key $PRIVATE_KEY \
  "request(address)" \
  0x8822F2965090Ddc102F7de354dfd6E642C090269 \
  --value 0.1ether
```

**Output:**
```
blockHash            0x10e4d9c84d8f5f75a389250e28b0783ceaf9351d879d2c769cbf7c1ec16f8484
blockNumber          10446538
status               1 (success)
transactionHash      0x348ca0501f318bd34210f58670de055c41e0d8cb263548d0f88af608f177b7bc
from                 0x8822F2965090Ddc102F7de354dfd6E642C090269
to                   0x9b9BB25f1A81078C544C829c5EB7822d747Cf434
gasUsed              25428
```

✅ **Faucet request successful** — 0.1 SepETH sent, ~10 lREACT received on Lasna.

---

## Step 2: Deploy KineticCallback to Sepolia

**Command:**
```
forge create --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast \
  src/KineticCallback.sol:KineticCallback \
  --constructor-args 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA \
  --value 0.01ether
```

**Output:**
```
No files changed, compilation skipped
Deployer: 0x8822F2965090Ddc102F7de354dfd6E642C090269
Deployed to: 0x0898E1099B5063BAA5E694F5b8C6c5DA5Cc49C36
Transaction hash: 0x191170de17c6b0874594db5cfd7e1ecdbf360f0e42f81d65cd4211865c90f4cc
```

✅ **KineticCallback deployed** to Sepolia at `0x0898E1099B5063BAA5E694F5b8C6c5DA5Cc49C36`

**Etherscan:** https://sepolia.etherscan.io/tx/0x191170de17c6b0874594db5cfd7e1ecdbf360f0e42f81d65cd4211865c90f4cc

---

## Step 3: Deploy YieldScout to Reactive Lasna

**Command:**
```
forge create --rpc-url $REACTIVE_RPC --private-key $PRIVATE_KEY --broadcast \
  src/YieldScout.sol:YieldScout \
  --value 0.1ether \
  --constructor-args 0x0898E1099B5063BAA5E694F5b8C6c5DA5Cc49C36 11155111 15000 80 0x0898E1099B5063BAA5E694F5b8C6c5DA5Cc49C36 3000
```

**Output:**
```
No files changed, compilation skipped
Deployer: 0x8822F2965090Ddc102F7de354dfd6E642C090269
Deployed to: 0x6f3cf8b8E37d510a58956CEEc3Da0d62217b5DbE
Transaction hash: 0x994752c2e94cf67c150ab26be03df82971eff85bce2d40557386ff93e417a9a9
```

✅ **YieldScout deployed** to Reactive Lasna at `0x6f3cf8b8E37d510a58956CEEc3Da0d62217b5DbE`

**Reactscan:** https://lasna.reactscan.net/address/0x6f3cf8b8E37d510a58956CEEc3Da0d62217b5DbE

---

## Step 4: On-Chain Verification

**KineticCallback on Sepolia:**
```
rebalanceCount:  0x0000000000000000000000000000000000000000000000000000000000000000  → 0
lastSourcePool:  0x0000000000000000000000000000000000000000000000000000000000000000  → address(0)
```

**YieldScout on Reactive Lasna:**
```
kineticCallback:    0x0000000000000000000000000898e1099b5063baa5e694f5b8c6c5da5cc49c36  → ✅ matches
destinationChainId: 0x0000000000000000000000000000000000000000000000000000000000aa36a7  → 11155111 (Sepolia) ✅
yieldThreshold:     0x0000000000000000000000000000000000000000000000000000000000003a98  → 15000 ✅
owner:              0x0000000000000000000000008822f2965090ddc102f7de354dfd6e642c090269  → deployer ✅
```

**Active Subscription (rnk_getSubscribers):**
```json
{
  "uid": "84c37b1ff9e2b0e1f10b850974197559",
  "chainId": 0,
  "contract": null,
  "topics": [
    "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca2ac007aab8be0",
    null, null, null
  ],
  "rvmId": "0x8822f2965090ddc102f7de354dfd6e642c090269",
  "rvmContract": "0x6f3cf8b8e37d510a58956ceec3da0d62217b5dbe"
}
```

✅ **Subscription active** — monitoring Uniswap v4 Swap events on all chains.

---

## Step 5: Deploy KineticHook to Unichain Sepolia

**Command:**
```
source .env && forge script script/00_DeployHook.s.sol \
  --rpc-url $UNICHAIN_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast
```

**Output:**
```
No files changed, compilation skipped
Chain 1301

Estimated gas price: 0.001000001 gwei
Estimated total gas used for script: 3713661
Estimated amount required: 0.000003713664713661 ETH

✅  [Success] Hash: 0x3b1771cf823c7c6e0789842e209364591a52d87ac86c585f2ccb829e31abd662
Block: 47001560
Paid: 0.000001344314688624 ETH (2688624 gas * 0.000500001 gwei)
```

✅ **KineticHook deployed** to Unichain Sepolia at `0x8e1dd87d53f35233d2c5bb13335ed05c38e840c0`

- **Chain:** Unichain Sepolia (1301)
- **Pool Manager:** `0x00b036b58a818b1bc34d502d3fe730db729e62ac`
- **Reactive Sender (Callback Proxy):** `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`
- **Explorer:** https://sepolia.uniscan.xyz/address/0x8e1dd87d53f35233d2c5bb13335ed05c38e840c0
