#!/usr/bin/env python3
"""Deterministic Batch Replay & Golden Vector Generator CLI (`Seam S1` / `Seam S3`)."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ref_sim.crypto_eip712 import (  # noqa: E402
    privkey_to_address,
    sign_obligation_attestation,
    sign_trade_intent,
)
from tools.ref_sim.engine import ClearingError, execute_clearing_batch  # noqa: E402

WAD = 10**18


def build_golden_vectors() -> list[dict[str, Any]]:
    chain_id = 421614
    contract = "0x2222222222222222222222222222222222222222"
    pk1 = 0x1010101010101010101010101010101010101010101010101010101010101010
    pk2 = 0x2020202020202020202020202020202020202020202020202020202020202020
    addr1 = privkey_to_address(pk1)
    addr2 = privkey_to_address(pk2)
    relayer = "0x9999000000000000000000000000000000000099"

    assets = [
        {
            "asset_id": 0,
            "symbol": "USDC",
            "decimals": 6,
            "mark_price_wad": str(1 * WAD),
            "price_updated_at": 990,
            "haircut_bps": 0,
            "im_bps": 500,
            "mm_bps": 250,
        },
        {
            "asset_id": 1,
            "symbol": "WETH",
            "decimals": 18,
            "mark_price_wad": str(2500 * WAD),
            "price_updated_at": 990,
            "haircut_bps": 500,
            "im_bps": 1000,
            "mm_bps": 500,
        },
        {
            "asset_id": 2,
            "symbol": "ARB",
            "decimals": 18,
            "mark_price_wad": str(12 * 10**17),
            "price_updated_at": 990,
            "haircut_bps": 1500,
            "im_bps": 1500,
            "mm_bps": 800,
        },
    ]

    # Mixed 3-mode obligation authentication:
    # 0 -> 1 via on-chain PreRegisteredLedger ("0:1:0"),
    # 1 -> 2 via debtor EIP-712 ObligationAttestation signature (pk2),
    # 2 -> 0 via DirectDebtor (caller == relayer == account #2).
    ob_sig_12 = sign_obligation_attestation(
        pk2, chain_id, contract, relayer, 0, 800 * WAD, 100, 101
    )

    nonce1 = (3 << 8) | 19
    nonce2 = (0 << 8) | 7
    sig1 = sign_trade_intent(pk1, chain_id, contract, 1, 0, 0, 2 * WAD, 2510 * WAD, 100, nonce1)
    sig2 = sign_trade_intent(pk2, chain_id, contract, 1, 0, 1, 2 * WAD, 2490 * WAD, 100, nonce2)

    v1_input: dict[str, Any] = {
        "batch_epoch": 42,
        "block_timestamp": 1000,
        "max_price_staleness": 3600,
        "max_price_deviation_bps": 2000,
        "chain_id": chain_id,
        "verifying_contract": contract,
        "caller": relayer,
        "assets": assets,
        "accounts": [
            {"address": addr1, "balances": [str(6000 * WAD), "0", "0"]},
            {"address": addr2, "balances": ["0", str(3 * WAD), "0"]},
            {"address": relayer, "balances": ["0", "0", "0"]},
        ],
        "confirmed_obligations": {
            "0:1:0": str(800 * WAD),
        },
        "obligations": [
            {
                "debtor": 0,
                "creditor": 1,
                "asset_id": 0,
                "amount_wad": str(800 * WAD),
                "auth": {"mode": "LEDGER"},
            },
            {
                "debtor": 1,
                "creditor": 2,
                "asset_id": 0,
                "amount_wad": str(800 * WAD),
                "max_epoch": 100,
                "nonce": "101",
                "auth": ob_sig_12,
            },
            {
                "debtor": 2,
                "creditor": 0,
                "asset_id": 0,
                "amount_wad": str(800 * WAD),
                "max_epoch": 100,
                "nonce": "202",
                "auth": {"mode": "DIRECT"},
            },
        ],
        "intents": [
            {
                "trader": 0,
                "base_asset": 1,
                "quote_asset": 0,
                "side": "BUY",
                "amount_wad": str(2 * WAD),
                "limit_price_wad": str(2510 * WAD),
                "max_epoch": 100,
                "nonce": str(nonce1),
                "auth": sig1,
            },
            {
                "trader": 1,
                "base_asset": 1,
                "quote_asset": 0,
                "side": "SELL",
                "amount_wad": str(2 * WAD),
                "limit_price_wad": str(2490 * WAD),
                "max_epoch": 100,
                "nonce": str(nonce2),
                "auth": sig2,
            },
        ],
        "nonce_bitmaps": {},
    }
    v1_receipt = execute_clearing_batch(v1_input)

    v2_f01_attack: dict[str, Any] = {
        "batch_epoch": 43,
        "block_timestamp": 1000,
        "max_price_staleness": 3600,
        "max_price_deviation_bps": 2000,
        "chain_id": chain_id,
        "verifying_contract": contract,
        "caller": relayer,
        "assets": assets,
        "accounts": [
            {"address": addr1, "balances": [str(10000 * WAD), str(4 * WAD), "0"]},
            {"address": relayer, "balances": ["0", "0", "0"]},
        ],
        "confirmed_obligations": {},
        "obligations": [
            {
                "debtor": 0,
                "creditor": 1,
                "asset_id": 0,
                "amount_wad": str(19000 * WAD),
                "auth": {"mode": "LEDGER"},
            }
        ],
        "intents": [],
        "nonce_bitmaps": {},
    }

    v3_margin_rollback: dict[str, Any] = {
        "batch_epoch": 44,
        "block_timestamp": 1000,
        "max_price_staleness": 3600,
        "max_price_deviation_bps": 2000,
        "chain_id": chain_id,
        "verifying_contract": contract,
        "caller": relayer,
        "assets": assets,
        "accounts": [
            {"address": relayer, "balances": [str(10000 * WAD), "0", "0"]},
            {"address": addr2, "balances": ["0", "0", str(400 * WAD)]},
        ],
        "confirmed_obligations": {},
        "obligations": [],
        "intents": [
            {
                "trader": 0,
                "base_asset": 1,
                "quote_asset": 0,
                "side": "BUY",
                "amount_wad": str(2 * WAD),
                "limit_price_wad": str(2500 * WAD),
                "max_epoch": 100,
                "nonce": "1",
                "auth": {"mode": "DIRECT"},
            },
            {
                "trader": 1,
                "base_asset": 1,
                "quote_asset": 0,
                "side": "SELL",
                "amount_wad": str(2 * WAD),
                "limit_price_wad": str(2500 * WAD),
                "max_epoch": 100,
                "nonce": "2",
                "auth": sign_trade_intent(
                    pk2, chain_id, contract, 1, 0, 1, 2 * WAD, 2500 * WAD, 100, 2
                ),
            },
        ],
        "nonce_bitmaps": {},
    }

    v4_stale_oracle: dict[str, Any] = {
        "batch_epoch": 45,
        "block_timestamp": 6000,
        "max_price_staleness": 3600,
        "max_price_deviation_bps": 2000,
        "chain_id": chain_id,
        "verifying_contract": contract,
        "caller": relayer,
        "assets": assets,
        "accounts": [
            {"address": relayer, "balances": [str(1000 * WAD), "0", "0"]},
        ],
        "confirmed_obligations": {},
        "obligations": [],
        "intents": [],
        "nonce_bitmaps": {},
    }

    return [
        {
            "name": "golden_01_confirmed_and_eip712_cycle_ucpba_success",
            "expect_ok": True,
            "input": v1_input,
            "expected_receipt": v1_receipt,
        },
        {
            "name": "golden_02_f01_unsigned_obligation_drain_rejected",
            "expect_ok": False,
            "expected_error": "UnauthorizedObligation",
            "input": v2_f01_attack,
        },
        {
            "name": "golden_03_f02_insufficient_initial_margin_rollback",
            "expect_ok": False,
            "expected_error": "InsufficientInitialMargin",
            "input": v3_margin_rollback,
        },
        {
            "name": "golden_04_stale_mark_price_rejected",
            "expect_ok": False,
            "expected_error": "StaleMarkPrice",
            "input": v4_stale_oracle,
        },
    ]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: cli.py <benchmark | replay <file.json> | generate-golden>", file=sys.stderr)
        return 2

    cmd = sys.argv[1]
    if cmd == "benchmark":
        report_path = ROOT / "docs" / "benchmarks" / "gas-comparison-report.md"
        if not report_path.is_file():
            print(f"missing benchmark report: {report_path}", file=sys.stderr)
            return 1
        print(report_path.read_text(encoding="utf-8"), end="")
        return 0

    if cmd == "replay":
        if len(sys.argv) < 3:
            print("usage: cli.py replay <file.json>", file=sys.stderr)
            return 2
        with open(sys.argv[2], "r", encoding="utf-8") as fh:
            data = json.load(fh)
        try:
            receipt = execute_clearing_batch(data)
            print(json.dumps(receipt, indent=2))
            return 0
        except ClearingError as exc:
            print(
                json.dumps({"ok": False, "error_code": exc.code, "message": str(exc)}),
                file=sys.stderr,
            )
            return 1

    if cmd == "generate-golden":
        vectors_dir = ROOT / "tests" / "vectors"
        vectors_dir.mkdir(parents=True, exist_ok=True)
        vectors = build_golden_vectors()
        (vectors_dir / "golden_batches.json").write_text(
            json.dumps(vectors, indent=2) + "\n", encoding="utf-8"
        )
        (vectors_dir / "sample_batch.json").write_text(
            json.dumps(vectors[0]["input"], indent=2) + "\n", encoding="utf-8"
        )
        print("Generated tests/vectors/golden_batches.json and tests/vectors/sample_batch.json")
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
