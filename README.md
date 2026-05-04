# Pawthereum Mamo Yield Capture Safe Module

A Gnosis Safe Module that autonomously skims yield from a Mamo USDC strategy owned by the Pawthereum Safe and distributes it across a Safe-configured list of recipients, with any unallocated remainder auto-compounded back into protected principal — without ever touching principal.

## Invariant

```
(strategyValueAfter + safeIdleUSDC) >= protectedPrincipal
```

If this invariant is ever violated the execution reverts. Principal is sacrosanct.

## How it works

Once per `executionInterval`, anyone can poke `executeYieldCapture()`:

1. Compute `totalYield = (strategy value + safe idle USDC) - protectedPrincipal`
2. For each configured recipient, compute `amount = totalYield * recipient.bps / 10_000`. Sum these as `totalDistributed`.
3. Withdraw `totalDistributed` from the Mamo strategy via the Safe and transfer each recipient's share
4. Verify the principal invariant
5. Auto-ratchet: bump `protectedPrincipal` by the un-distributed remainder (`totalYield - totalDistributed`) so the buffer compounds

If recipient bps sum to less than 10,000, the remainder compounds. If they sum to exactly 10,000, nothing compounds and the entire yield is paid out. An empty recipients list means 100% compounds — useful as a "distributions paused, principal still grows" mode (set `minimumClaimAmount` to 0 in that case).

The auto-ratchet means the floor grows monotonically with the strategy.

## Previewing yield

Before executing, you can dry-run `previewYieldCapture()` to see expected amounts and whether execution would succeed. It returns a `Preview` struct. Because `balanceOfUnderlying` on the Moonwell mToken accrues interest as a side-effect, this function cannot be marked `view` — but it should still be called as a simulation (no gas, no state change), not as a transaction.

```sh
cast call <MODULE_ADDRESS> \
  "previewYieldCapture()((uint256,uint256,uint256,uint256,uint256,uint256[],bool))" \
  --rpc-url $BASE_RPC_URL
```

The seven struct fields in order:

| # | Name | Description |
|---|---|---|
| 1 | `strategyValue` | Total USDC value held in the Mamo strategy (raw 6-decimal units) |
| 2 | `safeIdle` | USDC sitting idle in the Safe itself |
| 3 | `totalYield` | `(strategyValue + safeIdle) - protectedPrincipal` |
| 4 | `totalDistributed` | Sum of per-recipient amounts that would be paid out |
| 5 | `compoundedAmount` | `totalYield - totalDistributed` — bumped into `protectedPrincipal` |
| 6 | `amounts` | Per-recipient amounts; `amounts[i]` corresponds to `getRecipients()[i]` |
| 7 | `canExecute` | `true` if not paused, interval has elapsed, yield is non-zero, and `totalDistributed >= minimumClaimAmount` |

Divide any USDC amount by `1e6` for a human-readable value. If `canExecute` is `false`, check whether the module is paused, the interval hasn't elapsed yet, there's no yield to claim, or distributions are below the minimum threshold.

**Do not send `previewYieldCapture` as a transaction** — return values are discarded by the EVM when called that way, and you will spend gas for nothing.

## Configuring recipients

The Safe owns the recipient list. Each entry is `(address addr, uint16 bps)` and the sum of bps across all entries must be ≤ 10,000. Whatever doesn't sum to 10,000 is the share that auto-compounds into `protectedPrincipal` each cycle.

Read the current configuration:

```sh
# returns (recipients, compoundBps)
cast call <MODULE_ADDRESS> \
  "getDistribution()((address,uint16)[],uint16)" \
  --rpc-url $BASE_RPC_URL
```

Update via a Safe transaction calling `setRecipients((address,uint16)[])`. Validation rules:

- Each `addr` must be non-zero
- Each `bps` must be > 0 (omit a recipient instead of giving it 0 bps)
- No duplicate addresses
- Sum of all `bps` ≤ 10,000
- At most `MAX_RECIPIENTS` entries (16)

An empty list is allowed and means "100% compound". `setRecipients` replaces the entire list — there are no add/remove primitives.

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
SAFE=                                # the Pawthereum Gnosis Safe
MAMO_STRATEGY=                       # strategy created by the Mamo factory for the Safe
RECIPIENT_ADDRESSES=0xAAA...,0xBBB... # comma-separated; same length as RECIPIENT_BPS
RECIPIENT_BPS=4500,4500              # comma-separated; sum must be <= 10000
PROTECTED_PRINCIPAL=                 # initial USDC floor (6 decimals)
EXECUTION_INTERVAL=604800            # 7 days
MIN_CLAIM_AMOUNT=1000000             # 1 USDC minimum to bother executing
```

`RECIPIENT_ADDRESSES` and `RECIPIENT_BPS` may both be empty strings to deploy with no recipients (100% compound from day one).

Then:

```sh
set -a && source .env && set +a
forge script script/DeployPawthereumMamoYieldModule.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

After deployment, the Safe must enable the module via a Safe transaction calling `enableModule(<deployed address>)`. This module cannot enable itself — that requires Safe-owner signatures.

## Admin

Only the Safe can call:

- `setRecipients((address,uint16)[])` (replaces the entire recipient list — see [Configuring recipients](#configuring-recipients))
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

All call-targets are immutable, all amounts are derived from the on-chain value calculation, and the recipient list is the only mutable destination set (Safe-controlled).
