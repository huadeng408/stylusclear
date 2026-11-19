# StylusClear (`v0.9.0`) — 3m13s (`193.0s`) Broadcast Demo Script

- **Total Duration**: `3m13s` (`193.000s` exact = `31.0s + 59.0s + 25.0s + 32.0s + 46.0s`)
- **Video Spec**: `1920x1080` @ `60fps` (`yuv420p`, H.264 High@4.2, `+faststart`, burned-in `subtitles.ass` + `mov_text`)
- **Audio Master**: `docs/assets/video_kit/master_audio.m4a` (`48 kHz` stereo, `276.4 kbps` AAC, `-14.0 LUFS` / `-1.0 dBTP`, copied lossless via `-c:a copy`)
- **Subtitle Tracks**: `docs/assets/video_kit/subtitles.srt` & `subtitles.ass` (26 cues, `00:00.200` to `03:12.600`)
- **Benchmark Version Note**: The pre-recorded 193s audio track narrates the `v0.8.0` baseline HostIO proxy (`9.26x` / `1.97M` vs `18.29M`). In `v0.9.0`, the conservative complete-HostIO model (adding all 88 `get_partial_fill` cold SLOADs, 8 config slots, `memory_grow`, and Solidity `optimizer_runs = 200`) reports `6.98x` (`2.62M` vs `18.28M`), and live Arbitrum Sepolia `eth_estimateGas` / `evm_ink_left()` replaces the offline proxy during local deployment.

## Timeline Breakdown
1. **Segment 1 — `seg1_hook.mp4` (`00:00 – 00:31`, `31.0s`)**: Institutional cold-storage gas bottleneck, StylusClear `no_std` Rust architecture, zero-patch WASM 1.0 MVP (`24,527 B` Brotli-q11, `< 24 KB` legacy & `96 KB` ArbOS 61 caps, zero float/post-MVP opcodes).
2. **Segment 2 — `seg2_workbench.mp4` (`00:31 – 01:30`, `59.0s`)**: Interactive Workbench walkthrough — Canonical `O(V^2)` 2-Origin BFS obligation cycle compression, 512-bit UCPBA uniform clearing auction, and fail-closed `LimitPriceViolated()` atomic rollback.
3. **Segment 3a — `seg3_bridge.mp4` (`01:30 – 01:55`, `25.0s`)**: Dual-chain ABI parity (`39` ABI selectors / `19` custom error selectors) across Arbitrum Sepolia (`421614`) and Robinhood Chain Testnet (`46630`), plus `StylusAtomicFactory` CEI-hardened atomic deployment.
4. **Segment 3b — `seg3_live_fallback.mp4` or Local 32s Live Clip (`01:55 – 02:27`, `32.0s`)**: Live `deploy-sepolia.sh` / `demo-sepolia-live.sh` broadcast & Arbiscan transaction receipt verification (replaceable via `bash scripts/build-final-video.sh <live_32s.mp4> docs/assets/demo-final.mp4`).
5. **Segment 4 — `seg4_rigor.mp4` (`02:27 – 03:13`, `46.0s`)**: Isomorphic `2 / 9 / 33 / 45`-cycle cold-storage gas comparison, `6/6` Z3 `PROVED_UNSAT` theorems, Hypothesis cross-binary differential fuzzing, `15/15` Foundry + `8/8` Cargo + `5/5` Pytest + `0` Ruff/Mypy/Clippy warnings, and 20-second judge verification (`bash scripts/verify-judge-60s.sh`).
