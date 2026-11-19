// Auto-generated single source of truth from scripts/generate-benchmarks.py — DO NOT EDIT BY HAND
export const MEASURED_BENCHMARKS = {
  "schema_version": "0.8.0",
  "calibration_status": "host_wasm_and_foundry_measured",
  "arbitrum_single_block_gas_limit": 32000000,
  "wasm_binary": {
    "artifact_path": "artifacts/clearing_stylus.wasm",
    "raw_bytes": 65341,
    "brotli_q11_bytes": 24527,
    "legacy_24kb_limit_bytes": 24576,
    "arbos61_96kb_limit_bytes": 98304,
    "sha256": "d4fba5d6d4315fce83fef29c2c52e2897de22b0ed0b7d7449293b5f6a33bfc8a",
    "zero_float_opcodes_verified": true,
    "zero_post_mvp_opcodes_verified": true,
    "custom_byte_mutation": false
  },
  "workloads": [
    {
      "tier": "Small",
      "accounts": 4,
      "obligations": 5,
      "cycles_eliminated": 2,
      "intents": 4,
      "solidity_evm_gas": 459676,
      "wasm_instructions": 5406000,
      "hostio_calls": 71,
      "stylus_ink": 1727160000,
      "stylus_compute_gas": 3893,
      "stylus_total_gas_est": 172716,
      "gas_reduction_pct": 62.43,
      "speedup_x": 2.66
    },
    {
      "tier": "Medium",
      "accounts": 12,
      "obligations": 20,
      "cycles_eliminated": 9,
      "intents": 24,
      "solidity_evm_gas": 2417984,
      "wasm_instructions": 23486000,
      "hostio_calls": 248,
      "stylus_ink": 5256540000,
      "stylus_compute_gas": 16910,
      "stylus_total_gas_est": 525654,
      "gas_reduction_pct": 78.26,
      "speedup_x": 4.6
    },
    {
      "tier": "Large",
      "accounts": 32,
      "obligations": 64,
      "cycles_eliminated": 33,
      "intents": 64,
      "solidity_evm_gas": 10578829,
      "wasm_instructions": 87682000,
      "hostio_calls": 680,
      "stylus_ink": 14373320000,
      "stylus_compute_gas": 63132,
      "stylus_total_gas_est": 1437332,
      "gas_reduction_pct": 86.41,
      "speedup_x": 7.36
    },
    {
      "tier": "Stress",
      "accounts": 44,
      "obligations": 88,
      "cycles_eliminated": 45,
      "intents": 88,
      "solidity_evm_gas": 18289638,
      "wasm_instructions": 136990000,
      "hostio_calls": 932,
      "stylus_ink": 19749730000,
      "stylus_compute_gas": 98633,
      "stylus_total_gas_est": 1974973,
      "gas_reduction_pct": 89.2,
      "speedup_x": 9.26
    }
  ],
  "onchain_verification": {
    "network": "arbitrum-sepolia",
    "chain_id": 421614,
    "explorer_base_url": "https://sepolia.arbiscan.io",
    "stylus_contract_address": null,
    "solidity_benchmark_address": null,
    "stylus_settle_tx_hash": null,
    "solidity_settle_tx_hash": null,
    "stylus_receipt_gas_used": null,
    "solidity_receipt_gas_used": null,
    "stylus_telemetry_wasm_ink": null,
    "stylus_telemetry_compute_gas": null,
    "onchain_gas_saved_pct": null
  }
};
