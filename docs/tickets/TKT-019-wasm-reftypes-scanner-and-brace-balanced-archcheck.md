# TKT-019: Upgrade WASM Reference-Types & Float-Trunc Scanner and Brace-Balanced Archcheck Rust Parser

- **Status**: `completed`
- **Priority**: P0
- **Blocked by**: `TKT-016`
- **Testing Seam**: `Seam S4` (`scripts/generate-benchmarks.py`, `tools/archcheck/check.py`, `tests/test_seam_s4_archcheck.py`)

## Acceptance Criteria
1. Extend `verify_wasm_zero_float_opcodes` in `scripts/generate-benchmarks.py` to detect `0xA8..0xAB` and `0xAE..0xB1` float truncations, scan Import/Global/Element sections, decode `reference-types` (`0x25`, `0x26`, `0xD0..0xD2`) and `0xFD` SIMD prefixes without immediate misalignment, and guard `None` telemetry formatting.
2. Replace naive `src.find("#[cfg(test)]")` truncation in `tools/archcheck/check.py` with brace-balanced `#[cfg(test)]` item stripping so 100% of production contract code is audited under Rules `A2`–`A3`.
