# DinoPeg402 ($DPEG402)

An agent-gated, **x402-paid**, DN-404 liquid-collectible fair-mint token on **BNB Smart Chain**
(chainId 56). An agent pays 1 USDT over x402 and mints `$DPEG402` plus a dino rendered 100%
on-chain. Fair launch, un-ruggable, and verifiable end-to-end.

> **Live on BNB Smart Chain (chainId 56), source-verified on BscScan:**
> - `$DPEG402` token — [`0x4037aB5eD43a332BF14e7E13504587e3b8cD0C27`](https://bscscan.com/address/0x4037aB5eD43a332BF14e7E13504587e3b8cD0C27)
> - `DinoMint` (x402 pay-to) — [`0xEc77268Fbb7e8b62D1dE8b913440d301c7B8CF55`](https://bscscan.com/address/0xEc77268Fbb7e8b62D1dE8b913440d301c7B8CF55)
> - `DinoRenderer` (on-chain SVG) — [`0x63e111D60539eCc6f6E0b043d22221B3C7030C13`](https://bscscan.com/address/0x63e111D60539eCc6f6E0b043d22221B3C7030C13)
>
> The canonical source of truth is `GET /_api/contract` (returns `deployed: true` + these addresses).
> Always confirm an address there and on BscScan before trusting or minting.

---

## Links

- Site: https://dpeg402.fun
- X: https://x.com/DPEG402
- Verified source on BscScan: [token](https://bscscan.com/address/0x4037aB5eD43a332BF14e7E13504587e3b8cD0C27#code) · [mint](https://bscscan.com/address/0xEc77268Fbb7e8b62D1dE8b913440d301c7B8CF55#code) · [renderer](https://bscscan.com/address/0x63e111D60539eCc6f6E0b043d22221B3C7030C13#code)

## How x402 works (read this first)

[x402](https://www.x402.org/) turns HTTP's long-dormant **`402 Payment Required`** status into a
real payment handshake, so an agent can pay for a resource with a single signed message — no
account, no API key, no gas.

For DinoPeg402, minting one or more shares is the "paid resource":

1. **Ask.** The agent calls `POST /_api/mint { wallet, handle, shares }`.
2. **402.** With no payment attached, the server replies **HTTP 402** with
   `paymentRequirements.accepts[]`:
   `{ scheme: "exact", network: "eip155:56", asset: <USDT>, maxAmountRequired: <shares × 1 USDT>,
   payTo: <DinoMint contract> }`.
3. **Sign one gasless authorization.** The agent's wallet signs a single USDT transfer
   authorization to `payTo`. No gas is spent by the agent to sign.
4. **Settle to the contract.** A facilitator/relayer submits the authorization; the **USDT lands
   directly in the DinoMint contract** — never an intermediary or a custodial spender.
5. **Mint fires.** The backend presents a one-time, expiring EIP-712 voucher and the keeper relays
   the on-chain mint; `50,000,000 $DPEG402` and one on-chain dino are minted to the agent per share.

A fully trustless alternative (`mintDirect`) skips x402: the agent approves USDT and mints in one
transaction, gated by its `.ai` Agent-ID.

### Verify the 402 is real, on-chain (anti-spoof)

Before paying, an agent can confirm the HTTP-402 it received matches the actual contract by reading
these gas-light views on **DinoMint**:

| View | Returns |
|---|---|
| `supportsX402()` | `true` |
| `x402PayTo()` | the DinoMint address (USDT recipient — never an intermediary) |
| `x402Asset()` | USDT token address |
| `x402ChainId()` | `56` |
| `x402Network()` | `"bsc"` |
| `x402Scheme()` | `"exact"` |
| `x402PricePerShare()` | `1e18` (1 USDT, 18-dec) |
| `x402VoucherTypehash()` | the EIP-712 mint-voucher typehash |
| `x402Domain()` | `("DinoMint", "1")` — EIP-712 domain name/version |
| `x402PaymentInfo()` | `(payTo, asset, chainId, scheme, pricePerShare)` in one call |

Cross-check: `accepts[].payTo == x402PayTo()`, `accepts[].asset == x402Asset()`,
`network/chainId` match, and `maxAmountRequired == shares × x402PricePerShare()`. If any differ, the
402 is spoofed — don't pay.

---

## Economics

- **Free phase:** the first **1,000 shares** are free — base **1 per agent**, upgradeable during the
  free session via social tasks + inviting a verified agent who mints, up to an on-chain ceiling of
  **5 per agent**.
- **Paid:** flat **$1.00 / share** (USDT), no tiers. Max **12 shares per transaction**, **12 paid
  shares per wallet**.
- Each share mints **50,000,000 $DPEG402** and one dino (DN-404: holding one unit carries one NFT,
  rendered fully on-chain as SVG — no IPFS, no server, no image files).
- **Pool opens automatically at 10,000 cumulative shares:** 80% of paid USDT + the pool's $DPEG402
  seed a PancakeSwap DPEG402/USDT pool, the **LP is burned** to the dead address, 20% USDT goes to
  the treasury, trading is enabled, and admin is renounced.
- **7-day refund:** if the pool has not opened within 7 days of the first mint, every paid minter
  can reclaim **100%** of their USDT. Permissionless and unblockable.

## Trading tax (fixed constants, no setter)

- **Buy:** 2.5% → treasury.
- **Sell:** 2.5% = 1% → treasury + 1.5% → **buyback-and-burn**.
- **Wallet-to-wallet:** 0%.

Tax routes through the DPEG402/USDT pool: the treasury slice is swapped to USDT and sent to the
treasury; the buyback slice performs a real market buy of $DPEG402 and burns it (falling back to a
direct burn if no pool/quote is available — never a zero-slippage-floor swap). Both paths are
permissionless, throttled, slippage-guarded, and capped at 0.1% of pool reserve per call.

## Anti-rug guarantees (enforced in code, not promised)

- No owner/admin/signer withdraw of escrow, pool, or LP. The only USDT exits are `refund()`
  (pre-open), the open/addLiquidity seed (LP → dead + 20% → treasury), and a recovery path that can
  move **only unaccounted** USDT (never accounted escrow / pool / LP).
- LP is always burned to the dead address.
- The token owner is renounced at deploy; the mint admin is renounced at pool open.
- Tax is immutable constants. No blacklist. No pause. The pool-open seed uses a griefing-proof
  direct `pair.mint` path, so a pre-open pair donation cannot brick the launch.

---

## Repository layout

```
contracts/      Solidity sources (DinoPeg402, DinoMint, DinoRenderer, DinoTraitData, Interfaces)
script/         Foundry deploy script (Deploy.s.sol)
foundry.toml    Foundry config (solc 0.8.24, optimizer, via-ir)
api/            Single-origin backend (app.py), on-chain mint indexer (indexer.py), config
skill/          Agent-facing skill (skill.md)
```

## Build & test

```bash
forge install Vectorized/solady Vectorized/dn404 OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge build
forge test            # unit suite + a BNB-fork backtest
```

## Deploy

Keys are read from the environment at deploy time and are never committed. See `script/Deploy.s.sol`
for the exact env it expects (`DEPLOYER_PK`, `TREASURY`, and `BACKEND_SIGNER_PK` or `BACKEND_SIGNER`).

```bash
export DEPLOYER_PK=$(cat ./secrets/deployer.key)
export BACKEND_SIGNER_PK=$(cat ./secrets/signer.key)
export TREASURY=0x... BACKEND_SIGNER=0x...
forge script script/Deploy.s.sol --rpc-url "$BSC_RPC"            # dry-run
forge script script/Deploy.s.sol --rpc-url "$BSC_RPC" --broadcast
```

## How an agent mints

1. Check eligibility: `POST /_api/gate/check { wallet, handle }` (owns an `.ai` Agent-ID).
2. Free allowance: `POST /_api/free/allowance { wallet, handle }`; free mint via
   `POST /_api/mint { wallet, handle, shares, "free": true }`.
3. Paid via x402: `POST /_api/mint { wallet, handle, shares }` → 402 → sign the USDT authorization →
   replay with the `PAYMENT-SIGNATURE` header. Or go trustless with
   `POST /_api/prepare/mint-direct { wallet, label, shares }` and send the returned calldata.
4. Track it: `GET /_api/status`, `GET /_api/collection?wallet=`, `GET /_api/refund/status?wallet=`.

## License

MIT — see [LICENSE](LICENSE).
