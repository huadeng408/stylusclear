# StylusClear v0.8.0 Empirical Gas & WASM Ink Benchmark Report

* **Calibration Status**: `host_wasm_and_foundry_measured`
* **Arbitrum Single-Block Gas Limit ([Chain Params](https://docs.arbitrum.io/arbitrum-essentials/reference/chain-params))**: `32,000,000` gas (`Stress` tier verified `< 32M` under cold storage `vm.cool()`)
* **Stylus WASM Artifact (`artifacts/clearing_stylus.wasm`)**: `65,341 B` uncompressed / **`24,527 B` Brotli-q11** (`49 B` below legacy `24,576 B` cap; `73,777 B` below [`ArbOS 61`](https://docs.arbitrum.io/run-a-node/arbos-releases/arbos61) `96 KB` cap; `SHA-256`: `d4fba5d6d4315fce83fef29c2c52e2897de22b0ed0b7d7449293b5f6a33bfc8a`)
* **Metering Model ([Stylus Gas & Ink](https://docs.arbitrum.io/stylus/concepts/gas-metering) / [HostIO Pricing](https://docs.arbitrum.io/stylus/reference/opcode-hostio-pricing))**: Reproducible isomorphic Rust/WASM execution (`scripts/measure-wasm-benchmarks.py`, asserting `foundry_cycles == rust_cycles` across `2/9/33/45` cycles) + transparent ArbOS HostIO cold-storage/ecrecover pricing (offline pre-deployment proxy; live on-chain `eth_estimateGas` & `evm_ink_left()` recorded upon testnet deployment) (`10,000 ink = 1 EVM gas`) vs `forge test -vvvv` with `vm.cool()` cold-slot realism (`solc 0.8.38`, `via_ir = true`).

| Tier | Desks | Obligations | Cycles Netted | Intents | Solidity Cold EVM Gas (`vm.cool()`) | Measured WASM Fuel (`wasmi`) | Total Stylus Ink | Stylus Total Gas (Compute + Cold Storage) | Net Gas Saved (`EVM / Stylus`) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `Small` | 4 | 5 | 2 | 4 | `459,676` | `5,406,000` | `1,727,160,000` | `172,716` | **62.4% (`2.66x`)** |
| `Medium` | 12 | 20 | 9 | 24 | `2,417,984` | `23,486,000` | `5,256,540,000` | `525,654` | **78.3% (`4.60x`)** |
| `Large` | 32 | 64 | 33 | 64 | `10,578,829` | `87,682,000` | `14,373,320,000` | `1,437,332` | **86.4% (`7.36x`)** |
| `Stress` | 44 | 88 | 45 | 88 | `18,289,638` | `136,990,000` | `19,749,730,000` | `1,974,973` | **89.2% (`9.26x`)** |

## Methodology & Reproducibility
1. **Zero Hardcoding & Strict `AND` Gate**: Both WASM binary metrics (`optimize-wasm-mvp.py` + `wasmi` fuel profiler) AND Foundry `ClearingBenchmarkGas` cold-slot traces (`forge test -vvvv`) must succeed simultaneously before `calibration_status` transitions to `host_wasm_and_foundry_measured`.
2. **Cold Storage Realism (`D-07` / `D-12`)**: Every `ClearingBenchmarkGas` tier invokes Foundry `vm.cool(address(engine))` immediately prior to `settleBatch(...)` so Solidity SLOAD/SSTORE costs reflect true cold-access EIP-2929 pricing (`2,100` cold SLOAD / `22,100` cold SSTORE) rather than warm-slot artifacts from setup seeding.
3. **Host-Native Keccak256**: `clearing-stylus` delegates all EIP-712 hashing and storage slot derivation to Stylus `native_keccak256` HostIO rather than software `tiny-keccak` inside WASM, cutting WASM instruction fuel by >12x while keeping total Stress-tier gas well below Arbitrum's `32,000,000` single-block limit.
