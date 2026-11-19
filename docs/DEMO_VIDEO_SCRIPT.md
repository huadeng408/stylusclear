# StylusClear v1.1.0 — Demo Video Script & Master Production Spec

* **Master File**: `docs/assets/demo-preview.mp4` (`1920x1080 @ 60fps`, `193.002s`, `H.264 High + AAC 48kHz stereo 100.8 kbps + burned-in ASS Inter Bold subtitles + mov_text eng + faststart`)
* **Subtitles**: `docs/assets/video_kit/subtitles.ass` & `docs/assets/video_kit/subtitles.srt` (synchronized to `v1.1.0` metrics & zero-mock pre-broadcast wording)
* **Local 32s Live Replacement**: After running `scripts/wsl2-oneclick-finish.ps1` on Arbitrum Sepolia (`421614`) and Robinhood Chain Testnet (`46630`), optionally pass a 32-second Arbiscan/Robinhood Explorer screen recording via `LIVE_CLIP_PATH` to `scripts/build-final-video.sh` to replace the pre-broadcast workflow preview segment (`01:55–02:27`).

## Scene Breakdown (193.0s)

1. **00:00 – 00:31 | Hook & Zero-Patch WASM 1.0 MVP**: Institutional DeFi clearing cold-storage gas bottleneck → StylusClear `v1.1.0` in `no_std` Rust (`24,484 B` Brotli-q11, `71 B` below `24,576 B` legacy cap incl. 4 B header, `0` float / `0` post-MVP opcodes, `92.05%` liquidity saved, `8.11x` Stress gas savings).
2. **00:31 – 01:30 | Interactive Keyless Web Workbench**: Scenario 1 (`$13,200 → $1,050`, `-92.05%`, `2.00 WETH @ $2,850`), Scenario 2 (`LimitPriceViolated`, `0` state mutated atomic rollback), and Scenario 4 (Robinhood Chain Testnet `46630` `USDG` + `NVDAx`, `-94.17%`).
3. **01:30 – 01:55 | Dual-Chain Architecture & Strict CEI Atomic Factory**: `StylusAtomicFactory.sol` (`2,064 B`) CREATE2 salt binding + `ArbWasm (0x71)` activation + `benchmarkSeedingEnabled()` verification; **37 ABI methods & 19 custom errors** with identical read-only reentrancy guards across Stylus & Solidity.
4. **01:55 – 02:27 | Pre-Broadcast Workflow Preview & 5-Stage Verification**: Honest `PRE-BROADCAST PREVIEW` of `bash scripts/verify-judge-60s.sh` (`[1/5]..[5/5]`, `< 20s`) and minimal local `scripts/wsl2-oneclick-finish.sh` broadcast flow (Zero-Mock guarantee).
5. **02:27 – 03:13 | Cold-Storage Benchmarks & 6/6 Z3 Formal Proofs**: Isomorphic `2/9/33/45` cycles (`2.26x / 3.93x / 6.43x / 8.11x`, Stress `2.26M` vs `18.30M`, `-87.7%`, `< 32M` single-block cap) + **6/6 Z3 SMT theorems `PROVED_UNSAT`** + **100/100 cross-binary `clearing-cli` Hypothesis fuzzing** (`17/17` Foundry, `8/8` Cargo, `8/8` Pytest, Seam S3).
