# OG Club launch adaptation

The requested scope is delayed furniture-minter grants and recording box rolls
independently of delivery. No deployment, broadcast, dependency, build-configuration
or payment-token change was made. Constructors and the existing five-field
`purchases(uint256)` ABI remain compatible with the supplied factory requirements.

## Changes and reasons

| Files | Change | Requirement / reproduced finding |
| --- | --- | --- |
| `src/OGClubFurniture.sol` | Replaced `setMinter` with owner-only `grantMinter`, `cancelMinter`, `revokeMinter`, and permissionless `activateMinter`. Grants are immediate only at zero total supply; otherwise activation requires seven days. Added `pendingMinters`, proposal/cancellation events, and explicit missing/early proposal errors. Immediate grants and activations both emit `MinterSet`. Revoke clears proposals immediately. Re-proposing restarts the delay; cancellation leaves an already-active permission intact. | Requested change 1; audit `c74ac643813b`. Prevent immediate authorization of new arbitrary minting after the collection exists. |
| `src/OGClubBox.sol` | `open` reserves caps and records `BoxOpened` before attempting delivery in `try/catch`. Successful minting sets delivery status and emits `Delivered`; failure stores ordered IDs and emits `DeliveryFailed`. Added permissionless `deliver`, buyer-only `deliverTo`, `delivered` and `getStoredItems`. Retry effects precede minting and roll back on failure. Successful retries clear stored IDs. All four purchase/delivery entry points share the reentrancy guard. | Requested change 2; audits `e0a50d6e49b9`, `460e31d87310`, `5926736c3fa8`. Preserve a recorded roll through revocation, receiver rejection, cap depletion and expiry, and allow a non-receiver buyer to redirect it. |
| `src/OGClubBox.sol` | Delivery status shares the existing `opened` storage slot. The purchase getter keeps its old return values. Only failed initial deliveries allocate stored ID arrays. Initial mint gas is capped at the named `OPEN_MINT_GAS_LIMIT` of 1,000,000; forwarding also retains 300,000 gas for up to ten cold ID slots, the array length and failure-path overhead. Retries have no fixed gas cap. | Requested normal-path storage constraint; the gas-exhaustion warning in audit `5926736c3fa8`. A receiver must not exhaust the caller's ability to save its roll. A transaction still needs enough gas to execute the opening and store the result. |
| `test/OGClubFurniture.t.sol`, `test/FurnitureInvariant.t.sol` | Test initial grants/events, exact seven-day boundary, early and missing activation, arbitrary activators, cancellation, immediate revoke, proposal deletion/replacement, role access and removal of the old selector. Keep ownership, transfer, metadata and royalty checks. | Requested furniture tests and audit `c74ac643813b`. |
| `test/Opening.t.sol`, `test/EdgeCases.t.sol`, `test/FixedOdds.t.sol`, `test/Delivery.t.sol`, `test/helpers/Adversaries.sol` | Replace old rollback expectations with recorded-roll and retry expectations. Cover revoked minter through reveal expiry and delayed restoration, non-receiver redirection, first-attempt-only rejection, retry failure/atomicity, single/batch callback reentrancy, at-most-once delivery, undelivered cap reservation, capped-piece owner mint attempts, zero/duplicate IDs, unopened expiry and receivers that exhaust gas or return large revert data. | All requested box tests and audits `e0a50d6e49b9`, `460e31d87310`, `c74ac643813b`, `5926736c3fa8`, `b2396477958b`. |
| `test/BoxInvariant.t.sol`, `test/MultiActorInvariant.t.sol`, `test/helpers/BoxTestBase.sol` | Check reserved per-item counts equal delivered supply plus stored undelivered IDs. Stateful actions reject, retry and redirect deliveries, verify immutable recorded-roll hashes, and count successful deliveries independently. Retain cap, payment-conservation, zero box-token balance and one-time opening checks. Successful normal opens must be delivered with no stored items. | Requested invariants; audit `b2396477958b`. |
| Other affected test fixtures (`test/Payments.t.sol`, `test/Seasons.t.sol`, shared setup and invariant setup) | Replace old minter API calls with grants/revokes. Their existing payment, season, selection and ownership expectations remain intact. | API migration required by requested change 1. |
| `README.md` | Document opening versus delivery, all new views/events and role operations, notice-period limitations, gas limits, preserved expiry, permissionless retries, buyer redirection, and `grantMinter(box)` immediately after deployment before any mint. Correct the overly broad claim that every pending ten-pack can only get worse: its existing guaranteed-tenth-pick rule remains state-dependent until opening. | Requested README changes; audits `5926736c3fa8` and `b59f42caf97d`. |

## Imported audit reproduction

The unchanged tree passed **81 tests**, not the 89 mentioned in the assignment,
with the supplied verifier seed. Before changing production code, the three pinned
proofs were copied to disposable `test/scratch/` and executed:

- `e0a50d6e49b9`: reproduced. The revoked-minter proof failed with
  `honest roll was lost: 0 != 3`. The same proof now passes; permanent tests also
  exercise restoration after existing supply triggers the seven-day delay.
- `460e31d87310`: reproduced. The non-receiver proof failed because `open` reverted
  and the paid roll was unrecoverable. The same proof now passes; permanent tests
  verify failed retries and buyer-only redirection after expiry.
- `c74ac643813b`: reproduced. The owner proof failed because it minted a capped
  piece past its cap without delay. The same proof now passes, supplemented by a
  real box cap and activation-boundary tests.
- `5926736c3fa8`: reproduced independently using a rejecting ten-pack buyer whose
  tenth selection was a cap-one Rare. Rejecting the first opening, opening a
  competing purchase, then accepting upgraded the tenth piece to Epic/Legendary.
  The permanent regression now reserves the Rare on the first opening, leaves the
  competing pick with fallback, and delivers exactly the original ten IDs.
  Gas-exhaustion and large-revert-data tests cover the reported catch-path concern.
- `b2396477958b`: confirmed by baseline test execution and inspection: the existing
  suite treated non-receiver loss and delivery rollback as expected. Those tests
  and supply invariants have been updated, with the missing recovery scenarios added.
- `b59f42caf97d`: confirmed as configuration/trust information, not a defect. The
  deployment tests show the box initially lacks mint permission, buys reject it,
  and any account can mint `MockOG`. The constructors already use explicit owner
  arguments and do not call dependencies. The explicit task retains post-deploy
  authorization and the existing Sepolia mock. No constructor redesign or new token
  was needed. `MockOG` remains testnet-only and carries no scarcity guarantee.

No reported application finding was left unreproduced. The delay is a notice
period, not a global furniture cap: existing minters, initially granted minters,
and newly activated minters retain the requested unrestricted mint interface.
Recorded delivery can remain pending if mint permission is never restored or the
buyer cannot receive and cannot call `deliverTo`. An unopened purchase still
expires to fallback after the original 256-block window.

The existing `launch.json` was not edited: manifest preparation belongs to the
subsequent step. Its legacy post-deploy note should use the README's new
`grantMinter(box)` instructions. No signer or deployment input is needed to build
or test this change.

## Validation

- `forge build` using the repository's unchanged Foundry configuration.
- `FOUNDRY_FUZZ_SEED=0x5fbefb26c0c2c1788540f6d50945b685a8eec10a4788d431c33daee28f75b7c5 forge test`.
- `forge fmt --check` after formatting.
- The three supplied proofs also pass locally in disposable `test/scratch/`;
  delivered regressions live in the permanent test files listed above.
- Local deployment tests exercise explicit constructor owners, absent dependencies,
  runtime size/opcode restrictions, and initial authorization requirements. The
  supplied protected deployment/ownership tests were read; their factory harness
  needs verifier-generated deployment inputs and was not executed here.

Final results: **95 permanent tests passed, zero failed or skipped**, using the
supplied verifier seed, after removing the disposable proofs. Before removal,
all **98 tests including the three supplied proofs** passed. `forge build`,
`forge fmt --check` and `git diff --check` passed. Runtime sizes are 11,811 bytes
for OGClubBox, 8,949 for OGClubFurniture and 1,851 for MockOG, below EIP-170.
Foundry's nonfatal lint messages include timestamp comparisons and post-call
status/events; the seven-day timestamp rule and guarded delivery transitions
are intentional and covered by boundary/reentrancy tests.

No Slither, Mythril, external-chain simulation or deployment was performed.
