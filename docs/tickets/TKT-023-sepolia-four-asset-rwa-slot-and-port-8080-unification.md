# TKT-023: Arbitrum Sepolia 4th Asset Slot (`rwaMock18`) Live RPC Parity & Port 8080 Unification

- **Status**: Completed (`v0.6.0` — Wave 1 Frontier)
- **Blocked by**: None
- **Testing Seam**: Seam S2, Seam S3
- **Governing Contracts**: `CONTEXT.md`, `ADR-0010`, `SPEC-001` (`v0.6.0`)

## Objective & Deliverable Behavior

1. Extend `deployments/arbitrum-sepolia.json`, `web/deployments/arbitrum-sepolia.json`, `scripts/deploy-sepolia.sh`, `scripts/demo-sepolia-live.sh` (and `.ps1` counterparts), `web/engine-ui.mjs`, and `web/index.html` with standard asset slot `assetId = 3` (`rwaMock18`: 18-decimal tokenized equity `NVDAx` @ `$140.00` = `140 * 10^18`, `haircut_bps = 1000`, `im_bps = 1200`, `mm_bps = 600`).
2. Ensure `demo-sepolia-live.sh` idempotently mints and deposits `assetId = 3` collateral for judge simulation desks (`DEMO_A_ADDR`, `DEMO_B_ADDR`), and update `PRESET_SCENARIOS.robinhoodUsdgMesh` + `buildLiveScenarioPayloads` / `buildDomainSignedLivePayload` so Scenario 4 settles `assetId = 3` (`NVDAx`) against `assetId = 0` (`USDG`/`USDC` 6d) with domain-separated EIP-712 signatures and zero protection-band reverts.
3. Unify workbench HTTP port to `8080` across all docs (fixing `docs/DEMO_VIDEO_SCRIPT.md` from `4173` to `8080`), rebuild `web/dist/rpc-client.mjs`, and verify Scenarios 1–4 against a 4-asset stateful mock JSON-RPC dual-contract harness in `tests/test_seam_s3_workbench.mjs`.
