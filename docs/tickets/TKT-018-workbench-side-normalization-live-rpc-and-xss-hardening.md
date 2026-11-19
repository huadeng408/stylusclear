# TKT-018: Harden Workbench Side Normalization, Unified RPC Bundle, Wallet Chain Sync & Live Dual-Contract Simulation

- **Status**: `completed`
- **Priority**: P0
- **Blocked by**: `TKT-017`
- **Testing Seam**: `Seam S3` (`web/engine-ui.mjs`, `web/rpc-client.ts`, `web/dist/rpc-client.mjs`, `web/index.html`)

## Acceptance Criteria
1. Normalize `side` case-insensitively across Stage 2, Stage 3, `toCanonicalBatchJson`, and `buildSettleBatchCallPayload` (preventing lowercase `"buy"` -> `SELL` inversion), sort `marketKeys` numerically, and enforce full asset/zero-address validation in `web/engine-ui.mjs`.
2. Unify `web/rpc-client.ts` and `web/dist/rpc-client.mjs` (removing hardcoded `arbitrumSepolia` chain lock, adding `AbortSignal.timeout`, strict `bytes32`/uint bounds checks, recursive `error.data` decoding, and EIP-2098 64-byte signature parsing).
3. Eliminate `innerHTML` DOM XSS and decimal input crashes in `web/index.html`, read active wallet `eth_chainId`, and dynamically domain-sign deterministic preset batches per target contract for Live JSON-RPC dual-contract simulation.
