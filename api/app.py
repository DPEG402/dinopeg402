#!/usr/bin/env python3
"""
DinoPeg402 backend — Flask, bound to 127.0.0.1:8265.

Fronted by web/serve.py (single-origin, :8264) which reverse-proxies /_api/* here.

Secret hygiene: signer / keeper keys are NEVER hardcoded or logged. They are read
only at call-time inside a subprocess via $(cat <chmod600-file>) and passed to
`cast` on its stdin-equivalent argv WITHOUT this process ever holding the plaintext
in a logged variable. Pre-deploy, the mint path is fail-closed (503) so keys are
not even required yet.
"""

import base64
import json
import os
import secrets
import sqlite3
import subprocess
import time
from flask import Flask, request, jsonify, Response

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")

# chmod600 key files (NOT present pre-deploy — the mint path is 503-gated until then).
# Key file locations come from env; defaults are a local, git-ignored ./secrets dir. The keys
# themselves are NEVER committed, hardcoded, or logged — only read at call time inside a subprocess.
SIGNER_KEY_FILE = os.environ.get("DPEG_SIGNER_KEY_FILE", "./secrets/signer.key")  # EIP-712 voucher signer
KEEPER_KEY_FILE = os.environ.get("DPEG_KEEPER_KEY_FILE", "./secrets/keeper.key")  # pays gas for mint relays

app = Flask(__name__)

# ---- economics: free phase + flat price (must mirror DinoMint exactly) ----
FLAT_PRICE_WEI = 10 ** 18       # $1.00/share (USDT 18-dec)
FREE_CAP = 1_000                # total free shares (global)
FREE_PER_AGENT_CAP = 5          # per-agent free HARD CEILING (on-chain guard in mintFree)
FREE_BASE = 1                   # base free allowance per agent (default)
PAID_CAP_PER_WALLET = 12        # paid shares per wallet
MAX_PER_TX = 12
MAX_SHARES = 4_440_000
OPEN_AT = 10_000
REFUND_WINDOW = 7 * 24 * 60 * 60  # 604800
VOUCHER_TTL = 15 * 60           # 15 min signed-voucher lifetime

# Social-task ladder: base 1 -> up to the FREE_PER_AGENT_CAP ceiling. Each task grants +1.
# follow/repost/telegram are attestation-based (proof URL, claim-once, NOT externally verified);
# invite is verified on-chain (the invited agent must actually first-mint). The on-chain ceiling is
# the real guard — the backend can never sign a FreeVoucher above it.
SOCIAL_TASKS = [
    {"id": "follow", "label": "Follow @DinoPeg402 on X", "reward": 1, "kind": "attest"},
    {"id": "repost", "label": "Repost the launch post", "reward": 1, "kind": "attest"},
    {"id": "telegram", "label": "Join the DinoPeg402 Telegram", "reward": 1, "kind": "attest"},
    {"id": "invite", "label": "Invite a verified agent who mints", "reward": 1, "kind": "onchain"},
]
STATE_DB = os.path.join(HERE, "dpeg_state.db")


def load_config():
    with open(CONFIG_PATH) as f:
        cfg = dict(json.load(f))
    # deployed is true only when both addresses are set AND the flag says so.
    cfg["deployed"] = bool(cfg.get("deployed")) and bool(cfg.get("mintAddr")) and bool(cfg.get("tokenAddr"))
    return cfg


def flat_cost_wei(shares):
    """Flat cost to mint `shares` PAID shares: shares * $1.00 (USDT 18-dec wei)."""
    return shares * FLAT_PRICE_WEI


# ---------------------------------------------------------------------------
# cast helpers (subprocess — reliable RPC, no python urllib for chain reads)
# ---------------------------------------------------------------------------

def _cast(args, timeout=25):
    """Run `cast <args>`; return (ok, stdout_stripped, stderr_stripped)."""
    try:
        p = subprocess.run(
            ["cast", *args],
            capture_output=True, text=True, timeout=timeout,
        )
        return (p.returncode == 0, p.stdout.strip(), p.stderr.strip())
    except Exception as e:  # noqa: BLE001
        return (False, "", str(e))


def cast_call(cfg, to, sig, *call_args):
    ok, out, err = _cast(["call", to, sig, *[str(a) for a in call_args], "--rpc-url", cfg["rpc"]])
    return ok, out, err


def label_from_name(name):
    """Normalize an agent name to its registry label (strip a trailing .ai)."""
    label = (name or "").strip()
    if label.lower().endswith(".ai"):
        label = label[:-3]
    return label


def token_id_of(label):
    """uint256(keccak256(bytes(label))) as a decimal string (matches the contract)."""
    ok, out, _ = _cast(["keccak", label])
    if not ok or not out.startswith("0x"):
        return None
    ok2, dec, _ = _cast(["to-dec", out])
    return dec if ok2 else None


def registry_owner_of(cfg, token_id_dec):
    ok, out, err = cast_call(cfg, cfg["registry"], "ownerOf(uint256)(address)", token_id_dec)
    if not ok:
        return None  # reverts when the id is unregistered
    return out.split()[0] if out else None


ZERO = "0x0000000000000000000000000000000000000000"


# ---------------------------------------------------------------------------
# CORS
# ---------------------------------------------------------------------------

@app.after_request
def cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type, PAYMENT-SIGNATURE, X-PAYMENT"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    return resp


@app.route("/<path:_any>", methods=["OPTIONS"])
@app.route("/", methods=["OPTIONS"])
def options(_any=None):
    return ("", 204)


def body():
    return request.get_json(force=True, silent=True) or {}


# ---------------------------------------------------------------------------
# read-only endpoints (LIVE pre-deploy)
# ---------------------------------------------------------------------------

def _token_explorer(cfg):
    return f"{cfg['explorer']}/token/{cfg['tokenAddr']}" if cfg.get("tokenAddr") else ""


def _mint_explorer(cfg):
    return f"{cfg['explorer']}/address/{cfg['mintAddr']}" if cfg.get("mintAddr") else ""


@app.get("/health")
def health():
    return jsonify(ok=True, service="dpeg-api")


@app.get("/config")
def config():
    cfg = load_config()
    return jsonify(
        chainId=cfg["chainId"], chainName=cfg["chainName"], rpc=cfg["rpc"],
        explorer=cfg["explorer"], usdt=cfg["usdt"], registry=cfg["registry"],
        mintAddr=cfg["mintAddr"], tokenAddr=cfg["tokenAddr"], signer=cfg["signer"],
        deployed=cfg["deployed"],
        tokenExplorer=_token_explorer(cfg), mintExplorer=_mint_explorer(cfg),
    )


@app.get("/contract")
def contract():
    """Canonical trusted-contract manifest. The ONE source of truth for the $DPEG402 address.
       Everything is config-driven: set tokenAddr/mintAddr + deployed=true in config.json at deploy
       and every surface (this endpoint, /config, /api/status, x402 payTo) points at the real CA."""
    cfg = load_config()
    if cfg["deployed"]:
        note = ("VERIFIED. Trust this address only after confirming the source is verified on "
                "BscScan at the links below.")
    else:
        note = ("DinoPeg402 is PRE-LAUNCH. No contract is deployed yet. Do NOT trust any address "
                "claiming to be $DPEG402 until this endpoint returns deployed=true with a "
                "BscScan-verified address.")
    return jsonify(
        chainId=cfg["chainId"],
        chain=cfg["chainName"],
        deployed=cfg["deployed"],
        verified=cfg["deployed"],
        token=cfg["tokenAddr"],
        mint=cfg["mintAddr"],
        usdt=cfg["usdt"],
        registry=cfg["registry"],
        tokenExplorer=_token_explorer(cfg),
        mintExplorer=_mint_explorer(cfg),
        note=note,
    )


@app.post("/resolve")
def resolve():
    cfg = load_config()
    name = body().get("name", "")
    label = label_from_name(name)
    if not label:
        return jsonify(ok=False, error="empty name"), 400
    tid = token_id_of(label)
    if tid is None:
        return jsonify(ok=False, error="hash failed"), 500
    owner = registry_owner_of(cfg, tid)
    exists = owner is not None and owner.lower() != ZERO
    return jsonify(ok=True, name=name, label=label, tokenId=tid,
                   owner=(owner if exists else None), exists=exists)


@app.post("/gate/check")
def gate_check():
    cfg = load_config()
    data = body()
    wallet = (data.get("wallet") or "").strip()
    handle = data.get("handle", "")
    label = label_from_name(handle)
    tid = token_id_of(label)
    if tid is None:
        return jsonify(ok=False, error="hash failed"), 500
    owner = registry_owner_of(cfg, tid)
    is_agent = bool(wallet) and owner is not None and owner.lower() == wallet.lower()
    return jsonify(ok=True, isAgent=is_agent, tokenId=tid,
                   owner=(owner if (owner and owner.lower() != ZERO) else None))


def _normalize_shares(raw):
    try:
        shares = int(raw)
    except (TypeError, ValueError):
        return None
    if shares < 1 or shares > 10:
        return None
    return shares


@app.post("/quote")
def quote():
    cfg = load_config()
    shares = _normalize_shares(body().get("shares"))
    if shares is None:
        return jsonify(ok=False, error="shares must be 1..10"), 400

    # Flat price: every paid share is $1.00. (Free shares are handled via /free/allowance.)
    wei = flat_cost_wei(shares)
    return jsonify(
        ok=True,
        shares=shares,
        costUsd=f"{shares:.2f}",               # $1.00 * shares
        costWei=str(wei),                      # raw 18-dec USDT wei
        flatPriceUsd="1.00",
        flatPriceWei=str(FLAT_PRICE_WEI),
    )


def _read_uint(cfg, sig, *args):
    ok, out, _ = cast_call(cfg, cfg["mintAddr"], sig, *args)
    if not ok or not out:
        return 0
    try:
        return int(out.split()[0])
    except ValueError:
        return 0


def _read_shares_minted(cfg):
    if not cfg["deployed"]:
        return 0
    return _read_uint(cfg, "sharesMinted()(uint256)")


@app.post("/free/allowance")
def free_allowance():
    """Free-phase allowance: base 1/agent, upgradeable via social tasks + invite up to the on-chain
       FREE_PER_AGENT_CAP ceiling. Returns the task ladder and what's still claimable."""
    cfg = load_config()
    data = body()
    wallet = (data.get("wallet") or "").strip()
    handle = data.get("handle", "")
    label = label_from_name(handle)
    tid = token_id_of(label)
    owner = registry_owner_of(cfg, tid) if tid is not None else None
    is_agent = bool(wallet) and owner is not None and owner.lower() == wallet.lower()

    tasks, bonus = _social_state(cfg, wallet)
    total = min(FREE_BASE + bonus, FREE_PER_AGENT_CAP)
    free_minted = _read_uint(cfg, "freeMinted()(uint256)") if cfg["deployed"] else 0
    used = _read_uint(cfg, "freeUsedByAgent(address)(uint256)", wallet) if (cfg["deployed"] and wallet) else 0
    global_left = max(0, FREE_CAP - free_minted) if cfg["deployed"] else FREE_CAP
    remaining = 0
    if is_agent:
        remaining = min(max(0, total - used), global_left)
    return jsonify(
        ok=True, deployed=cfg["deployed"], isAgent=is_agent,
        base=FREE_BASE, bonusEarned=bonus, tasks=tasks, total=total,
        claimed=used, remaining=remaining, ceiling=FREE_PER_AGENT_CAP,
        freeMinted=free_minted, freeCap=FREE_CAP, globalRemaining=global_left,
    )


def _fmt_usdt(wei):
    """USDT wei (18-dec) -> human string with 2 decimals (real value, no fabrication)."""
    whole = wei // (10 ** 18)
    cents = (wei % (10 ** 18)) // (10 ** 16)
    return f"{whole}.{cents:02d}"


@app.get("/refund/status")
def refund_status():
    """Refund eligibility for a paid minter. ?wallet= or ?handle= (resolves via the registry).
       refundableNow = !opened AND now >= firstMintTime+refundWindow AND paidUsdt>0."""
    cfg = load_config()
    wallet = (request.args.get("wallet") or "").strip()
    handle = request.args.get("handle") or ""
    resolved_handle = None
    if not wallet and handle:
        label = label_from_name(handle)
        tid = token_id_of(label)
        owner = registry_owner_of(cfg, tid) if tid is not None else None
        if owner and owner.lower() != ZERO:
            wallet = owner
            resolved_handle = handle

    if not cfg["deployed"]:
        return jsonify(deployed=False, wallet=wallet, handle=resolved_handle, paidUsdt="0",
                       refundableNow=False, opened=False, firstMintTime=0, windowEnd=0)

    opened_ok, opened_out, _ = cast_call(cfg, cfg["mintAddr"], "opened()(bool)")
    opened = opened_ok and opened_out.strip().lower().startswith("true")
    first_mint = _read_uint(cfg, "firstMintTime()(uint256)")
    paid_wei = _read_uint(cfg, "paidUsdt(address)(uint256)", wallet) if wallet else 0
    window_end = (first_mint + REFUND_WINDOW) if first_mint > 0 else 0
    refundable = (not opened) and paid_wei > 0 and first_mint > 0 and _now() >= window_end
    return jsonify(
        deployed=True, wallet=wallet, handle=resolved_handle,
        paidUsdt=_fmt_usdt(paid_wei), paidUsdtWei=str(paid_wei),
        refundableNow=bool(refundable), opened=opened,
        firstMintTime=first_mint, windowEnd=window_end, refundWindow=REFUND_WINDOW,
    )


@app.get("/api/status")
@app.get("/status")  # alias so the single-origin /_api/status path resolves
def status():
    cfg = load_config()
    base = dict(
        openAt=OPEN_AT, refundWindow=REFUND_WINDOW,
        flatPriceUsd="1.00", flatPriceWei=str(FLAT_PRICE_WEI),
        freeCap=FREE_CAP, freePerAgentCap=FREE_PER_AGENT_CAP,
        paidCapPerWallet=PAID_CAP_PER_WALLET, maxPerTx=MAX_PER_TX, priceUsd="1.00",
    )
    if not cfg["deployed"]:
        # pre-launch: real-or-empty — zeros, never fabricated. (site countdown stays hidden since
        # firstMintTime==0.)
        return jsonify(deployed=False, sharesMinted=0, firstMintTime=0, opened=False,
                       freeMinted=0, paidShares=0, tokenExplorer="", mintExplorer="", **base)
    shares = _read_shares_minted(cfg)
    free_minted = _read_uint(cfg, "freeMinted()(uint256)")
    paid_shares = _read_uint(cfg, "paidShares()(uint256)")
    ok_o, opened_out, _ = cast_call(cfg, cfg["mintAddr"], "opened()(bool)")
    first_mint = _read_uint(cfg, "firstMintTime()(uint256)")
    opened = ok_o and opened_out.strip().lower().startswith("true")
    return jsonify(
        deployed=True, sharesMinted=shares, paidShares=paid_shares,
        freeMinted=free_minted, opened=opened, firstMintTime=first_mint,
        token=cfg["tokenAddr"], mint=cfg["mintAddr"],
        tokenExplorer=_token_explorer(cfg), mintExplorer=_mint_explorer(cfg), **base,
    )


# ---------------------------------------------------------------------------
# x402 MINT (fail-closed until deployed)
# ---------------------------------------------------------------------------

def _payment_requirements(cfg, resource_url, cost_wei):
    return {
        "x402Version": 2,
        "resource": {"url": resource_url},
        "accepts": [{
            "scheme": "exact",
            "network": "eip155:56",
            "asset": cfg["usdt"],
            "amount": str(cost_wei),
            "payTo": cfg["mintAddr"],
            "extra": {"name": "Tether USD", "version": "1"},
        }],
    }


@app.post("/api/mint")
@app.post("/mint")  # alias so the single-origin /_api/mint path resolves
def api_mint():
    cfg = load_config()
    # LAUNCH GATE — fail-closed.
    if not cfg["deployed"]:
        return jsonify(error="mint not live yet"), 503

    data = body()
    shares = _normalize_shares(data.get("shares"))
    if shares is None:
        return jsonify(error="shares must be 1..10"), 400

    start = _read_shares_minted(cfg)
    if start + shares > MAX_SHARES:
        return jsonify(error="exceeds max shares"), 400

    # FREE path: no x402 payment. Backend checks agent eligibility + caps, signs a FREE voucher,
    # keeper relays mintFree. (The off-chain "1 base + invite/social bonus" logic lives here; the
    # contract only enforces the hard FREE_CAP / FREE_PER_AGENT_CAP bounds.)
    if data.get("free") is True:
        return _free_mint(cfg, data, shares)

    cost_wei = flat_cost_wei(shares)  # flat $1/share

    pay_sig = request.headers.get("PAYMENT-SIGNATURE") or request.headers.get("X-PAYMENT")

    # Step 1: no payment yet -> HTTP 402 with x402 paymentRequirements.
    if not pay_sig:
        reqs = _payment_requirements(cfg, "https://dpeg402.fun/_api/mint", cost_wei)
        return Response(json.dumps(reqs), status=402, mimetype="application/json")

    # Step 2: PAYMENT-SIGNATURE present -> validate the x402 authorization.
    try:
        payload = json.loads(base64.b64decode(pay_sig).decode("utf-8"))
    except Exception:  # noqa: BLE001
        return jsonify(error="bad PAYMENT-SIGNATURE encoding"), 400

    accepted = payload.get("accepted") or payload.get("accept") or {}
    auth = (payload.get("authorization")
            or (payload.get("payload") or {}).get("authorization") or {})

    def eq(a, b):
        return str(a).lower() == str(b).lower()

    if not eq(accepted.get("payTo"), cfg["mintAddr"]):
        return jsonify(error="payTo mismatch"), 400
    if not eq(accepted.get("asset"), cfg["usdt"]):
        return jsonify(error="asset mismatch"), 400
    if accepted.get("network") != "eip155:56":
        return jsonify(error="network mismatch"), 400
    if not eq(auth.get("to"), cfg["mintAddr"]):
        return jsonify(error="authorization.to mismatch"), 400
    if str(auth.get("value")) != str(cost_wei):
        return jsonify(error="authorization.value != flat cost"), 400

    payer = auth.get("from")
    x402_nonce = auth.get("nonce")  # EIP-3009 nonce (bytes32 hex) — single-use voucher binding
    deadline = auth.get("validBefore")  # voucher expiry = authorization validBefore (unix secs)
    if not payer or x402_nonce is None or deadline is None:
        return jsonify(error="missing from/nonce/validBefore"), 400
    x402_nonce = _as_bytes32(x402_nonce)
    if x402_nonce is None:
        return jsonify(error="bad x402 nonce"), 400

    # The signed USDT authorization is settled by baw's relayer -> USDT lands at payTo (mintAddr).
    # We (facilitator) sign a MintVoucher bound to (payer, shares, cost, x402Nonce, deadline) and
    # the keeper relays processMint. The voucher can only mint against received USDT (anti-rug).
    digest = _voucher_digest(cfg, payer, shares, cost_wei, x402_nonce, deadline)
    if digest is None:
        return jsonify(error="could not compute voucher digest"), 502
    sig = _sign_no_hash(digest)        # signer.key, never logged
    if sig is None:
        return jsonify(error="signer unavailable"), 500
    tx_ok, tx_hash, tx_err = _send_process_mint(
        cfg, payer, shares, cost_wei, x402_nonce, deadline, sig
    )
    if not tx_ok:
        return jsonify(error="processMint failed", detail=_scrub(tx_err)), 502
    return jsonify(ok=True, txHash=tx_hash, minted=shares, payer=payer)


@app.post("/prepare/mint-direct")
def prepare_mint_direct():
    """Return calldata for the trustless fallback mintDirect(label, shares)."""
    cfg = load_config()
    if not cfg["deployed"]:
        return jsonify(error="mint not live yet"), 503
    data = body()
    shares = _normalize_shares(data.get("shares"))
    if shares is None:
        return jsonify(error="shares must be 1..10"), 400
    label = label_from_name(data.get("label") or data.get("handle") or "")
    if not label:
        return jsonify(error="missing label"), 400
    ok, calldata, err = _cast(["calldata", "mintDirect(string,uint256)", label, str(shares)])
    if not ok:
        return jsonify(error="calldata encode failed", detail=_scrub(err)), 500
    return jsonify(ok=True, to=cfg["mintAddr"], data=calldata, value="0x0", chainId=56)


def _free_mint(cfg, data, shares):
    """FREE-phase mint: verify agent, compute the earned allowance (base + social/invite bonus,
       clamped to the on-chain ceiling), sign a FREE voucher for exactly `shares`, keeper relays."""
    wallet = (data.get("wallet") or "").strip()
    handle = data.get("handle", "")
    if shares > MAX_PER_TX:
        return jsonify(error="shares > max per tx"), 400

    # agent eligibility (registry)
    label = label_from_name(handle)
    tid = token_id_of(label)
    owner = registry_owner_of(cfg, tid) if tid is not None else None
    if not (wallet and owner and owner.lower() == wallet.lower()):
        return jsonify(error="not an agent"), 403

    # earned allowance = base + completed tasks, clamped to the hard ceiling; minus already claimed.
    _, bonus = _social_state(cfg, wallet)
    total = min(FREE_BASE + bonus, FREE_PER_AGENT_CAP)
    free_minted = _read_uint(cfg, "freeMinted()(uint256)")
    used = _read_uint(cfg, "freeUsedByAgent(address)(uint256)", wallet)
    if free_minted + shares > FREE_CAP:
        return jsonify(error="global free cap reached"), 409
    if used + shares > total:
        return jsonify(error="exceeds earned free allowance — complete tasks to upgrade"), 409
    if used + shares > FREE_PER_AGENT_CAP:  # defensive; contract enforces the ceiling too
        return jsonify(error="per-agent free ceiling reached"), 409

    nonce = "0x" + secrets.token_hex(32)
    deadline = _now() + VOUCHER_TTL
    digest = _free_voucher_digest(cfg, wallet, shares, nonce, deadline)
    if digest is None:
        return jsonify(error="could not compute free voucher digest"), 502
    sig = _sign_no_hash(digest)  # signer.key, never logged
    if sig is None:
        return jsonify(error="signer unavailable"), 500
    tx_ok, tx_hash, tx_err = _send_free_mint(cfg, wallet, shares, nonce, deadline, sig)
    if not tx_ok:
        return jsonify(error="mintFree failed", detail=_scrub(tx_err)), 502
    return jsonify(ok=True, txHash=tx_hash, minted=shares, payer=wallet, free=True)


def _now():
    import time
    return int(time.time())


# ---------------------------------------------------------------------------
# signing / sending (keys read via $(cat file) inside subprocess; never logged)
# ---------------------------------------------------------------------------

def _to_uint(v):
    s = str(v)
    if s.startswith("0x"):
        ok, dec, _ = _cast(["to-dec", s])
        return dec if ok else s
    return s


def _as_bytes32(v):
    """Normalize an x402 nonce to a 0x-prefixed 32-byte hex string."""
    s = str(v).strip()
    if s.startswith("0x"):
        h = s[2:]
    elif s.isdigit():
        h = format(int(s), "064x")
    else:
        return None
    if len(h) > 64:
        return None
    return "0x" + h.rjust(64, "0")


def _voucher_digest(cfg, payer, shares, cost_wei, x402_nonce, deadline):
    ok, out, _ = cast_call(
        cfg, cfg["mintAddr"],
        "voucherDigest(address,uint256,uint256,bytes32,uint256)(bytes32)",
        payer, str(shares), str(cost_wei), x402_nonce, str(deadline),
    )
    if not ok or not out.startswith("0x"):
        return None
    return out.split()[0]


def _free_voucher_digest(cfg, payer, shares, nonce, deadline):
    ok, out, _ = cast_call(
        cfg, cfg["mintAddr"],
        "freeVoucherDigest(address,uint256,bytes32,uint256)(bytes32)",
        payer, str(shares), nonce, str(deadline),
    )
    if not ok or not out.startswith("0x"):
        return None
    return out.split()[0]


def _sh(cmd):
    """Run a bash -c command so $(cat keyfile) expands in the shell, not in python.
       The key is never assigned to a python variable and never logged."""
    try:
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=60)
        return (p.returncode == 0, p.stdout.strip(), p.stderr.strip())
    except Exception as e:  # noqa: BLE001
        return (False, "", str(e))


def _sign_no_hash(digest):
    if not os.path.exists(SIGNER_KEY_FILE):
        return None
    ok, out, _ = _sh(
        f'cast wallet sign --no-hash --private-key "$(cat {SIGNER_KEY_FILE})" {digest}'
    )
    return out if (ok and out.startswith("0x")) else None


def _send_process_mint(cfg, payer, shares, cost_wei, x402_nonce, deadline, sig):
    if not os.path.exists(KEEPER_KEY_FILE):
        return (False, "", "keeper key not set")
    cmd = (
        f'cast send {cfg["mintAddr"]} '
        f'"processMint(address,uint256,uint256,bytes32,uint256,bytes)" '
        f'{payer} {shares} {cost_wei} {x402_nonce} {deadline} {sig} '
        f'--private-key "$(cat {KEEPER_KEY_FILE})" '
        f'--rpc-url {cfg["rpc"]} --json'
    )
    ok, out, err = _sh(cmd)
    if not ok:
        return (False, "", err)
    try:
        return (True, json.loads(out).get("transactionHash", out), "")
    except Exception:  # noqa: BLE001
        return (True, out, "")


def _send_free_mint(cfg, payer, shares, nonce, deadline, sig):
    if not os.path.exists(KEEPER_KEY_FILE):
        return (False, "", "keeper key not set")
    cmd = (
        f'cast send {cfg["mintAddr"]} '
        f'"mintFree(address,uint256,bytes32,uint256,bytes)" '
        f'{payer} {shares} {nonce} {deadline} {sig} '
        f'--private-key "$(cat {KEEPER_KEY_FILE})" '
        f'--rpc-url {cfg["rpc"]} --json'
    )
    ok, out, err = _sh(cmd)
    if not ok:
        return (False, "", err)
    try:
        return (True, json.loads(out).get("transactionHash", out), "")
    except Exception:  # noqa: BLE001
        return (True, out, "")


def _scrub(text):
    """Never surface anything that could contain key material."""
    if not text:
        return ""
    return "cast error (redacted)"


# ---------------------------------------------------------------------------
# free-upgrade engine: social-task attestations + on-chain-verified invites
#   base free = 1 per agent; each completed task grants +1, clamped to the
#   on-chain FREE_PER_AGENT_CAP ceiling (the real guard lives in the contract).
# ---------------------------------------------------------------------------

def _state_db():
    conn = sqlite3.connect(STATE_DB, timeout=10)
    conn.execute("""CREATE TABLE IF NOT EXISTS social_claims (
        wallet TEXT NOT NULL, task TEXT NOT NULL, proof TEXT, created REAL,
        PRIMARY KEY (wallet, task))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS invites (
        invitee TEXT PRIMARY KEY,      -- each agent can be referred by at most one inviter
        inviter TEXT NOT NULL,
        created REAL)""")
    conn.commit()
    return conn


def _norm(addr):
    return (addr or "").strip().lower()


def _social_attest(wallet, task, proof):
    """Record an attestation submission for (wallet, task). Claim-once; idempotent."""
    with _state_db() as c:
        cur = c.execute(
            "INSERT OR IGNORE INTO social_claims (wallet, task, proof, created) VALUES (?,?,?,?)",
            (_norm(wallet), task, (proof or "")[:400], time.time()))
        c.commit()
        return cur.rowcount > 0


def _social_has(wallet, task):
    with _state_db() as c:
        return c.execute("SELECT 1 FROM social_claims WHERE wallet=? AND task=?",
                         (_norm(wallet), task)).fetchone() is not None


def _invite_register(invitee, inviter):
    """invitee was referred by inviter. First writer wins; self-referral ignored."""
    if _norm(invitee) == _norm(inviter) or not _norm(invitee) or not _norm(inviter):
        return False
    with _state_db() as c:
        cur = c.execute(
            "INSERT OR IGNORE INTO invites (invitee, inviter, created) VALUES (?,?,?)",
            (_norm(invitee), _norm(inviter), time.time()))
        c.commit()
        return cur.rowcount > 0


def _invitees(inviter):
    with _state_db() as c:
        return [r[0] for r in c.execute("SELECT invitee FROM invites WHERE inviter=?",
                                        (_norm(inviter),)).fetchall()]


_CONVERTED = {}  # invitee wallet -> True once it has first-minted on-chain (sticky)


def _has_minted_onchain(cfg, wallet):
    """True iff this wallet has actually minted (free or paid) — a real chain read, sticky cache."""
    k = _norm(wallet)
    if _CONVERTED.get(k):
        return True
    if not cfg["deployed"] or not k:
        return False
    used_free = _read_uint(cfg, "freeUsedByAgent(address)(uint256)", wallet)
    paid = _read_uint(cfg, "paidSharesByWallet(address)(uint256)", wallet)
    if used_free > 0 or paid > 0:
        _CONVERTED[k] = True
        return True
    return False


def _invite_converted_count(cfg, inviter):
    """How many of this inviter's invitees have actually first-minted on-chain."""
    n = 0
    for invitee in _invitees(inviter):
        if _has_minted_onchain(cfg, invitee):
            n += 1
    return n


def _social_state(cfg, wallet):
    """Return (tasks[], bonusEarned) for a wallet. follow/repost/telegram are attestation-based;
       invite is verified on-chain (an invited agent must have first-minted)."""
    tasks = []
    bonus = 0
    invite_done = _invite_converted_count(cfg, wallet) > 0 if wallet else False
    for t in SOCIAL_TASKS:
        if t["kind"] == "onchain":
            done = invite_done
        else:
            done = _social_has(wallet, t["id"]) if wallet else False
        if done:
            bonus += t["reward"]
        tasks.append({
            "id": t["id"], "label": t["label"], "reward": t["reward"],
            "kind": t["kind"], "done": bool(done),
        })
    return tasks, bonus


@app.post("/social/claim")
def social_claim():
    """Submit an attestation (proof URL / handle) for a social task (follow/repost/telegram).
       Attestation-based: accepted on submit, claim-once per (wallet, task); NOT externally
       verified. The on-chain FREE_PER_AGENT_CAP ceiling is the real bound on granted free shares."""
    data = body()
    wallet = (data.get("wallet") or "").strip()
    task = (data.get("task") or "").strip()
    proof = data.get("proof") or ""
    valid = {t["id"] for t in SOCIAL_TASKS if t["kind"] == "attest"}
    if not wallet:
        return jsonify(ok=False, error="missing wallet"), 400
    if task not in valid:
        return jsonify(ok=False, error="unknown or non-attestation task"), 400
    created = _social_attest(wallet, task, proof)
    return jsonify(ok=True, task=task, recorded=created, attestation=True,
                   note="attested (not externally verified); on-chain ceiling still bounds free shares")


@app.post("/invite/register")
def invite_register():
    """An invitee records who referred it (both verified .ai agents). First referrer wins;
       self-referral ignored. The referral only COUNTS for the inviter once the invitee first-mints
       on-chain — verified by a real freeUsedByAgent/paidSharesByWallet read."""
    cfg = load_config()
    data = body()
    invitee = (data.get("wallet") or "").strip()
    inviter = (data.get("inviter") or data.get("ref") or "").strip()
    handle = data.get("handle", "")
    # gate: the invitee must own the Agent-ID it registers, so referrals can't be spoofed.
    label = label_from_name(handle)
    tid = token_id_of(label)
    owner = registry_owner_of(cfg, tid) if tid is not None else None
    if not (invitee and owner and owner.lower() == invitee.lower()):
        return jsonify(ok=False, error="not an agent — agent-gated"), 403
    created = _invite_register(invitee, inviter)
    return jsonify(ok=True, registered=created,
                   note="referral recorded" if created else "already referred / self-referral")


@app.get("/invite/status")
@app.post("/invite/status")
def invite_status():
    """An inviter's referral tally: total registered and how many have first-minted (converted)."""
    cfg = load_config()
    wallet = request.args.get("wallet") or (body().get("wallet") if request.method == "POST" else "")
    wallet = (wallet or "").strip()
    if not wallet:
        return jsonify(ok=False, error="missing wallet"), 400
    invited = _invitees(wallet)
    converted = _invite_converted_count(cfg, wallet)
    return jsonify(ok=True, wallet=wallet, invited=len(invited), converted=converted,
                   inviteTaskDone=(converted > 0))


# ---------------------------------------------------------------------------
# on-chain explorer: real mint history (indexer.py writes it) + live renderer reads
# ---------------------------------------------------------------------------

EXPLORER_DB = os.path.join(HERE, "explorer.db")

# Layer-id -> display name (canonical order; mirrors DinoRenderer exactly).
_BG = ["Desert", "Dunes", "Cactus", "Cactus 1", "Cactus 2", "Cactus 3", "Meteors", "Plane"]
_FT = {9: "Freckles", 10: "Pattern", 11: "Spikes", 12: "Horns", 13: "Back", 14: "Sticks",
       15: "Bone", 16: "Canop", 17: "Fire"}
_AC = {18: "Cap", 19: "Hat", 20: "Glasses", 21: "Headphone", 22: "Mask", 23: "Mill hat",
       24: "Smoking", 25: "Steam", 26: "Stars", 27: "Fleck", 28: "Water", 29: "Fire",
       30: "Halo", 31: "Laser"}
_COL = ["Gold", "Green", "Blue", "Purple", "Red", "Mint", "Pink"]


def _renderer_addr(cfg):
    if not cfg["deployed"]:
        return ""
    ok, out, _ = cast_call(cfg, cfg["tokenAddr"], "renderer()(address)")
    return out.split()[0] if (ok and out) else ""


def _mirror_addr(cfg):
    if not cfg["deployed"]:
        return ""
    ok, out, _ = cast_call(cfg, cfg["tokenAddr"], "mirrorERC721()(address)")
    return out.split()[0] if (ok and out) else ""


def _traits_for(cfg, renderer, token_id):
    """Chain-truth traits for a tokenId via the on-chain renderer (seed = keccak(abi.encode(id)))."""
    if not renderer:
        return None
    ok1, enc, _ = _cast(["abi-encode", "x(uint256)", str(token_id)])
    if not ok1:
        return None
    ok2, seed, _ = _cast(["keccak", enc])
    if not ok2 or not seed.startswith("0x"):
        return None
    ok3, out, _ = cast_call(cfg, renderer, "traitsOf(uint256)(uint8,uint8,uint8,uint8)", seed)
    if not ok3 or not out:
        return None
    parts = out.split()
    if len(parts) < 4:
        return None
    try:
        bg, ft, ac, col = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
    except ValueError:
        return None
    return {
        "Background": _BG[bg] if 0 <= bg < len(_BG) else str(bg),
        "Base": "Main base",
        "Accessory": _AC.get(ac, "None") if ac != 255 else "None",
        "Feature": _FT.get(ft, "None") if ft != 255 else "None",
        "Body-Color": _COL[col] if 0 <= col < len(_COL) else str(col),
    }


def _owner_of(cfg, mirror, token_id):
    if not mirror:
        return ""
    ok, out, _ = cast_call(cfg, mirror, "ownerOf(uint256)(address)", str(token_id))
    return out.split()[0] if (ok and out and out.split()[0].lower() != ZERO) else ""


def _explorer_rows(offset, limit):
    """(total, rows[]) from the indexer DB; empty if it hasn't indexed anything yet."""
    if not os.path.exists(EXPLORER_DB):
        return 0, []
    try:
        c = sqlite3.connect(EXPLORER_DB, timeout=5)
        total = c.execute("SELECT COUNT(*) FROM tokens").fetchone()[0]
        rows = c.execute(
            "SELECT tokenId, minter, mintBlock, mintTs, txHash FROM tokens "
            "ORDER BY mintBlock ASC, tokenId ASC LIMIT ? OFFSET ?", (limit, offset)).fetchall()
        c.close()
        return total, rows
    except sqlite3.Error:
        return 0, []


def _explorer_one(token_id):
    if not os.path.exists(EXPLORER_DB):
        return None
    try:
        c = sqlite3.connect(EXPLORER_DB, timeout=5)
        r = c.execute("SELECT tokenId, minter, mintBlock, mintTs, txHash FROM tokens WHERE tokenId=?",
                      (token_id,)).fetchone()
        c.close()
        return r
    except sqlite3.Error:
        return None


@app.get("/explore/tokens")
def explore_tokens():
    cfg = load_config()
    if not cfg["deployed"]:
        return jsonify(deployed=False, total=0, tokens=[])
    try:
        offset = max(0, int(request.args.get("offset", 0)))
        limit = min(100, max(1, int(request.args.get("limit", 20))))
    except ValueError:
        offset, limit = 0, 20

    renderer = _renderer_addr(cfg)
    mirror = _mirror_addr(cfg)
    total, rows = _explorer_rows(offset, limit)
    exp = cfg["explorer"]
    out = []
    for (tid, minter, blk, ts, txh) in rows:
        out.append({
            "tokenId": tid,
            "traits": _traits_for(cfg, renderer, tid) or {},
            "minter": {"wallet": minter, "handle": None, "verified": True},  # minted via agent-gate
            "owner": {"wallet": _owner_of(cfg, mirror, tid) or minter, "handle": None},
            "block": blk, "ts": ts, "txHash": txh,
            "bscscan": {"token": f"{exp}/token/{cfg['tokenAddr']}", "tx": f"{exp}/tx/{txh}"},
        })
    return jsonify(deployed=True, total=total, tokens=out)


def _explorer_by_minter(wallet):
    """All mint-ledger rows whose ORIGINAL minter == wallet (Transfer-from-zero), oldest first."""
    if not os.path.exists(EXPLORER_DB):
        return []
    try:
        c = sqlite3.connect(EXPLORER_DB, timeout=5)
        rows = c.execute(
            "SELECT tokenId, minter, mintBlock, mintTs, txHash FROM tokens WHERE minter=? "
            "ORDER BY mintBlock ASC, tokenId ASC", (_norm(wallet),)).fetchall()
        c.close()
        return rows
    except sqlite3.Error:
        return []


@app.get("/collection")
def collection():
    """Dinos a wallet GOT FROM MINTING (original minter == wallet), with live held/moved status.
       Accepts ?wallet= or ?handle= (handle resolves to its Agent-ID owner wallet)."""
    cfg = load_config()
    wallet = (request.args.get("wallet") or "").strip()
    handle = request.args.get("handle") or ""
    resolved_handle = None
    if not wallet and handle:
        # resolve a .ai handle to the wallet that owns its Agent-ID
        label = label_from_name(handle)
        tid = token_id_of(label)
        owner = registry_owner_of(cfg, tid) if tid is not None else None
        if owner and owner.lower() != ZERO:
            wallet = owner
            resolved_handle = handle

    if not cfg["deployed"]:
        return jsonify(deployed=False, wallet=wallet, handle=resolved_handle, count=0, tokens=[])
    if not wallet:
        return jsonify(deployed=True, wallet="", handle=None, count=0, tokens=[])

    renderer = _renderer_addr(cfg)
    mirror = _mirror_addr(cfg)
    exp = cfg["explorer"]
    out = []
    for (tid, minter, blk, ts, txh) in _explorer_by_minter(wallet):
        owner = _owner_of(cfg, mirror, tid)
        out.append({
            "tokenId": tid,
            "traits": _traits_for(cfg, renderer, tid) or {},
            "mintBlock": blk, "ts": ts, "txHash": txh,
            "bscscan": {"token": f"{exp}/token/{cfg['tokenAddr']}", "tx": f"{exp}/tx/{txh}"},
            "currentOwner": owner,
            "stillHeld": bool(owner) and owner.lower() == _norm(wallet),
        })
    return jsonify(deployed=True, wallet=wallet, handle=resolved_handle, count=len(out), tokens=out)


@app.get("/explore/token/<int:token_id>")
def explore_token(token_id):
    cfg = load_config()
    if not cfg["deployed"]:
        return jsonify(deployed=False, tokenId=token_id)
    renderer = _renderer_addr(cfg)
    mirror = _mirror_addr(cfg)
    exp = cfg["explorer"]

    # svg + traits straight from the on-chain renderer (chain-truth, not the preview json)
    svg = ""
    ok, uri, _ = cast_call(cfg, renderer, "tokenURI(uint256)(string)", str(token_id)) if renderer else (False, "", "")
    if ok and uri:
        uri = uri.strip().strip('"')
        try:
            meta = json.loads(base64.b64decode(uri.split("base64,", 1)[1]).decode("utf-8"))
            svg = meta.get("image", "")
        except Exception:  # noqa: BLE001
            svg = uri

    r = _explorer_one(token_id)
    minter = r[1] if r else ""
    blk = r[2] if r else 0
    ts = r[3] if r else 0
    txh = r[4] if r else ""
    owner = _owner_of(cfg, mirror, token_id)
    return jsonify(
        deployed=True, tokenId=token_id, svg=svg,
        traits=_traits_for(cfg, renderer, token_id) or {},
        minter={"wallet": minter, "handle": None, "verified": bool(minter)},
        owner={"wallet": owner, "handle": None},
        block=blk, ts=ts, txHash=txh,
        bscscan={"token": f"{exp}/token/{cfg['tokenAddr']}",
                 "tx": (f"{exp}/tx/{txh}" if txh else ""),
                 "owner": (f"{exp}/address/{owner}" if owner else "")},
        agentGated=True,
    )


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8265)
