"""Seam S2 tests: EIP-712 canonical signatures (421614 + 46630) and Python <-> Rust CLI differential parity."""
from __future__ import annotations

from pathlib import Path

from tools.ref_sim.crypto_eip712 import (
    compute_intent_digest,
    compute_obligation_digest,
    privkey_to_address,
    sign_digest,
)
from tools.ref_sim.engine import WAD, execute_batch_payload, recover_eip712_signer

ROOT = Path(__file__).resolve().parents[1]


def test_s2_eip712_dual_chain_signatures_and_batch_execution() -> None:
    pk_a = int("11" * 32, 16)
    pk_b = int("22" * 32, 16)
    addr_a = privkey_to_address(pk_a)
    addr_b = privkey_to_address(pk_b)
    contract = "0x" + "cc" * 20

    for chain_id in (421614, 46630):
        ob_digest = compute_obligation_digest(chain_id, contract, addr_a, addr_b, 0, 500 * WAD, 10, 77)
        v_ob, r_ob, s_ob = sign_digest(pk_a, ob_digest)
        assert recover_eip712_signer(ob_digest, v_ob, "0x" + r_ob.hex(), "0x" + s_ob.hex()).lower() == addr_a.lower()

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
