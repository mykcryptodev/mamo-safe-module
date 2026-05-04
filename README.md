# Pawthereum Mamo Yield Capture Safe Module

A Gnosis Safe Module that autonomously skims yield from a Mamo USDC strategy owned by the Pawthereum Safe and splits it 50/50 between a donation wallet and a dev wallet — without ever touching principal.

## Invariant

```
(strategyValueAfter + safeIdleUSDC) >= protectedPrincipal
```

If this invariant is ever violated the execution reverts. Principal is sacrosanct.

## How it works

Once per `executionInterval`, anyone can poke `executeYieldCapture()`:

1. Compute `totalYield = (strategy value + safe idle USDC) - protectedPrincipal`
2. Withdraw `claimedYield = totalYield * 90%` from the Mamo strategy via the Safe
3. Transfer 50% to `donationRecipient`, 50% to `devRecipient`
4. Verify the principal invariant
5. Auto-ratchet: bump `protectedPrincipal` by the unclaimed 10% so the buffer compounds

The 10% buffer protects against rounding/share-conversion drift; the auto-ratchet means the floor grows monotonically with the strategy.

## Previewing yield

Before executing, you can dry-run `previewYieldCapture()` to see expected amounts and whether execution would succeed. Because `balanceOfUnderlying` on the Moonwell mToken accrues interest as a side-effect, this function cannot be marked `view` — but it should still be called as a simulation (no gas, no state change), not as a transaction.

```sh
cast call <MODULE_ADDRESS> \
  "previewYieldCapture()(uint256,uint256,uint256,uint256,uint256,uint256,bool)" \
  --rpc-url $BASE_RPC_URL
```

The seven return values in order:

| # | Name | Description |
|---|---|---|
| 1 | `strategyValue` | Total USDC value held in the Mamo strategy (raw 6-decimal units) |
| 2 | `safeIdle` | USDC sitting idle in the Safe itself |
| 3 | `totalYield` | `(strategyValue + safeIdle) - protectedPrincipal` |
| 4 | `claimedYield` | 90% of `totalYield` — the amount that would be withdrawn |
| 5 | `donationAmount` | 50% of `claimedYield` — sent to `donationRecipient` |
| 6 | `devAmount` | 50% of `claimedYield` — sent to `devRecipient` |
| 7 | `canExecute` | `true` if not paused, interval has elapsed, and `claimedYield >= minimumClaimAmount` |

Divide any USDC amount by `1e6` for a human-readable value. If `canExecute` is `false`, check whether the module is paused, the interval hasn't elapsed yet, or yield is below the minimum threshold.

**Do not send `previewYieldCapture` as a transaction** — return values are discarded by the EVM when called that way, and you will spend gas for nothing.

## Strategy value calculation

Mirrors Mamo's internal `_getTotalBalance()` exactly:

```solidity
morphoVault.convertToAssets(morphoVault.balanceOf(strategy))
+ mToken.balanceOfUnderlying(strategy)
+ USDC.balanceOf(strategy)
```

Verified against `moonwell-fi/mamo-contracts` source — see `src/PawthereumMamoYieldModule.sol::getStrategyValue`.

## Safe version requirement

The module relies on `Safe.execTransactionFromModuleReturnData(...)`, which has been part of the Safe interface since v1.3.0 (March 2021). **Deployments must use a Safe ≥ 1.3.0.** The current canonical Safe v1.4.1 singleton on Base is `0x41675C099F32341bf84BFc5382aF534df5C7461a`. End-to-end integration coverage against a real Safe v1.4.1 proxy lives in `test/PawthereumMamoYieldModule.fork.t.sol` (the `RealSafeForkTest` contract).

## Base mainnet addresses

| | |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Moonwell mUSDC | `0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22` |
| Moonwell Flagship USDC vault | `0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca` |
| Mamo USDC strategy factory | `0x5967ea71cC65d610dc6999d7dF62bfa512e62D07` |

The per-Safe Mamo strategy address is created via the factory and supplied at module-deployment time.

## Layout

```
src/
  PawthereumMamoYieldModule.sol       # the module
  interfaces/
    IMamoStrategy.sol
    IMToken.sol
    IERC4626Minimal.sol
    IERC20Minimal.sol
    ISafe.sol
script/
  DeployPawthereumMamoYieldModule.s.sol
test/
  PawthereumMamoYieldModule.t.sol         # mock-based unit tests
  PawthereumMamoYieldModule.fork.t.sol    # Base mainnet fork tests
```

## Build

```sh
forge build
```

## Test

```sh
# unit tests (no network)
forge test --match-path "test/PawthereumMamoYieldModule.t.sol" -vv

# fork tests (requires BASE_RPC_URL)
set -a && source .env && set +a
forge test --match-path "test/PawthereumMamoYieldModule.fork.t.sol" -vv

# everything
forge test
```

Copy `.env.example` to `.env` and fill in `BASE_RPC_URL` and `ETHERSCAN_API_KEY` for fork tests and verification.

## Deploy

Set the env vars in `.env`:

```
SAFE=                    # the Pawthereum Gnosis Safe
MAMO_STRATEGY=           # strategy created by the Mamo factory for the Safe
DONATION_RECIPIENT=
DEV_RECIPIENT=
PROTECTED_PRINCIPAL=     # initial USDC floor (6 decimals)
EXECUTION_INTERVAL=604800 # 7 days
MIN_CLAIM_AMOUNT=1000000 # 1 USDC minimum to bother executing
```

Then:

```sh
set -a && source .env && set +a
forge script script/DeployPawthereumMamoYieldModule.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

After deployment, the Safe must enable the module via a Safe transaction calling `enableModule(<deployed address>)`. This module cannot enable itself — that requires Safe-owner signatures.

## Admin

Only the Safe can call:

- `setDonationRecipient(address)` / `setDevRecipient(address)`
- `setProtectedPrincipal(uint256)` (manual override of the auto-ratcheted floor)
- `setExecutionInterval(uint256)`
- `setMinimumClaimAmount(uint256)`
- `pause()` / `unpause()`

## Constraints (by design)

The module **cannot**:

- call arbitrary contracts
- accept external calldata
- delegatecall
- approve tokens
- pull funds out of the Mamo strategy beyond the computed yield
- send funds to anyone other than the configured recipients
- change strategy ownership

All call-targets are immutable, all amounts are derived from the on-chain value calculation, and recipients are the only mutable destinations (Safe-controlled).
