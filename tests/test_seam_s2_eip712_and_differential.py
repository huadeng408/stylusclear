"""Seam S2 tests: EIP-712 canonical signatures (421614 + 46630) and Python <-> Rust CLI differential parity."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

from tools.ref_sim.crypto_eip712 import (
    compute_intent_digest,
    compute_obligation_digest,
    privkey_to_address,
    sign_digest,
)
from tools.ref_sim.engine import WAD, ClearingEngineError, execute_batch_payload, recover_eip712_signer

ROOT = Path(__file__).resolve().parents[1]


def _find_cli() -> Path | None:
    cands: list[Path] = []
    if os.environ.get("CARGO_TARGET_DIR"):
        cands.append(Path(os.environ["CARGO_TARGET_DIR"]) / "release" / "clearing-cli")
    cands.extend([ROOT / "target" / "release" / "clearing-cli", ROOT / "target" / "debug" / "clearing-cli"])
    for c in cands:
        if c.exists() and os.access(c, os.X_OK):
            return c
    return None


def test_s2_eip712_dual_chain_signatures_and_batch_execution() -> None:
    pk_a = int("11" * 32, 16)
    pk_b = int("22" * 32, 16)
    addr_a = privkey_to_address(pk_a)
    addr_b = privkey_to_address(pk_b)
    contract = "0x" + "cc" * 20

    for chain_id in (421614, 46630):
        ob_digest = compute_obligation_digest(chain_id, contract, addr_a, addr_b, 0, 500 * WAD, 10, 77)
        v_ob, r_ob, s_ob = sign_digest(pk_a, ob_digest)
        rec = recover_eip712_signer(ob_digest, v_ob, "0x" + r_ob.hex(), "0x" + s_ob.hex())
        assert rec is not None and rec.lower() == addr_a.lower()

        it_digest = compute_intent_digest(chain_id, contract, addr_b, 1, 0, 1, 1 * WAD, 2400 * WAD, 10, 88)
        v_it, r_it, s_it = sign_digest(pk_b, it_digest)

        payload = {
            "batch_epoch": 1,
            "block_timestamp": 1_700_000_100,
            "max_price_staleness": 3600,
            "max_price_deviation_bps": 2000,
            "chain_id": chain_id,
            "verifying_contract": contract,
            "caller": addr_a,
            "assets": [
                {"asset_id": 0, "decimals": 6, "mark_price_wad": 1 * WAD, "price_updated_at": 1_700_000_090, "haircut_bps": 0, "im_bps": 500, "mm_bps": 250},
                {"asset_id": 1, "decimals": 18, "mark_price_wad": 2500 * WAD, "price_updated_at": 1_700_000_090, "haircut_bps": 500, "im_bps": 1000, "mm_bps": 500},
            ],
            "accounts": [
                {"address": addr_a, "balances": [20_000 * WAD, 5 * WAD]},
                {"address": addr_b, "balances": [20_000 * WAD, 5 * WAD]},
            ],
            "obligations": [
                {
                    "debtor": 0,
                    "creditor": 1,
                    "asset_id": 0,
                    "amount_wad": 500 * WAD,
                    "auth_mode": 2,
                    "max_epoch": 10,
                    "nonce": 77,
                    "v": v_ob,
                    "r": "0x" + r_ob.hex(),
                    "s": "0x" + s_ob.hex(),
                }
            ],
            "intents": [
                {"trader": 0, "base_asset": 1, "quote_asset": 0, "side": 0, "amount_wad": 1 * WAD, "limit_price_wad": 2550 * WAD, "max_epoch": 10, "nonce": 78, "auth_mode": 0},
                {
                    "trader": 1,
                    "base_asset": 1,
                    "quote_asset": 0,
                    "side": 1,
                    "amount_wad": 1 * WAD,
                    "limit_price_wad": 2400 * WAD,
                    "max_epoch": 10,
                    "nonce": 88,
                    "auth_mode": 1,
                    "v": v_it,
                    "r": "0x" + r_it.hex(),
                    "s": "0x" + s_it.hex(),
                },
            ],
        }
        out = execute_batch_payload(payload)
        assert int(out["total_matched_volume_wad"]) == 1 * WAD


def test_s2_golden_vectors_and_rust_cli_differential_parity() -> None:
    vectors = json.loads((ROOT / "tests" / "vectors" / "golden_batches.json").read_text(encoding="utf-8"))
    assert len(vectors) >= 4
    cli_bin = _find_cli()

    with tempfile.TemporaryDirectory() as td:
        for vec in vectors:
            payload = vec["input"]
            if vec["expect_ok"]:
                py_res = execute_batch_payload(payload)
                exp = vec["expected_receipt"]
                assert int(py_res["cycles_eliminated"]) == int(exp["cycles_eliminated"])
                assert py_res["fee_vault_deltas"] == exp["fee_vault_deltas"]
                assert py_res["compressed_volume_by_asset"] == exp["compressed_volume_by_asset"]
                if cli_bin is not None:
                    pfile = Path(td) / f"{vec['name']}.json"
                    pfile.write_text(json.dumps(payload), encoding="utf-8")
                    proc = subprocess.run([str(cli_bin), "replay", str(pfile)], capture_output=True, text=True, check=True)
                    cli_res = json.loads(proc.stdout)
                    assert cli_res["cycles_eliminated"] == py_res["cycles_eliminated"]
                    assert cli_res["auctions"] == py_res["auctions"]
                    assert cli_res["compressed_volume_by_asset"] == py_res["compressed_volume_by_asset"]
                    assert cli_res["fee_vault_deltas"] == py_res["fee_vault_deltas"]
                    assert cli_res["post_accounts"] == py_res["post_accounts"]
            else:
                with pytest.raises(ClearingEngineError) as exc:
                    execute_batch_payload(payload)
                assert exc.value.code == vec["expected_error"]
                if cli_bin is not None:
                    pfile = Path(td) / f"{vec['name']}.json"
                    pfile.write_text(json.dumps(payload), encoding="utf-8")
                    proc = subprocess.run([str(cli_bin), "replay", str(pfile)], capture_output=True, text=True)
                    assert proc.returncode != 0
                    assert vec["expected_error"] in (proc.stderr + proc.stdout)


def test_s2_v110_ref_sim_hardening_and_cli_strict_gate() -> None:
    from tools.ref_sim.engine import (
        WAD,
        AssetRiskConfig,
        ClearingEngineError,
        _norm_addr,
        recover_eip712_signer,
        validate_asset_configs_selective,
    )

    # 1. Invalid/overflowing r/s in recover_eip712_signer returns None instead of crashing
    assert recover_eip712_signer(b"\x00" * 32, 27, -1, 1) is None
    assert recover_eip712_signer(b"\x00" * 32, 27, "0xzzzz", "0x01") is None
    assert recover_eip712_signer(b"\x00" * 32, 27, 1 << 257, 1) is None

    # 2. Invalid hex address raises ClearingEngineError instead of raw ValueError
    try:
        _norm_addr("0x" + "g" * 40)
        raise AssertionError("expected ClearingEngineError")
    except ClearingEngineError as err:
        assert err.code == "InvalidAssetConfig"

    # 3. > 16 assets raises BatchCapacityExceeded
    too_many = [AssetRiskConfig(i, WAD, 0, 500, 250, 6, 100) for i in range(17)]
    try:
        validate_asset_configs_selective(too_many, 1, 100, 3600)
        raise AssertionError("expected BatchCapacityExceeded")
    except ClearingEngineError as err:
        assert err.code == "BatchCapacityExceeded"

    # 4. Strict CLI enforcement when STYLUSCLEAR_REQUIRE_CLI=1
    if os.environ.get("STYLUSCLEAR_REQUIRE_CLI") == "1":
        assert _find_cli() is not None, "clearing-cli binary required when STYLUSCLEAR_REQUIRE_CLI=1"
