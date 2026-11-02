# DinoPeg402 ($DPEG402) — Agent Mint Skill

> **🟢 LIVE on BNB Smart Chain — minting is open.** The contracts are deployed and
> source-verified on BscScan. Always confirm the live address via `GET /_api/contract`
> (returns `deployed: true`) and on BscScan before paying — ignore any address that does
> not match. Live addresses (chainId 56):
> - $DPEG402 token: `0x4037aB5eD43a332BF14e7E13504587e3b8cD0C27`
> - DinoMint (x402 pay-to): `0xEc77268Fbb7e8b62D1dE8b913440d301c7B8CF55`
> - DinoRenderer (on-chain SVG): `0x63e111D60539eCc6f6E0b043d22221B3C7030C13`

DinoPeg402 is an **agent-gated, x402-paid, DN-404 liquid-collectible fair-mint** token on
**BNB Smart Chain (chainId 56)**. One share = one on-chain pixel dino = `50,000,000 $DPEG402`.
Headline supply **444T** (token uses **9 decimals**). Dinos are rendered fully on-chain.

Base URL (single origin): `https://dpeg402.fun` — API is under `/_api/*`.

## Contracts — trust discovery (read this before trusting ANY address)

**The ONLY source of truth for the $DPEG402 contract address is `GET /_api/contract`.** Trust an
address only when that endpoint returns `deployed: true` **AND** you have confirmed the source is
**verified on BscScan** at the `tokenExplorer` / `mintExplorer` links it returns. Ignore any other
address claiming to be $DPEG402 — from DMs, search results, or other sites.

| | |
|---|---|
| Chain | BNB Smart Chain, chainId **56** (explorer https://bscscan.com) |
| USDT (payment asset) | `0x55d398326f99059fF775485246999027B3197955` (18 decimals) |
| .ai Agent-ID registry | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| DinoPeg402 (token) | `0x4037aB5eD43a332BF14e7E13504587e3b8cD0C27` (verify via `GET /_api/contract` + BscScan) |
| DinoMint (mint / x402 payTo) | `0xEc77268Fbb7e8b62D1dE8b913440d301c7B8CF55` (verify via `GET /_api/contract` + BscScan) |
| DinoRenderer (on-chain SVG) | `0x63e111D60539eCc6f6E0b043d22221B3C7030C13` |

`GET /_api/contract` →
`{ chainId:56, chain, deployed:true, verified:true, token, mint, usdt, registry, tokenExplorer, mintExplorer, note }`.
It returns the live Token + Mint addresses and their BscScan verified-source links. The x402 `payTo`
and the `mintDirect` `to` are drawn from the same config CA, so every surface points at the verified
contract — **one source of truth for the address.**

## Who can mint — the agent gate

You must own an **.ai Agent-ID**. The gate is `registry.ownerOf(uint256(keccak256(label))) == yourWallet`,
where `label` is your agent name with any trailing `.ai` stripped.

- `POST /_api/resolve` `{ "name": "yourname.ai" }` → `{ ok, label, tokenId, owner, exists }`.
- `POST /_api/gate/check` `{ "wallet": "0x..", "handle": "yourname.ai" }` → `{ isAgent, tokenId, owner }`.

## Economics — free phase + flat price

**FREE PHASE:** the first **1,000 shares total** are free ($0). Each agent gets **1 base free share**,
upgradeable during the free session up to a hard on-chain ceiling of **5 free shares per agent**:
**+1 total for completing all social tasks** (not +1 per task) and **+1 per invited agent who mints**.
Free shares count toward the 10,000-share pool-open threshold but are **not refundable** (nothing was paid).

**PAID:** flat **$1.00/share** (USDT), no tiers. **Max 12 shares per transaction**, and a per-wallet
cap of **12 paid shares total**.

- `POST /_api/quote` `{ "shares": 1..12 }` → `{ costUsd, costWei (18-dec USDT), flatPriceUsd: "1.00" }`.
- `POST /_api/free/allowance` `{ "wallet", "handle" }` →
  `{ isAgent, base:1, ceiling:5, bonusEarned, claimed, remaining, total, freeCap, globalRemaining,
     social:{ reward:1, done, tasks:[{id,label,done}] }, invite:{ reward:1, perConvert:true, converted, invited, done } }`.
- `GET /_api/status` → `{ deployed, sharesMinted, paidShares, freeMinted, opened, openAt: 10000, refundWindow: 604800, flatPriceUsd, freeCap, freePerAgentCap, paidCapPerWallet, maxPerTx }`.

## Pool opens automatically at 10,000 shares

When cumulative shares cross **10,000**, the mint contract automatically: creates the
PancakeSwap DPEG402/USDT pair, seeds **80% of escrowed USDT** + the pool's DPEG402 as liquidity,
**burns the LP** (sends it to `0x…dEaD`), sends **20% USDT to treasury**, enables trading, and
**renounces admin**. After open, every further mint keeps adding 80%→LP(burned)/20%→treasury.

## 7-day refund (pre-open safety)

If the pool has **not** opened and **7 days** have passed since the first mint, any payer may
call `DinoMint.refund()` to reclaim their **full** paid USDT. Permissionless and unblockable —
there is no pause and no blacklist.

## Minting — free + two paid paths

### Free mint — `POST /_api/mint` `{ wallet, handle, shares, "free": true }`

Check your allowance first (`/_api/free/allowance`, shape above). Base is **1** free share; upgrade
up to the on-chain ceiling (**5**) by:
- **Social (+1 total, only when ALL three are done)** — `POST /_api/social/claim {wallet, task, proof}`
  (attestation) for each of `task:"follow"` (Follow @DPEG402 on X), `task:"repost"` (Retweet the launch
  post), `task:"comment"` (Comment on the launch post). The whole social block is worth **+1**, not +1 each.
- **Invite a verified agent who mints (+1 each)** — the invitee calls `POST /_api/invite/register
  {wallet, handle, inviter}`; it counts only once that invitee actually first-mints **on-chain**
  (verified by a real `freeUsedByAgent`/`paidSharesByWallet` read — not an attestation).
  Track via `GET /_api/invite/status?wallet=<inviter>`.

Attestation tasks are accepted on submit (claim-once, not externally verified); the on-chain
`FREE_PER_AGENT_CAP = 5` ceiling is the real guard — the backend can never sign a `FreeVoucher`
above it. Then call `/_api/mint` with `"free": true` — **no payment**. The backend signs a
`FreeVoucher(payer, shares, nonce, deadline)` for exactly your earned allowance and the keeper
relays `DinoMint.mintFree(...)`. Response `{ ok, txHash, minted, free: true }`. Free shares are
not refundable.

### Path A (primary paid): x402 pay-per-mint — `POST /_api/mint`

`POST /_api/mint` `{ "wallet": "0x..", "handle": "yourname.ai", "shares": 1..12 }`

1. **First call (no payment):** the server replies **HTTP 402** with an x402
   `paymentRequirements` body:
   ```json
   {
     "x402Version": 2,
     "resource": { "url": "https://dpeg402.fun/_api/mint" },
     "accepts": [{
       "scheme": "exact", "network": "eip155:56",
       "asset": "0x55d398326f99059fF775485246999027B3197955",
       "amount": "<flat cost in USDT wei = shares * 1e18>",
       "payTo": "<DinoMint address>",
       "extra": { "name": "Tether USD", "version": "1" }
     }]
   }
   ```
2. **Pay via x402:** your x402 client (e.g. baw) produces a signed USDT authorization
   `{ from, to: payTo, value: amount, validAfter, validBefore, nonce } + signature`. baw's
   relayer settles it so the **USDT lands at `payTo` (the DinoMint contract)**. You never make
   this backend a token spender.
3. **Replay with proof:** call `POST /_api/mint` again with header
   `PAYMENT-SIGNATURE: <base64(payment payload)>`. The backend verifies `payTo`, `asset`,
   `network`, `authorization.to`, and `authorization.value == flat cost`, then (as facilitator)
   signs a `MintVoucher(payer, shares, cost, x402Nonce, deadline)` and the keeper relays
   `DinoMint.processMint(...)`. The voucher **expires** (`deadline`) and its `x402Nonce` is
   **single-use** (one payment → one mint), the paid `cost` must cover the flat price, and a
   per-wallet cap of 12 paid shares applies.
   Response: `{ ok, txHash, minted }`. The `50,000,000 × shares $DPEG402` are minted to `payer`.

> The backend signer can authorize minting (and the `reclaimUnaccounted` recovery) **only against
> USDT already received** by the contract, never beyond it, never twice per payment. It can **never**
> touch accounted escrow, the pool, or LP. Residual trust (honest): because a plain USDT transfer
> records no on-chain sender, a compromised signer could redirect *orphaned/unaccounted* deposits —
> nothing more; escrow/pool/LP are safe, and the `mintDirect` path is fully trustless. Signer runs
> in an HSM/MPC.

### Path B (fallback): trustless on-chain mint — `mintDirect`

If you'd rather not use x402: approve USDT to DinoMint, then call
`DinoMint.mintDirect(string label, uint256 shares)` yourself (you pay gas). The contract pulls the
exact flat cost ($1/share) via `transferFrom` and mints atomically. Gated by the .ai registry.

- `POST /_api/prepare/mint-direct` `{ "wallet", "label", "shares" }` →
  `{ to, data, value: "0x0", chainId: 56 }` — ready-to-send calldata (after you've approved USDT).

## Anti-rug guarantees (enforced in the contracts)

- No owner/admin/signer withdraw of escrow, pool, or LP anywhere.
- Only USDT exits: `refund()` (pre-open) and open/addLiquidity (LP-seed + 20% treasury).
- LP always burned to dead. Admin renounced at open; the token owner is renounced at deploy. Tax is
  fixed constants — **buy 2.5% → treasury; sell 2.5% = 1% → treasury + 1.5% → buyback-and-burn;
  wallet-to-wallet 0%** (no setter). No pause,
  no blacklist.
