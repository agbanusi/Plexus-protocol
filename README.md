# Plexus Protocol

**Liquidity that stacks.**

Every instant-redemption design in production today makes the same trade: to promise a holder they can exit *now*, you have to park idle stables against their asset, and that pot backs exactly one asset. Want to underwrite a second? Raise a second pot. A third? A third. Liquidity fragments, every new integration starts from zero, and most of that capital sits still most of the time — because redemptions are bursty, and you're sizing each pot for a spike that rarely comes.

Plexus breaks that one-to-one. Every vault is itself an ERC4626 over the same base asset, so **vaults allocate into each other**. One pool of stables can sit behind a dozen redemption desks at once, backstopping each of them, and earn yield at the leaves while it waits. The spike in one vault is absorbed by capital that's idle in another — which is exactly the capital you'd otherwise be paying to keep still.

```
Vault A ──50%──> Vault B ──40%──> Vault D
    ├───30%────> Vault C ──30%──> Morpho vault
    └───20%────> Morpho vault
```

A holder redeems against vault B. B has no idle stables of its own — it pulls from Morpho, holding liquidity that came in as an LP deposit into A. B's fee accrues to B's shares, which A owns, so the yield flows back up to A's LPs. **The same dollar underwrites redemptions at every level of that graph, and earns yield at the bottom of it.**

## What this unlocks

- **Onboard an asset without raising a pool.** A curator who wants to underwrite instant redemption for a new tokenized treasury deploys a vault, points it at existing liquidity, and is live. No bootstrap, no fragmentation, no waiting to hit critical mass. The marginal cost of the next asset collapses.
- **Redemption logic stays yours.** Each vault names its own redeemer at onboarding — the contract, the calldata, the settlement flow. A T-bill fund with a 2-day window and a private credit deal with a 30-day one live side by side on shared liquidity and never touch each other's code.
- **Underwrite and farm with the same capital.** Idle liquidity isn't dead weight parked against a spike. It's allocated into Morpho or any ERC4626 and pulled back the moment a redemption lands. Curators get a yield venue and a redemption backstop out of one balance sheet.
- **Curators compose, not compete.** A deep, conservative base vault can wholesale liquidity to specialist vaults downstream and earn their fees, while each specialist keeps its own risk. Liquidity providers pick their depth in the stack: root for diversified fee flow, leaf for concentrated exposure.
- **Risk stays where it's underwritten.** A vault holds *shares* of its downstream vaults, never their RWA. B taking on a distressed asset never puts that asset on A's books — A's exposure is bounded by its cap on B, and by B's own `rwaCap`. Contagion is priced and capped per edge, not implicit.
- **Price the spread, not the wait.** The fee an RWA holder pays for immediacy is the LP's yield. Curators tune `redemptionFee` and `rwaCap` per asset and let the market decide what jumping the settlement queue is worth.

The result is an open market for immediacy: anyone can bring an asset, anyone can bring liquidity, and the liquidity doesn't have to pick just one asset to believe in.

## Table of Contents

- [Plexus Protocol](#plexus-protocol)
- [What this unlocks](#what-this-unlocks)
- [Table of Contents](#table-of-contents)
- [Protocol Overview](#protocol-overview)
- [Liquidity Stacking](#liquidity-stacking)
  - [Allocation Mechanics](#allocation-mechanics)
  - [Stacking](#stacking)
  - [Cycle Safety](#cycle-safety)
- [Oracle Architecture](#oracle-architecture)
- [Manager Roles](#manager-roles)
- [User Guide](#user-guide)
  - [Deposits](#deposits)
  - [Withdrawals](#withdrawals)
  - [Instant RWA Redemption](#instant-rwa-redemption)
  - [External Settlement](#external-settlement)
- [Repository Structure](#repository-structure)
- [Dependencies](#dependencies)
  - [Required](#required)
  - [Dependency Strategy](#dependency-strategy)
- [Development](#development)
  - [Build](#build)
  - [Test](#test)
  - [Format](#format)
- [Security](#security)
  - [Trust Assumptions](#trust-assumptions)
  - [Known Limitations](#known-limitations)
  - [Audit Reports](#audit-reports)
  - [Bug Bounty](#bug-bounty)
- [License](#license)

## Protocol Overview

The core component is the `Vault`, which pairs one base asset with exactly one RWA and manages LP positions, allocation, and redemption.

- **Vault**: An ERC4626 over a base asset (a stable), paired with exactly one RWA. LPs deposit the base asset and receive shares; RWA holders swap into the base asset instantly. Inherits `Allocator`.
- **Allocator**: The allocation layer every vault inherits. Pushes idle base asset into external ERC4626 targets under per-target caps. Targets are ERC4626 over the same base asset, so there is no adapter layer.
- **Oracle**: Wraps one Chainlink-style feed. Deployed per vault, and reports the price of one whole RWA in the base asset, scaled to 1e18.
- **Redeemer**: Not a Plexus contract. An issuer-specific address, set per vault at onboarding, that converts held RWA back into the base asset out-of-band. This is what keeps a new asset's redemption logic from touching any other vault.

## Liquidity Stacking

### Allocation Mechanics

- **Targets**: `setCaps` registers an ERC4626 target and bounds it with an `absoluteCap` (max base asset in that target) and a `relativeCap` (max share of `totalAssets`, in WAD). A target with an outstanding balance cannot be removed.
- **Liquidity target**: One target designated as the default route. Deposits flow into it immediately, and withdrawals and redemptions pull back from it when local idle is short.
- **Accounting**: `totalAssets()` is idle base asset, plus base asset held across every target, plus RWA marked at the oracle price. Allocation is read live through each target rather than stored, so yield in a target accrues to LPs with no sync step.

### Stacking

Because `Vault` is an ERC4626 over its base asset, a vault is a valid allocation target for another vault, and allocation composes to arbitrary depth.

Each hop stays independently risk-managed. `absoluteCap` and `relativeCap` bound what any one vault routes into any one target, and each vault's RWA exposure is bounded by its own `rwaCap`. A vault holds shares of its downstream vaults, never their RWA.

Depth has costs: `totalAssets()` fans out across the graph on every deposit, withdrawal, and redemption, and leaf liquidity is only reachable from the root as far as each intermediate hop's `maxWithdraw` allows.

### Cycle Safety

A vault must never be reachable from itself (`A -> B -> A`). `totalAssets()` reads through to each target, so a cycle makes it recurse with no base case until it exhausts gas — which would brick every vault on the loop, taking deposits, withdrawals, redemptions and allocation with it. This is a property of the *edge*, not of the amounts: a 0% cap with nothing allocated recurses exactly like a 50% one, because `totalAllocated()` previews every registered target regardless of balance.

Two mechanisms prevent it:

- **`setCaps` walks the graph through the edge it just added.** It calls its own `totalAssets()` after registering the target. If the new edge closes a loop, that walk recurses until it dies, and the whole call reverts, so the edge never lands. Closing a loop always requires a `setCaps` somewhere, and that call is the one that fails.
- **The vault uses one virtual share and one virtual asset.** This removes the `supply == 0` branch from every ERC4626 conversion. Without it, previewing an *empty* target returns early without reading its `totalAssets`, so the walk above would stop short and an empty loop would pass `setCaps` and only brick on the first deposit. It also gives the usual first-depositor inflation resistance. The cost is that conversions round down by up to one wei per hop, in the vault's favour.

`setCaps` also rejects a direct self-target, and `removeTarget` checks the target's raw share balance instead of previewing through it, so it stays callable as an escape hatch on a target whose accounting is unreadable.

## Oracle Architecture

- `Oracle` is deployed per vault and is the vault's only price entry point. `price()` takes no arguments and returns the price of one whole RWA denominated in the vault's base asset, scaled to 1e18.
- It normalizes the feed's own decimals to 1e18 and nothing else. Token decimals are handled by the vault in `rwaValue`, which scales by the base and RWA decimals — normalizing in both places would double-count.
- `price()` reverts on a non-positive answer, an unset round, and on any answer older than `maxAge`. There is no fallback: a stale feed halts redemption and share pricing rather than quoting a stale mark.

## Manager Roles

- **Owner**: Sets the oracle, the redeemer, `redemptionFee` and `rwaCap`, registers targets and their caps, designates the liquidity target, grants the allocator role, and drives external settlement. Fully trusted.
- **Allocator**: Can `allocate` and `deallocate` between registered targets, within caps. Cannot move funds out of the vault. The owner holds this role implicitly.

## User Guide

### Deposits

LPs deposit the base asset and receive vault shares, earning the redemption fee and any yield from allocation targets.

1. **Call deposit**: The user calls `deposit(assets, receiver)` or `mint(shares, receiver)` on the `Vault`.
2. **Share calculation**: Assets convert to shares against the current `totalAssets`, which reads through the whole allocation graph.
3. **Allocation**: `afterDeposit` routes the deposit into the vault's `liquidityTarget` immediately, subject to that target's caps.

### Withdrawals

Withdrawals are single-step. The user calls `withdraw(assets, receiver, owner)` or `redeem(shares, receiver, owner)`. `beforeWithdraw` pulls back from the `liquidityTarget` to cover the payout if local idle is short, bounded by that target's `maxWithdraw`. A withdrawal larger than what the graph can free reverts.

### Instant RWA Redemption

The protocol's purpose: an RWA holder exits to the base asset immediately rather than waiting on the issuer.

1. The holder calls `redeemRwa(rwaAmount, minBaseOut)`.
2. The vault values the RWA at the oracle price and applies `redemptionFee`. `previewRedeemRwa` quotes this off-chain.
3. The total RWA exposure is checked against `rwaCap`, and the payout against `minBaseOut`.
4. The RWA transfers in, the vault sources base asset from its liquidity target if needed, and the base asset transfers out.

The fee is what LPs earn: the vault takes on RWA worth more than the base it pays out.

### External Settlement

The RWA accumulates on the vault's books until the owner settles it back to the base asset through the vault's redeemer. Settlement is issuer-specific and not atomic, so the owner supplies the calldata and the call target is pinned to `redeemer`.

1. **`externalRedeem(data, value)`**: Approves the vault's RWA balance to the redeemer and calls it. The RWA that leaves is booked as `rwaInRedemption` and still counts toward `totalAssets` and `rwaExposure`, so the share price does not move.
2. **`finalizeExternalRedeem(rwaAmount, data, value)`**: Calls the redeemer to collect the base asset, clears `rwaAmount` from `rwaInRedemption`, and allocates the proceeds to the liquidity target.

## Repository Structure

```
plexus-protocol/
├── src/                          # Main source code
│   ├── Vault.sol                 # ERC4626 base asset + one RWA; instant redemption, settlement
│   ├── Allocator.sol             # Allocation layer inherited by every vault; targets and caps
│   ├── Oracle.sol                # Per-vault Chainlink-style price feed wrapper
│   └── interfaces/               # Protocol interfaces
│       ├── IOracle.sol           # Price entry point consumed by the vault
│       └── IPriceFeed.sol        # Minimal Chainlink AggregatorV3Interface
├── test/                         # Test suite
│   ├── Vault.t.sol               # Accounting, allocation, redemption, settlement, fuzz
│   ├── Stacking.t.sol            # Vault-to-vault composition and cycle safety
│   ├── Oracle.t.sol              # Feed normalization and staleness
│   └── mocks/                    # Test doubles (ERC20, yield vault, feed, redeemer)
├── script/                       # Deployment and interaction scripts
├── foundry.toml                  # Foundry configuration
└── lib/                          # Foundry dependencies
```

## Dependencies

### Required

[Foundry](https://book.getfoundry.sh/) - Development framework

```shell
curl -L https://foundry.paradigm.xyz | bash
foundryup  # Update to latest version
```

### Dependency Strategy

Dependencies are managed via git submodules in the `lib` directory. The protocol depends on `solmate` for ERC20, ERC4626, `Owned`, `SafeTransferLib` and `FixedPointMathLib`, and on `forge-std` for tests.

Solidity is pinned to `0.8.28`, targeting the `cancun` EVM for portability across L2s.

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

- Run a specific suite: `forge test --match-contract StackingTest`
- Run with verbosity: `forge test -vvv`

### Format

```shell
forge fmt
```

## Security

### Trust Assumptions

- The **owner is fully trusted**. It sets the redeemer and drives settlement, which involves calling that redeemer with owner-supplied calldata. The call target is pinned to `redeemer`, but a malicious or compromised owner can point the vault at a redeemer of its choosing.
- **Allocation targets are trusted.** A vault reads its own `totalAssets` through every target. A target that misreports, reverts, or reads back into the vault affects the vault's share price and liveness. Targets are owner-curated for this reason.
- The **price feed is trusted** within `maxAge`. The vault marks all RWA — held and mid-settlement — at that price.
- The **issuer is trusted to settle.** RWA sitting in `rwaInRedemption` is marked at full oracle value while off-chain. An issuer that never settles leaves that value permanently overstated.

### Known Limitations

- **A target can brick a vault after registration.** The `setCaps` walk validates the graph at registration time. An arbitrary ERC4626 target that only starts reading back into the vault later cannot be caught by any registration-time check. Curation is the mitigation.
- **Assets allocated into an unreadable target are stuck.** `deallocate` previews through the target, so it fails alongside `totalAssets`. `removeTarget` only helps while the balance is zero.
- **Depth costs gas.** `totalAssets()` fans out across the whole graph on every deposit, withdrawal, and redemption.
- **Redemption is oracle-priced, not market-priced.** `redeemRwa` fills at the oracle mark less the fee, so `redemptionFee` and `rwaCap` are the only buffer against a mispriced or depegging RWA.

### Audit Reports

Not yet audited. This code is unaudited and has not been reviewed for production use.

### Bug Bounty

Further details will be made available soon.

## License

Plexus Protocol is released under the MIT license. Each Solidity file declares its applicable license.
