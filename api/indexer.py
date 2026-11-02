#!/usr/bin/env python3
"""
DinoPeg402 mint-history indexer.

Reads config.json. When the contracts are live (deployed=true), scans the DN-404 mirror's
ERC-721 Transfer-from-zero logs to record the ORIGINAL minter of each tokenId (first mint wins;
DN-404 recycles ids, so only the earliest mint per id is kept). Persists lastScannedBlock and
catches up incrementally. Writes backend/explorer.db, which the API read path serves (cached) —
the indexer never blocks reads. Pre-deploy it idles. All chain reads via `cast` (no fabricated data).

Run under pm2:  pm2 start indexer.py --name dpeg-indexer --interpreter python3
"""
import json
import os
import sqlite3
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "config.json")
DB = os.path.join(HERE, "explorer.db")

# keccak256("Transfer(address,address,uint256)")
TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ZERO_TOPIC = "0x" + "00" * 32
CHUNK = 1000          # blocks per eth_getLogs call (public-RPC friendly)
POLL = 20             # seconds between catch-up passes


def load_config():
    with open(CONFIG) as f:
        c = json.load(f)
    c["deployed"] = bool(c.get("deployed")) and bool(c.get("mintAddr")) and bool(c.get("tokenAddr"))
    return c


def cast(args, timeout=40):
    try:
        p = subprocess.run(["cast", *args], capture_output=True, text=True, timeout=timeout)
        return (p.returncode == 0, p.stdout.strip(), p.stderr.strip())
    except Exception:  # noqa: BLE001
        return (False, "", "cast failed")


def db():
    c = sqlite3.connect(DB, timeout=10)
    c.execute("""CREATE TABLE IF NOT EXISTS tokens (
        tokenId INTEGER PRIMARY KEY, minter TEXT, mintBlock INTEGER, mintTs INTEGER, txHash TEXT)""")
    c.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
    c.commit()
    return c


def get_meta(c, k, default=None):
    r = c.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return r[0] if r else default


def set_meta(c, k, v):
    c.execute("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
              (k, str(v)))
    c.commit()


def rpc_block_number(cfg):
    ok, out, _ = cast(["rpc", "eth_blockNumber", "--rpc-url", cfg["rpc"]])
    if not ok:
        return None
    try:
        return int(out.strip().strip('"'), 16)
    except ValueError:
        return None


def mirror_of(cfg):
    ok, out, _ = cast(["call", cfg["tokenAddr"], "mirrorERC721()(address)", "--rpc-url", cfg["rpc"]])
    return out.split()[0] if (ok and out) else ""


_TS_CACHE = {}


def block_ts(cfg, bn):
    if bn in _TS_CACHE:
        return _TS_CACHE[bn]
    ok, out, _ = cast(["rpc", "eth_getBlockByNumber", hex(bn), "false", "--rpc-url", cfg["rpc"]])
    ts = 0
    if ok:
        try:
            ts = int(json.loads(out)["timestamp"], 16)
        except Exception:  # noqa: BLE001
            ts = 0
    _TS_CACHE[bn] = ts
    return ts


def scan_range(cfg, mirror, c, fromBlk, toBlk):
    """eth_getLogs for mirror Transfer-from-zero in [fromBlk, toBlk]; record first mint per tokenId."""
    flt = {
        "address": mirror,
        "fromBlock": hex(fromBlk),
        "toBlock": hex(toBlk),
        "topics": [TRANSFER_TOPIC, ZERO_TOPIC],  # from == 0x0 (mint)
    }
    ok, out, _ = cast(["rpc", "eth_getLogs", json.dumps(flt), "--rpc-url", cfg["rpc"]])
    if not ok:
        return False
    try:
        logs = json.loads(out)
    except Exception:  # noqa: BLE001
        return False
    for lg in logs:
        topics = lg.get("topics", [])
        if len(topics) < 4:
            continue
        to = "0x" + topics[2][-40:]
        try:
            token_id = int(topics[3], 16)
            blk = int(lg["blockNumber"], 16)
        except (ValueError, KeyError):
            continue
        txh = lg.get("transactionHash", "")
        # first mint wins (INSERT OR IGNORE keeps the earliest scanned; ranges go forward in time)
        c.execute(
            "INSERT OR IGNORE INTO tokens (tokenId, minter, mintBlock, mintTs, txHash) "
            "VALUES (?,?,?,?,?)", (token_id, to, blk, block_ts(cfg, blk), txh))
    c.commit()
    return True


def main():
    print("dpeg-indexer starting; db=", DB, flush=True)
    while True:
        cfg = load_config()
        cfg["rpc"] = cfg.get("logsRpc") or cfg["rpc"]  # eth_getLogs needs a logs-friendly RPC (bsc-dataseed rejects with -32005)
        if not cfg["deployed"]:
            print("not deployed yet - idle", flush=True)
            time.sleep(POLL)
            continue
        c = db()
        mirror = mirror_of(cfg)
        if not mirror:
            print("mirror unavailable - retry", flush=True)
            c.close()
            time.sleep(POLL)
            continue

        head = rpc_block_number(cfg)
        if head is None:
            c.close()
            time.sleep(POLL)
            continue

        start = get_meta(c, "lastScannedBlock")
        # first run: start at the token's deploy block if known, else from head (no backfill gap
        # beyond what we can see) — set START_BLOCK meta via config if you want an exact origin.
        fromBlk = int(start) + 1 if start is not None else max(0, head - CHUNK)
        if cfg.get("startBlock") and start is None:
            fromBlk = int(cfg["startBlock"])

        while fromBlk <= head:
            toBlk = min(fromBlk + CHUNK - 1, head)
            if not scan_range(cfg, mirror, c, fromBlk, toBlk):
                print(f"scan {fromBlk}-{toBlk} failed - will retry", flush=True)
                break
            set_meta(c, "lastScannedBlock", toBlk)
            fromBlk = toBlk + 1
        c.close()
        time.sleep(POLL)


if __name__ == "__main__":
    main()
