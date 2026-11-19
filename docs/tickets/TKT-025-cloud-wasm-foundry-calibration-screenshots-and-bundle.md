# TKT-025: Cloud Host WASM/Foundry Calibration, Headless Chromium Retina Screenshots, Dual-Axis Audit & Drive Sync

- **Status**: Completed (`v0.6.0` — Wave 3 Frontier)
- **Blocked by**: TKT-024
- **Testing Seam**: Seam S1, Seam S2, Seam S3, Seam S4
- **Governing Contracts**: `CONTEXT.md`, `ADR-0010`, `SPEC-001` (`v0.6.0`)

## Objective & Deliverable Behavior

1. Mount `代码任务所需实体` (`01,02,03,06,07`) in Debian 12 sandbox and run `bash scripts/check.sh --strict --offline` end-to-end with zero skipped gates: `cargo fmt --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` (including `TestVM`), `clearing_stylus.wasm` Brotli-q11 `< 24,576 B` + zero-float/SIMD/reftype scan, and `forge test -vv` (256-run fuzz + 4-tier `2 / 9 / 33 / 62` multi-chord EVM gas calibration).
2. Upgrade `docs/benchmarks/measured-gas-artifacts.json` to `host_wasm_and_foundry_measured` and sync `docs/benchmarks/gas-comparison-report.md`, `README.md`, and `web/engine-ui.mjs`, achieving `python3 tools/archcheck/check.py . --strict` exit 0 (`[archcheck] OK [strict-calibrated]`).
3. Render `docs/assets/workbench-institutional-mesh.png` and `docs/assets/workbench-fail-closed-guard.png` via headless Chromium (`1440x920` @ 2x DPR) and visually inspect both images to confirm zero clipping and exact calibration parity.
4. Run concurrent read-only Standards and Spec code-review subagents, resolve any findings, create semantic Git commit, export `.vm_deps/repo.bundle`, and overwrite all modified files in-place on Google Drive with zero duplicate filenames.
