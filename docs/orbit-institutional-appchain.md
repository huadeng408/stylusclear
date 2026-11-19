# StylusClear Dual-Track Deployment Architecture: Arbitrum Sepolia + Institutional Orbit L3 Appchain (v1.1.0)

## 1. Strategic Context: Navigating the October 2026 Stylus Pause & Constitutional AIP-31605

Following the October 2, 2026 [Stylus Activation Pause Notice](https://docs.arbitrum.io/notices/stylus-activation-pause-notice) ([Security Council Emergency Action](https://forum.arbitrum.foundation/t/security-council-emergency-action-2-10-2026/31530)) and the October 23, 2026 [[Constitutional] AIP: Stylus Activation Contract](https://forum.arbitrum.foundation/t/constitutional-aip-stylus-activation-contract/31605), Arbitrum's Stylus deployment landscape operates across three tiers:

1. **Arbitrum Sepolia (`chainId: 421614`)**: Full permissionless `cargo stylus deploy` and [`ArbWasm` (`0x...0071`)](https://docs.arbitrum.io/stylus/concepts/activation) activation for public testnet verification and hackathon evaluation ([Open House Qualification Rules](https://www.hackquest.io/hackathons/Arbitrum-Open-House-Arbitrum Open House-Online-Buildathon)).
2. **Custom Arbitrum Orbit L3 & RWA Chains (including [Robinhood Chain Testnet `46630`](https://docs.robinhood.com/chain/connecting/))**: Independent `ArbOwner` and `ArbWasmCache` precompile governance enabling immediate institutional clearing of tokenized equities and [USDG stablecoins](https://grants.watch/programs/arbitrum-stablecoin-growth-program) with `benchmark_seeding_enabled = false`.
3. **Arbitrum One (`42161`) via AIP-31605 Wrapper**: `StylusClear` enforces `#![forbid(unsafe_code)]`, strict WASM 1.0 (`-reference-types,-simd128` per [Stylus WebAssembly Spec](https://docs.arbitrum.io/stylus/concepts/webassembly)), `Host::msg_reentrant()` protection ([Stylus Rust SDK Guide](https://docs.arbitrum.io/stylus/reference/rust-sdk-guide)), and reproducible Docker builds (`Dockerfile.stylus-reproducible`), satisfying the technical audit checklist for the [Arbitrum Security Program (ASP)](https://forum.arbitrum.foundation/t/42nd-grc-call-recording-transcript/31589) and AIP-31605 allowlist activation.

## 2. Quantitative `ArbWasmCache` Bid & Break-Even Analysis

Per official [Arbitrum Stylus Gas and Ink Metering](https://docs.arbitrum.io/stylus/concepts/gas-metering) (`1 EVM Gas = 10,000 WASM Ink`) and [Opcode & Host I/O Pricing](https://docs.arbitrum.io/stylus/reference/opcode-hostio-pricing):

- **Uncached Program Initialization**: Invoking an uncached Stylus contract incurs a minimum base initialization cost of **`8,832` EVM gas** (`+` linear footprint scaling) to load compiled machine code from storage.
- **Warm Cached Execution (`ArbWasmCache` at `0x0000000000000000000000000000000000000072`)**: Invoking a cached Stylus program drops initialization overhead to a **`352` EVM gas** minimum (`8,480` gas saved per call).
- **External Host I/O Separation**: Each EIP-712 `ecrecover` (`0x01`) `static_call` consumes **`3,000` gas** (`30,000,000` Ink) identically in both EVM and Stylus; `StylusClearingEngine` isolates pure WASM graph/auction compute Ink from `0x01` precompile Ink inside `BatchTelemetry`.
- **Public Rollup vs Dedicated Orbit L3 Caching**:
  - **Public Rollups (Arbitrum Sepolia / Arbitrum One)**: Submit cache bids via [`cargo stylus cache bid`](https://docs.arbitrum.io/stylus/cli-tools/commands-reference) (`CacheManager.placeBid`), recovering the `8,480`-gas cold-load delta within a few dozen batches vs uncached Stylus and in **1 single clearing batch** vs Solidity EVM (`>140,000` compute gas saved even on 4-account batches).
  - **Dedicated Orbit L3 Appchains**: The chain owner pins the clearing engine directly in `ArbWasmCache` (`0x...0072`) via `ArbWasmCache.cacheProgram(address)`:
    ```bash
    cast send 0x0000000000000000000000000000000000000072 \
      "cacheProgram(address)" "$STYLUS_CLEARING_ADDRESS" \
      --rpc-url "$ORBIT_RPC_URL" \
      --private-key "$CHAIN_OWNER_PRIVATE_KEY"
    ```

## 3. Production 365-Day `codehashKeepalive` Lifecycle Runbook

Activated Stylus programs remain active for **365 days** ([Stylus Activation & Keepalive](https://docs.arbitrum.io/stylus/concepts/activation)). Any keeper may invoke the **payable** `ArbWasm.codehashKeepalive(bytes32 codehash)` method once at least **31 days** have elapsed since activation so the clearinghouse never expires:

```bash
CODEHASH=$(cast codehash "$STYLUS_CLEARING_ADDRESS" --rpc-url "$ARBITRUM_RPC_URL")
cast call 0x0000000000000000000000000000000000000071 \
  "programTimeLeft(bytes32)(uint64)" "$CODEHASH" \
  --rpc-url "$ARBITRUM_RPC_URL"

KEEPALIVE_FEE_WEI="${KEEPALIVE_FEE_WEI:-500000000000000}" # 0.0005 ETH buffer; excess refunded
cast send 0x0000000000000000000000000000000000000071 \
  "codehashKeepalive(bytes32)" "$CODEHASH" \
  --value "$KEEPALIVE_FEE_WEI" \
  --rpc-url "$ARBITRUM_RPC_URL" \
  --private-key "$KEEPER_PRIVATE_KEY"
```
