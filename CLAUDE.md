# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Gnosis Safe Module that autonomously skims yield from a Mamo USDC strategy and distributes it to configured recipients, auto-compounding any remainder back into a protected principal floor. The invariant `(strategyValue + safeIdleUSDC) >= protectedPrincipal` must never be violated.

## Commands

```sh
forge build

# Unit tests (no network required)
forge test --match-path "test/PawthereumMamoYieldModule.t.sol" -vv

# Fork tests (requires BASE_RPC_URL in .env)
set -a && source .env && set +a
forge test --match-path "test/PawthereumMamoYieldModule.fork.t.sol" -vv

# Run a single test by name
forge test --match-test testFunctionName -vvv

# Deploy
set -a && source .env && set +a
forge script script/DeployPawthereumMamoYieldModule.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

Solidity: `0.8.28`, optimizer on (200 runs), `via_ir`, evm `cancun`, target chain: Base (8453).

## Architecture

Single contract: `src/PawthereumMamoYieldModule.sol`

**Core flow (`executeYieldCapture`):**
1. `getStrategyValue()` — sums morpho vault assets + mToken underlying + idle USDC held by the Mamo strategy (mirrors Mamo's internal `_getTotalBalance`)
2. Computes `totalYield = strategyValue - protectedPrincipal`; Safe-held USDC backs the invariant but is not claimable yield
3. Withdraws `totalDistributed` from Mamo strategy via Safe module call, then transfers each recipient's share
4. Bumps `protectedPrincipal += compoundedAmount` (the auto-ratchet)
5. Verifies the invariant, reverts on violation

**Access control:** All admin functions (`setRecipients`, `setProtectedPrincipal`, `pause`, etc.) use `onlySafe` — only the Gnosis Safe itself can call them. `executeYieldCapture` is permissionless.

**`_safeExec`:** Every on-chain action (withdraw from Mamo, transfer USDC) goes through `Safe.execTransactionFromModuleReturnData`. The module never holds funds or approves tokens.

**`previewYieldCapture`:** Dry-run; cannot be `view` because `mToken.balanceOfUnderlying` accrues interest as a side effect. Call as `cast call` (simulation), never as a transaction.

**Recipients:** `Recipient[] { addr, bps }`, max 16, sum of bps ≤ 10,000. The remainder (10,000 − sum) is the compound share. Empty list = 100% compound.

## Key addresses (Base mainnet)

| | |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Moonwell mUSDC | `0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22` |
| Moonwell Flagship USDC vault | `0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca` |
| Mamo USDC strategy factory | `0x5967ea71cC65d610dc6999d7dF62bfa512e62D07` |

Requires Safe ≥ v1.3.0; canonical v1.4.1 singleton on Base: `0x41675C099F32341bf84BFc5382aF534df5C7461a`.
