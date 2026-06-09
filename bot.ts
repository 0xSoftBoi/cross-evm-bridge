import { Contract, WebSocketProvider, JsonRpcProvider, Wallet, getBytes } from "ethers";
import { Bridge__factory } from "./typechain-types";
import * as dotenv from "dotenv";

dotenv.config();

// Source chain (where tokens are Locked) and destination chain (where they're Released).
const SRC_CHAIN_ID = Number(process.env.SRC_CHAIN_ID!!);
const SRC_BRIDGE = process.env.SRC_BRIDGE_ADDRESS!!;
const DST_BRIDGE = process.env.DST_BRIDGE_ADDRESS!!;
// Wait this many source confirmations before releasing — a reorg before this would
// otherwise pay out a lock that no longer exists. (Idempotency stops *double* pays;
// finality stops paying for a vanished lock.)
const CONFIRMATIONS = Number(process.env.SRC_CONFIRMATIONS || 12);

const srcProvider = new WebSocketProvider(process.env.SRC_WS_RPC_URL!!);
const dstProvider = new JsonRpcProvider(process.env.DST_RPC_URL!!);
const validator = new Wallet(process.env.VALIDATOR_PRIVATE_KEY!!, dstProvider);

const src = new Contract(SRC_BRIDGE, Bridge__factory.abi, srcProvider);
const dst = Bridge__factory.connect(DST_BRIDGE, validator);

console.log("relayer listening for Locked events...");

src.on("Locked", async (nonce: bigint, from: string, to: string, amount: bigint, event: any) => {
  // wait for source finality
  await event.log.getTransactionReceipt().then((r: any) => r.confirmations(CONFIRMATIONS));

  // sign the destination transferId (binds chainids + both bridges + this exact transfer)
  const id = await dst.transferId(SRC_CHAIN_ID, SRC_BRIDGE, nonce, to, amount);
  const signature = await validator.signMessage(getBytes(id));

  // idempotent: a re-delivered Locked event reverts with AlreadyReleased instead of double-paying
  try {
    const tx = await dst.release(SRC_CHAIN_ID, SRC_BRIDGE, nonce, to, amount, signature);
    await tx.wait();
    console.log(`released ${amount} to ${to} (src nonce ${nonce})`);
  } catch (e: any) {
    if (String(e?.message).includes("AlreadyReleased")) console.log(`nonce ${nonce} already released — skipping`);
    else throw e;
  }
});
