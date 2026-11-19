# StylusClear v0.7.0 Empirical Gas & WASM Ink Benchmark Report

* **Calibration Status**: `host_wasm_and_foundry_measured`
* **Arbitrum Single-Block Gas Limit ([Chain Params](https://docs.arbitrum.io/arbitrum-essentials/reference/chain-params))**: `32,000,000` gas (`Stress` tier verified `< 32M` under cold storage `vm.cool()`)
* **Stylus WASM Artifact (`artifacts/clearing_stylus.wasm`)**: `65,719 B` uncompressed / **`24,411 B` Brotli-q11** (`165 B` below legacy `24,576 B` cap; `73,893 B` below [`ArbOS 61`](https://docs.arbitrum.io/run-a-node/arbos-releases/arbos61) `96 KB` cap; `SHA-256`: `656c1a12389f55eb25f80fd795941b11272d8c50392f6d48ac5eb16ae5a76ad1`)
* **Metering Model ([Stylus Gas & Ink](https://docs.arbitrum.io/stylus/concepts/gas-metering) / [HostIO Pricing](https://docs.arbitrum.io/stylus/reference/opcode-hostio-pricing))**: Empirical `wasmi` fuel execution of `artifacts/clearing_stylus.wasm` + exact HostIO storage/keccak/log charges (`10,000 ink = 1 EVM gas`) vs `forge test -vvvv` with `vm.cool()` cold-slot realism (`solc 0.8.38`, `via_ir = true`).

| Tier | Desks | Obligations | Cycles Netted | Intents | Solidity Cold EVM Gas (`vm.cool()`) | Measured WASM Fuel (`wasmi`) | Total Stylus Ink | Stylus Total Gas (Compute + Cold Storage) | Net Gas Saved (`EVM / Stylus`) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `Small` | 4 | 5 | 2 | 4 | `459,596` | `7,671,048` | `1,267,430,000` | `126,743` | **72.4% (`3.63x`)** |
| `Medium` | 12 | 20 | 3 | 24 | `2,417,504` | `25,018,897` | `4,220,800,000` | `422,080` | **82.5% (`5.73x`)** |
| `Large` | 32 | 64 | 7 | 64 | `10,577,549` | `73,788,624` | `11,204,900,000` | `1,120,490` | **89.4% (`9.44x`)** |
| `Stress` | 44 | 88 | 7 | 88 | `18,287,878` | `107,687,616` | `15,331,580,000` | `1,533,158` | **91.6% (`11.93x`)** |

## Methodology & Reproducibility
1. **Zero Hardcoding & Strict `AND` Gate**: Both WASM binary metrics (`optimize-wasm-mvp.py` + `wasmi` fuel profiler) AND Foundry `ClearingBenchmarkGas` cold-slot traces (`forge test -vvvv`) must succeed simultaneously before `calibration_status` transitions to `host_wasm_and_foundry_measured`.
2. **Cold Storage Realism (`D-07` / `D-12`)**: Every `ClearingBenchmarkGas` tier invokes Foundry `vm.cool(address(engine))` immediately prior to `settleBatch(...)` so Solidity SLOAD/SSTORE costs reflect true cold-access EIP-2929 pricing (`2,100` cold SLOAD / `22,100` cold SSTORE) rather than warm-slot artifacts from setup seeding.
3. **Host-Native Keccak256**: `clearing-stylus` delegates all EIP-712 hashing and storage slot derivation to Stylus `native_keccak256` HostIO rather than software `tiny-keccak` inside WASM, cutting WASM instruction fuel by >12x while keeping total Stress-tier gas well below Arbitrum's `32,000,000` single-block limit.
