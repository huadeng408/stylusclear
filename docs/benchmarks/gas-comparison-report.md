# StylusClear v1.2.0 Isomorphic Cold-Storage Gas & Stylus Ink Benchmark Report

* **Calibration Status**: `host_replay_analytical_and_foundry_measured`
* **Arbitrum Single-Block Gas Limit ([Chain Params](https://docs.arbitrum.io/arbitrum-essentials/reference/chain-params))**: `32,000,000` gas (`Stress` tier verified `< 32M` under cold storage `vm.cool()`)
* **Stylus WASM Artifact (`artifacts/clearing_stylus.wasm`)**: `65,635 B` uncompressed / **`24,518 B` Brotli-q11** (`24,522 B` incl. 4 B Stylus prefix — `54 B` below legacy `24,576 B` cap; `73,782 B` below [`ArbOS 61`](https://docs.arbitrum.io/run-a-node/arbos-releases/arbos61) `96 KB` cap; `SHA-256`: `c2f3244ddeca5c54e9ac47be27caabd38f50d7cfc6b3af19457db98f5f4588b3`)
* **Metering Model ([Stylus Gas & Ink](https://docs.arbitrum.io/stylus/concepts/gas-metering) / [HostIO Pricing](https://docs.arbitrum.io/stylus/reference/opcode-hostio-pricing))**: Offline analytical proxy anchored to host-verified Rust `clearing-cli` replay (`scripts/measure-wasm-benchmarks.py`, asserting `foundry_cycles == rust_cycles` across `2/9/33/45` cycles) + complete EIP-2929 HostIO cold-storage pricing (8 config slots, all `get_partial_fill` cold SLOADs, full `20,000`-gas cold `0 -> non-zero` nonce SSTOREs, `5,000`-gas warm SSTOREs, `ecrecover`, `native_keccak256`, and quadratic `memory_grow`; `10,000 ink = 1 EVM gas`) vs `forge test -vvvv` with `vm.cool()` (`solc 0.8.38`, `via_ir = true`, `optimizer_runs = 200`). Both pure execution-frame speedup (`exec`) and end-to-end speedup including shared L2 calldata (`e2e`) are disclosed side by side. Live on-chain `eth_estimateGas` & `evm_ink_left()` calibration runs upon Arbitrum Sepolia deployment.

| Tier | Desks | Obligations | Cycles Netted | Intents | Solidity Cold EVM Gas (`vm.cool()`, runs=200) | Analytical WASM Ops (Host Replay) | Total Stylus Ink (Est.) | Stylus Total Gas (Compute + Complete HostIO) | Net Gas Saved (`exec` / `e2e`) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `Small` | 4 | 5 | 2 | 4 | `449,659` | `5,406,000` | `2,644,630,000` | `264,463` | **41.2% (`1.70x` exec / `1.61x` e2e)** |
| `Medium` | 12 | 20 | 9 | 24 | `2,342,677` | `23,486,000` | `7,966,050,000` | `796,605` | **66.0% (`2.94x` exec / `2.53x` e2e)** |
| `Large` | 32 | 64 | 33 | 64 | `9,843,744` | `87,682,000` | `21,279,030,000` | `2,127,903` | **78.4% (`4.63x` exec / `3.85x` e2e)** |
| `Stress` | 44 | 88 | 45 | 88 | `16,645,399` | `136,990,000` | `29,173,160,000` | `2,917,316` | **82.5% (`5.71x` exec / `4.69x` e2e)** |

## Visual Summary
![StylusClear Cold-Storage Gas & 24 KiB Budget](../assets/gas-comparison-chart.png)

## Methodology & Reproducibility
1. **Strict `AND` Gate & Zero Stale Drift**: Both Rust host-verified replay (`scripts/measure-wasm-benchmarks.py`) AND Foundry `ClearingBenchmarkGas` cold-slot traces (`forge test -vvvv`, `optimizer_runs = 200`) must succeed simultaneously to regenerate `measured-gas-artifacts.json`, `gas-comparison-report.md`, `docs/assets/gas-comparison-chart.svg`, and `web/benchmarks.generated.mjs`.
2. **Cold Storage & Compiler Parity**: Every `ClearingBenchmarkGas` tier invokes `vm.cool(address(engine))` immediately before `settleBatch(...)` with `optimizer_runs = 200` (avoiding `runs = 1` bytecode-only bias while remaining under EIP-170). On the Stylus side, the HostIO model charges all 8 config cold SLOADs, every `get_partial_fill` cold SLOAD (`n_int * 2,100`), full `20,000`-gas cold `0 -> non-zero` nonce SSTOREs (`n_acc * 20,000`), warm SSTOREs (`5,000` gas), `ecrecover`, `native_keccak256`, and quadratic WASM memory expansion.
3. **Host-Native Keccak256**: `clearing-stylus` delegates EIP-712 hashing and storage slot derivation to Stylus `native_keccak256` HostIO rather than software `tiny-keccak`, keeping Stress-tier execution well below Arbitrum's `32,000,000` single-block gas limit.
