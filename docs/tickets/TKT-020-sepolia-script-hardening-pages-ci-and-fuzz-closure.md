# TKT-020: Harden WSL2/Sepolia Scripts, Add GitHub Pages Workflow, Refresh Screenshots & Enforce Drive Purity

- **Status**: `completed`
- **Priority**: P0
- **Blocked by**: `TKT-018`, `TKT-019`
- **Testing Seam**: `Seam S3` & `Seam S4` (`scripts/*.sh`, `.github/workflows/pages.yml`, `docs/assets/*.png`)

## Acceptance Criteria
1. Fix `cleanup_temp` `return 0` and `/mnt/g` `drvfs`-safe native build staging in `scripts/check.sh`, add `node --input-type=module`, env-only key passing, collision-free nonces, last-JSON parsing, and 90-day testnet oracle freshness in `deploy-sepolia.*` & `demo-sepolia-live.sh`.
2. Add `.github/workflows/pages.yml` for zero-install GitHub Pages workbench hosting, add `agents.md` to `.gitignore`, re-render HD Chromium workbench screenshots, and verify 500+ cross-language adversarial fuzz batches pass.
