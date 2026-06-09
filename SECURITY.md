# Security notes

Educational; **not audited**.

## What was fixed

- **Double-pay on event re-delivery (critical).** The original released on every `Deposit`
  with no idempotency; re-delivered events (relayer restart, ws reconnect, source reorg)
  paid out repeatedly. Now each payout is keyed by a `transferId` over the unique source
  lock + destination context, and `processed[transferId]` makes release pay at most once.
- **Unauthorized / unverifiable release.** Release now requires a `validator` signature over
  the `transferId`; the authority is explicit and decoupled from the owner, and the id binds
  the destination chain id + this contract so a signature can't be replayed elsewhere.
- **Unsafe ERC-20 calls.** `SafeERC20` for both lock and release.
- **No reconciliation.** A `Released` event + a `Locked` nonce let the relayer/anyone
  reconcile that each lock paid exactly once.
- **Pausing.** `Pausable` for incident response.

## Residual / out of scope (the honest part)

- **Custodial trust.** A compromised or malicious `validator` can still sign a payout for a
  source lock that never happened. The idempotency/signature work removes *mechanical* loss,
  not *trust* loss. The trust-minimized design is a **light-client / Merkle-proof** release
  (verify the source `Locked` event was included and finalized, instead of trusting a
  signer). Not built here.
- **Finality.** Idempotency prevents paying the same lock twice; it does **not** prevent
  paying a lock that a reorg later erased. The relayer waits `SRC_CONFIRMATIONS` before
  signing — set it to the source chain's finality, not a small constant.
- **Validator key management.** Single-key validator here; production should use a
  threshold/multisig validator set so one key can't sign payouts alone.
- **Liquidity.** `release` assumes the destination reserve is funded; there is no automatic
  mint/burn accounting tying total locked to total released across chains.

## Reporting

No deployment, no funds. Open an issue for a soundness bug (e.g. a release path that can pay
a `transferId` twice, or a signature that verifies for the wrong validator/amount).
