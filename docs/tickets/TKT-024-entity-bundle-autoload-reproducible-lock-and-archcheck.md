# TKT-024: Shared Entity Bundle Auto-Mount, `Cargo.lock` `--locked` Reproducibility & Archcheck Hardening

- **Status**: Completed (`v0.6.0` — Wave 2 Frontier)
- **Blocked by**: TKT-022, TKT-023
- **Testing Seam**: Seam S4
- **Governing Contracts**: `CONTEXT.md`, `ADR-0010`, `SPEC-001` (`v0.6.0`)

## Objective & Deliverable Behavior

1. Upgrade `scripts/check.sh` and `scripts/wsl2-oneclick-finish.sh` to auto-detect `STYLUSCLEAR_ENTITY_DIR` or `../local offline toolchain bundle/manifest.json`, invoke `bootstrap_sandbox.py --dst "$HOME/.cache/stylusclear_entity_sandbox" --modules 01,02,03,06,07`, source `activate_env.sh`, configure Cargo `vendored-sources` (`$OFFLINE_CRATES_VENDOR`) and offline `solc`, while retaining `.vm_deps/stylus_web_bundle.tar.xz` compatibility and protecting `arbitrum_sepolia_onchain_verified` status idempotently in `scripts/generate-benchmarks.py --ingest-host-logs`.
2. Generate and commit root `Cargo.lock`, and update `Dockerfile.stylus-reproducible` to `COPY Cargo.toml Cargo.lock Stylus.toml ./` and run `cargo build --locked --release --target wasm32-unknown-unknown -p clearing-stylus`.
3. Harden `tools/archcheck/check.py` and `tests/test_seam_s4_archcheck.py` (Red-Green TDD) to forbid `legacy 500-bps bonus cap` and `legacy port 4173` across repository code/docs and require root `Cargo.lock` plus `Cargo.lock` + `--locked` inside `Dockerfile.stylus-reproducible`.
