# StylusClear v1.0.0 Isomorphic Cold-Storage Gas & Stylus Ink Benchmark Report

* **Calibration Status**: `host_replay_analytical_and_foundry_measured`
* **Arbitrum Single-Block Gas Limit ([Chain Params](https://docs.arbitrum.io/arbitrum-essentials/reference/chain-params))**: `32,000,000` gas (`Stress` tier verified `< 32M` under cold storage `vm.cool()`)
* **Stylus WASM Artifact (`artifacts/clearing_stylus.wasm`)**: `65,673 B` uncompressed / **`24,501 B` Brotli-q11** (`24,505 B` incl. 4 B Stylus prefix — `71 B` below legacy `24,576 B` cap; `73,799 B` below [`ArbOS 61`](https://docs.arbitrum.io/run-a-node/arbos-releases/arbos61) `96 KB` cap; `SHA-256`: `174dda6effaf78c267c660deb396772e07d3869f710e7eebaa21d4d3e6a2cc91`)
* **Metering Model ([Stylus Gas & Ink](https://docs.arbitrum.io/stylus/concepts/gas-metering) / [HostIO Pricing](https://docs.arbitrum.io/stylus/reference/opcode-hostio-pricing))**: Offline analytical proxy anchored to host-verified Rust `clearing-cli` replay (`scripts/measure-wasm-benchmarks.py`, asserting `foundry_cycles == rust_cycles` across `2/9/33/45` cycles) + complete EIP-2929 HostIO cold-storage pricing (8 config slots, all `get_partial_fill` cold SLOADs, conservative 5,000-gas SSTOREs, `ecrecover`, `native_keccak256`, and `memory_grow`; `10,000 ink = 1 EVM gas`) vs `forge test -vvvv` with `vm.cool()` (`solc 0.8.38`, `via_ir = true`, `optimizer_runs = 200`). Shared L2 calldata gas is excluded identically from both sides' execution frames and disclosed in JSON. Live on-chain `eth_estimateGas` & `evm_ink_left()` calibration runs upon Arbitrum Sepolia deployment.

| Tier | Desks | Obligations | Cycles Netted | Intents | Solidity Cold EVM Gas (`vm.cool()`, runs=200) | Analytical WASM Ops (Host Replay) | Total Stylus Ink (Est.) | Stylus Total Gas (Compute + Complete HostIO) | Net Gas Saved (`EVM / Stylus`) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `Small` | 4 | 5 | 2 | 4 | `459,327` | `5,406,000` | `2,034,390,000` | `203,439` | **55.7% (`2.26x`)** |
| `Medium` | 12 | 20 | 9 | 24 | `2,416,506` | `23,486,000` | `6,155,810,000` | `615,581` | **74.5% (`3.93x`)** |
| `Large` | 32 | 64 | 33 | 64 | `10,574,871` | `87,682,000` | `16,468,790,000` | `1,646,879` | **84.4% (`6.42x`)** |
| `Stress` | 44 | 88 | 45 | 88 | `18,284,228` | `136,990,000` | `22,562,920,000` | `2,256,292` | **87.7% (`8.10x`)** |

## Methodology & Reproducibility
1. **Strict `AND` Gate & Zero Stale Drift**: Both Rust host-verified replay (`scripts/measure-wasm-benchmarks.py`) AND Foundry `ClearingBenchmarkGas` cold-slot traces (`forge test -vvvv`, `optimizer_runs = 200`) must succeed simultaneously to regenerate `measured-gas-artifacts.json`, `gas-comparison-report.md`, and `web/benchmarks.generated.mjs`.
2. **Cold Storage & Compiler Parity**: Every `ClearingBenchmarkGas` tier invokes `vm.cool(address(engine))` immediately before `settleBatch(...)` with `optimizer_runs = 200` (avoiding `runs = 1` bytecode-only bias while remaining under EIP-170). On the Stylus side, the analytical HostIO model charges all 8 config cold SLOADs, every `get_partial_fill` cold SLOAD (`n_int * 2,100`), conservative SSTOREs (`5,000` gas), `ecrecover`, `native_keccak256`, and `4,096` gas WASM memory expansion.
3. **Host-Native Keccak256**: `clearing-stylus` delegates EIP-712 hashing and storage slot derivation to Stylus `native_keccak256` HostIO rather than software `tiny-keccak`, keeping Stress-tier execution well below Arbitrum's `32,000,000` single-block gas limit.
