# StylusClear v0.8.0 — 2m45s (`193s`) Demo Video Script & Pre-Rendered Production Kit

* **Resolution & Frame Rate**: `1920x1080` (`1080p60`), H.264 `yuv420p`, `-14 LUFS` EBU R128 broadcast audio with sidechain-ducked CC0 underscore
* **Workbench Local URL**: `http://127.0.0.1:8080`
* **Pre-Rendered Cloud Assets (`docs/assets/video_kit/`)**:
  * `seg1_hook.mp4` (`00:00–00:25`, `25s`): Institutional Liquidity Lockup & `$13,200.00 -> $1,050.00` Multilateral Cycle Compression
  * `seg2_workbench.mp4` (`00:25–01:10`, `45s`): 4-Asset Portfolio (`USDC/USDG`, `WETH`, `ARB`, `NVDAx`), `<5ms` 64-Desk O(V²) Mesh & Fail-Closed Guard
  * `seg3_bridge.mp4` (`01:10–01:35`, `25s`, auto-replaced or extended by `35s` live explorer clip via `scripts/build-final-video.sh`): Arbitrum Sepolia (`421614`) & Robinhood Chain Testnet (`46630`) Dual-Chain Bridge
  * `seg4_rigor.mp4` (`02:10–02:45`, `35s`): Cold-Storage `vm.cool()` EVM vs `wasmi` Fuel Benchmarks & 6 Z3 `UNSAT` Formal Proofs
  * `master_audio.wav` (`193.0s`), `subtitles.srt`, `subtitles.ass`

## Full 4-Scene Voiceover Transcript (Exact Spoken Script)

### Scene 1 (`00:00–00:25`) — The Institutional Clearing Bottleneck
Institutional market makers on Arbitrum and Robinhood Chain lock millions in fragmented collateral because bilateral payables settle one leg at a time. StylusClear v0.8.0 brings solverless multilateral cycle compression and a five-hundred-twelve-bit Uniform Clearing Price Batch Auction directly into a twenty-four-point-four kilobyte Arbitrum Stylus Rust WASM engine—collapsing thirteen thousand two hundred dollars of circular debt down to just one thousand fifty dollars of net transfer, a ninety-two percent liquidity savings in one atomic transaction.

### Scene 2 (`00:25–01:10`) — Interactive 4-Asset Workbench & Fail-Closed Guards
Inside the StylusClear Workbench on port eighty-eighty, operators inspect four cross-margined assets: six-decimal USDC and USDG stablecoins, WETH, ARB, and eighteen-decimal tokenized NVDAx equities. Our canonical two-origin breadth-first cycle finder scales smoothly to sixty-four institutional desks in under five milliseconds, always prioritizing multilateral rings over greedy bilateral pairs. When an adversarial order crosses outside the twenty percent oracle band—or breaches initial margin—StylusClear reverts fail-closed with LimitPriceViolated or InsufficientInitialMargin, mutating zero state.

### Scene 3 (`01:10–02:10`) — Dual-Chain Settlement on Arbitrum Sepolia & Robinhood Testnet
StylusClear deploys reproducibly with official Binaryen WASM one-point-zero MVP passes—zero custom section mutation, fully compliant with Arbitrum AIP thirty-one-six-oh-five and ArbOS sixty-one—and initializes atomically through StylusAtomicFactory. Switching the workbench between Arbitrum Sepolia chain ID four-two-one-six-one-four and Robinhood Chain Testnet four-six-six-three-zero executes keyless eth-call and gas estimation against live contracts, settling USDG obligations alongside tokenized NVDAx equity fills with cryptographic domain separation.

### Scene 4 (`02:10–02:45`) — Empirical Cold-Storage Benchmarks & Z3 Formal Proofs
Under cold EIP-twenty-nine-twenty-nine storage realism with Foundry vm-cool, a forty-four-desk stress batch consumes twenty-four-point-eight million gas in Solidity—safely under Arbitrum's thirty-two million single-block cap—while Stylus WASM cuts total gas by over eighteen-fold. Six machine-checked Z3 SMT theorems prove zero stablecoin liquidation deadlocks, zero floor-cap overcharges, five-hundred-twelve-bit individual rationality, double-entry conservation, and physical vault solvency—all verifiable in fifteen seconds via verify-judge-sixty-s dot sh.
