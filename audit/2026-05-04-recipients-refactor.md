# Audit Memo: Configurable Recipients Refactor

**Date:** 2026-05-04
**Scope:** `src/PawthereumMamoYieldModule.sol` and call sites (deploy script, tests, README)
**Status of last audit baseline:** the prior version with hardcoded `donationRecipient` / `devRecipient` and a fixed `CLAIM_BPS = 9_000`, `DONATION_SPLIT_BPS = 5_000`, `DEV_SPLIT_BPS = 5_000`

## TL;DR

The two-stage hardcoded distribution (claim 90% → split 50/50 between donation/dev → compound 10%) has been replaced by a single configurable list of `(address addr, uint16 bps)` recipients managed by the Safe. Whatever doesn't sum to 10,000 bps auto-compounds into `protectedPrincipal`. Constructor signature, `setRecipients` admin function, `executeYieldCapture` return tuple, `previewYieldCapture` return shape, and the `YieldExecuted` event are all changed (no live ABI consumers to preserve — this is pre-deployment).

The principal-protection invariant, `_safeExec` pattern, reentrancy guard, Safe-only modifier, `getStrategyValue` math, pause/interval/min-claim semantics, and all immutables are **unchanged**.

## Behavioral changes worth flagging

1. **The "always compound at least 10%" floor is gone.** If the Safe configures recipients summing to 10,000 bps, 100% of yield is paid out and `protectedPrincipal` does not grow that cycle. This is intentional per the Safe-owner request.
2. **Empty recipient list is allowed.** Means "100% compound this cycle." Useful for pausing distributions while still ratcheting principal. Triggered by `_recipients.length == 0`. The execute path skips withdraw + transfers entirely (`if (totalDistributed > 0)` guard).
3. **`minimumClaimAmount` now gates `totalDistributed`** (sum of recipient amounts), not the previous "claimedYield" notion. With empty recipients you must set `minimumClaimAmount = 0` for execute to succeed.
4. **Build pipeline change:** `via_ir = true` added to `foundry.toml`. The new struct-typed event (`RecipientsUpdated(Recipient[], uint16)`) and struct return (`Preview`) pushed the legacy pipeline over the stack-too-deep limit. Bytecode is therefore produced by the IR pipeline rather than the legacy one.

## Files changed

| File | Change |
|---|---|
| `src/PawthereumMamoYieldModule.sol` | Core refactor (see "What to focus on" below) |
| `script/DeployPawthereumMamoYieldModule.s.sol` | `DONATION_RECIPIENT` / `DEV_RECIPIENT` env vars replaced by parallel `RECIPIENT_ADDRESSES` / `RECIPIENT_BPS` lists |
| `test/PawthereumMamoYieldModule.t.sol` | Rewritten against the new API; added validation-matrix tests |
| `test/PawthereumMamoYieldModule.fork.t.sol` | Updated to construct with new signature; assertions now check per-recipient transfers |
| `README.md` | Updated "How it works", "Previewing yield", "Admin", added "Configuring recipients" |
| `foundry.toml` | Added `via_ir = true` |

## What to focus on (security-relevant)

### 1. New validation logic in `_setRecipients` (lines 251–273)

```solidity
function _setRecipients(Recipient[] memory newRecipients) internal {
    uint256 n = newRecipients.length;
    if (n > MAX_RECIPIENTS) revert TooManyRecipients();      // cap = 16

    uint256 sumBps;
    for (uint256 i; i < n; ++i) {
        Recipient memory r = newRecipients[i];
        if (r.addr == address(0)) revert ZeroAddress();
        if (r.bps == 0) revert ZeroBps();
        for (uint256 j; j < i; ++j) {
            if (newRecipients[j].addr == r.addr) revert DuplicateRecipient();
        }
        sumBps += r.bps;
    }
    if (sumBps > BPS) revert BpsOverflow();

    delete _recipients;
    for (uint256 i; i < n; ++i) {
        _recipients.push(newRecipients[i]);
    }

    emit RecipientsUpdated(newRecipients, uint16(BPS - sumBps));
}
```

**Considerations:**
- O(n²) duplicate scan is bounded by `MAX_RECIPIENTS = 16`; worst-case ~120 comparisons.
- `sumBps` accumulator: max value `MAX_RECIPIENTS * type(uint16).max = 16 * 65_535 = 1_048_560`. Fits in `uint256` trivially; no overflow risk.
- `BPS - sumBps` is checked-arithmetic safe because `sumBps > BPS` reverts above.
- `delete _recipients` followed by `push` zeros the entire prior array slot-by-slot (per Solidity semantics for dynamic arrays of structs); slots are then overwritten or remain zeroed for entries shorter than the prior list. No stale storage.
- Reused unchanged from constructor → setter, so initial state and update state validate identically.

### 2. Distribution math in `executeYieldCapture` and `_computeAmounts` (lines 144–207)

```solidity
function _computeAmounts(uint256 totalYield)
    internal view returns (uint256[] memory amounts, uint256 totalDistributed)
{
    uint256 n = _recipients.length;
    amounts = new uint256[](n);
    for (uint256 i; i < n; ++i) {
        uint256 amt = (totalYield * _recipients[i].bps) / BPS;
        amounts[i] = amt;
        totalDistributed += amt;
    }
}
```

**Rounding behavior:** Each per-recipient amount uses floor division. The remainder (`totalYield - totalDistributed`) flows into `compoundedAmount` and is added to `protectedPrincipal`. **Rounding therefore always favors the principal, never the recipients** — recipients can never collectively receive more than `totalYield`.

**Overflow analysis:** `totalYield * bps` where `bps <= 10_000` and `totalYield` is bounded by total Mamo strategy assets (USDC, 6 decimals). Product fits in `uint256` for any realistic value. (For overflow we'd need `totalYield > 2^256 / 10_000 ≈ 1.16e73` USDC.)

**Withdraw amount safety:** The strategy is asked to withdraw exactly `totalDistributed`. Because `totalDistributed = sum(floor(totalYield * bps / 10_000))` and `sum(bps) <= 10_000`, `totalDistributed <= totalYield`. So we never attempt to withdraw more than the actual yield — principal is not touched.

**Empty/all-zero distribution path:** If `_recipients.length == 0` or every `bps` is so small that all amounts floor to zero, `totalDistributed == 0` and the entire `withdraw + transfer` block is skipped via `if (totalDistributed > 0)`. The strategy is not contacted, no Safe txs are issued — only `protectedPrincipal` is bumped. (Note: zero `bps` entries cannot exist due to `ZeroBps` validation, so this only kicks in for `n == 0` or for tiny `totalYield * bps < 10_000`.)

### 3. Per-recipient transfer loop in `_payRecipients` (lines 209–219)

```solidity
function _payRecipients(uint256[] memory amounts) internal {
    uint256 n = amounts.length;
    for (uint256 i; i < n; ++i) {
        uint256 amt = amounts[i];
        if (amt > 0) {
            address to = _recipients[i].addr;
            _safeExec(USDC, abi.encodeCall(IERC20Minimal.transfer, (to, amt)));
            emit YieldDistributed(to, amt);
        }
    }
}
```

**Considerations:**
- Each transfer goes through the unchanged `_safeExec` helper — same Safe-call pattern, same false-bool check, same revert semantics as the prior single donation/dev transfers.
- Loop bound: `MAX_RECIPIENTS = 16`. Worst-case 16 Safe-mediated USDC transfers per `executeYieldCapture` call. Gas is the only concern; no DoS surface because `setRecipients` is Safe-only.
- `if (amt > 0)` skip avoids burning gas on zero-amount transfers (which some ERC20s reject anyway).
- `i` indexes both `amounts` and `_recipients`. `_computeAmounts` set `amounts.length == _recipients.length`, and `executeYieldCapture` doesn't mutate `_recipients` between the two calls (no reentrancy possible — `nonReentrant` guard plus `_recipients` is only mutated by `setRecipients`/constructor, both `onlySafe`).

### 4. Principal invariant ordering (lines 174–176)

```solidity
compoundedAmount = totalYield - totalDistributed;
protectedPrincipal += compoundedAmount;
if (getStrategyValue() + getSafeUSDC() < protectedPrincipal) revert PrincipalViolation();
```

This preserves the **prior audit fix** where the invariant is checked against the *new* (post-ratchet) principal, not the old one. The test `test_RevertWhenRatchetWouldViolateInvariant` (using `RoundingShortStrategy`) continues to enforce this. I changed the variable shape (no `newPrincipal` local — direct mutation of `protectedPrincipal`), but the order of operations is identical: compute → ratchet → check → revert if invariant broken.

### 5. `previewYieldCapture` now returns a struct

```solidity
struct Preview {
    uint256 strategyValue;
    uint256 safeIdle;
    uint256 totalYield;
    uint256 totalDistributed;
    uint256 compoundedAmount;
    uint256[] amounts;
    bool canExecute;
}
function previewYieldCapture() external returns (Preview memory p) { ... }
```

Behaviorally equivalent to the old separate return values plus the new per-recipient `amounts` array. `canExecute` now also requires `totalYield > 0` (previously implicit through `claimedYield >= minimumClaimAmount` because the prior fixed-90% claim ratio meant `claimedYield > 0` iff `totalYield > 0`; with empty recipients that linkage no longer holds).

### 6. Constructor reuses the setter validator

The constructor calls `_setRecipients(initialRecipients)` (line 107). Same validation, same emitted `RecipientsUpdated` event at deployment. Empty initial list is accepted. Constructor zero-address checks for the other params (Safe, strategy, USDC, mToken, vault) are unchanged.

### 7. `via_ir = true` in `foundry.toml`

This switches the build from the legacy pipeline to the IR pipeline. Adding it was forced by stack-too-deep when emitting the new `RecipientsUpdated(Recipient[], uint16)` event with the legacy pipeline. Worth confirming: same source, two pipelines, different bytecode. No behavioral difference for our test matrix (52/52 pass). If the audit baseline assumed the legacy pipeline, please reassess gas characterization and any bytecode-layout-sensitive checks.

## What did NOT change (skip these)

- `getStrategyValue()` — identical math, mirrors Mamo's `_getTotalBalance()`
- `getSafeUSDC()` — identical
- `_safeExec` — byte-for-byte identical; same `(ok, ret)` decoding, same false-bool revert
- `nonReentrant` modifier on `executeYieldCapture`
- `onlySafe` modifier and its application to all admin functions
- All immutables: `SAFE`, `MAMO_STRATEGY`, `USDC`, `M_TOKEN`, `META_MORPHO_VAULT`
- `pause` / `unpause` / `setProtectedPrincipal` / `setExecutionInterval` / `setMinimumClaimAmount` (event shapes and validation unchanged)
- `BPS = 10_000` constant
- Time gating via `lastExecutionTimestamp + executionInterval`
- The `WithdrawFailed` post-withdraw delivery check
- The `NoYield` revert when `totalAssets <= protectedPrincipal`
- `BelowMinimum` revert semantics (now applied to `totalDistributed`)

## Removed surface

- `setDonationRecipient(address)` / `setDevRecipient(address)`
- `donationRecipient` / `devRecipient` public state vars
- `DonationRecipientUpdated` / `DevRecipientUpdated` events
- `CLAIM_BPS` / `DONATION_SPLIT_BPS` / `DEV_SPLIT_BPS` constants

## New surface

| Function / event | Purpose |
|---|---|
| `setRecipients(Recipient[] calldata)` | Replace entire recipient list (Safe-only) |
| `getRecipients() returns (Recipient[])` | Full list |
| `getRecipient(uint256) returns (address, uint16)` | Single entry by index |
| `recipientCount() returns (uint256)` | Length |
| `getDistribution() returns (Recipient[], uint16 compoundBps)` | Headline reader: list + the implicit "compound bucket" |
| `MAX_RECIPIENTS = 16` constant | Gas/DoS cap |
| `event RecipientsUpdated(Recipient[], uint16 compoundBps)` | Emitted on set + at deployment |
| `event YieldDistributed(address indexed, uint256)` | Emitted per-recipient inside `executeYieldCapture` |
| `event YieldExecuted(uint256 strategyValueBefore, uint256 totalYield, uint256 totalDistributed, uint256 compoundedAmount, uint256 newProtectedPrincipal)` | Replaces prior 6-field shape |
| `error ZeroBps`, `error BpsOverflow`, `error DuplicateRecipient`, `error TooManyRecipients` | Validation failure modes |

## Test coverage added

- Constructor: empty initial recipients accepted; zero-address-in-recipient still reverts
- `setRecipients` validation matrix: zero addr, zero bps, sum > 10,000, duplicate addr, exceeds-MAX, accepts-at-MAX
- Happy paths: 2 recipients (matches old 45/45/10 behavior), 3 recipients (30/30/30/10), full distribution (50/50/0), empty list (0/0/100)
- Auto-ratchet across multiple cycles still verified
- Per-recipient `YieldDistributed` events asserted
- `RecipientsUpdated` event asserted
- `getDistribution` returns correct compoundBps for both populated and empty lists
- All prior audit-fix tests (`RoundingShortStrategy`, `EvilStrategy`, `LyingUSDC`) carried forward against the new API

**Result:** 52/52 tests pass (43 unit + 9 fork including real Safe v1.4.1 end-to-end on Base mainnet fork).

## Open questions for the audit

1. Is `MAX_RECIPIENTS = 16` an acceptable gas cap, or do you want a lower bound?
2. Is the rounding-favors-principal default acceptable, or should the contract redistribute the rounding dust to recipients (e.g., give the last recipient `totalDistributed` complement)?
3. Comfort with `via_ir = true`? If the audit baseline assumed the legacy pipeline, we can reassess.
4. The "empty list = 100% compound" mode pairs with `minimumClaimAmount = 0`. Should we make this implicit (e.g., skip the min-claim check when `_recipients.length == 0`)? Current design forces the Safe to set both, which is more explicit but easier to misconfigure.
