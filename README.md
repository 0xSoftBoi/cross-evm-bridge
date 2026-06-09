# cross-evm-bridge

A custodial lock/release token bridge (Solidity + Hardhat + an ethers relayer). Lock tokens
on a source chain; a relayer mirrors the lock and releases on the destination chain.

Write-up: [*The bridge that paid twice*](https://0xsoftboi.github.io/blog/the-bridge-that-paid-twice/).

## The bug the original had

The first version released on **every** `Deposit` event with no record of what had already
been paid:

```solidity
function release(address _to, uint256 _amount) public onlyOwner {
    IERC20(token).transfer(_to, _amount);   // no nonce, no idempotency, no event
}
```

and the relayer called it once per event:

```ts
sepoliaBridge.on("Deposit", async (depositor, amount) => {
  await mumbaiBridge.release(depositor, amount);   // fire on every delivery
});
```

Event delivery is **not exactly-once**. A relayer restart, a websocket reconnect, or a
source-chain **reorg** re-delivers the same `Deposit` — and the destination, having no
memory of prior payouts, **releases again**. Repeat to drain the reserve. (Also: raw
`transfer`/`transferFrom` with unchecked returns, and no event on release to reconcile
against.)

## The fix

- **Idempotent releases.** Each payout is keyed by a `transferId` derived from the *unique*
  source lock (`srcChainId, srcBridge, srcNonce, to, amount` + the destination chain id and
  this contract). `processed[transferId]` means a re-delivered event reverts with
  `AlreadyReleased` instead of paying twice.
- **Authorized + verifiable.** A release carries a **validator signature** over that
  `transferId`, so the authority to pay is explicit and decoupled from the owner — and the
  signature can't be replayed onto another chain/deployment (both are in the id).
- **`SafeERC20`**, a `Released` event, and **`Pausable`**.
- The relayer (`bot.ts`) now listens for `Locked`, waits for source **finality** before
  signing (idempotency stops *double* pays; finality stops paying for a lock a reorg
  erased), and treats `AlreadyReleased` as a no-op.

## Trust model (read this)

This is still a **custodial** bridge: you trust the `validator` to sign payouts only for
real, finalized source locks. The hardening removes the *mechanical* failure (double-pay,
unsafe transfers, unauthorized release) but not the *trust* — a malicious or compromised
validator can still sign a fake payout. A **trust-minimized** bridge replaces the signature
with a **light-client / Merkle proof** of the source `Locked` event, so the destination
verifies the lock happened rather than trusting a signer. That's the real next step and is
**out of scope here** (documented, not built). See [SECURITY.md](SECURITY.md).

## Build & test

```bash
forge test          # 6 tests: valid release, idempotent no-double-pay, wrong/forged signer,
                    # tampered amount, deposit nonce, pause
npx hardhat compile # the relayer + deploy scripts (ethers v6)
```

Not audited; educational. [MIT](LICENSE).
