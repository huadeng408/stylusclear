# TKT-010：本机依赖一键就位、Arbitrum Sepolia 全链路实盘脚本、Orbit 清算专链配置与夺冠版 `README.md`

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-009`
* **Testing Seam**: `Seam S3`, `Seam S4`

## 交付行为（Vertical Slice Behavior）

1. 提供 `scripts/bootstrap-host.sh` 与 `scripts/bootstrap-host.ps1` 自动拉取本机 Rust `1.91.0`、`cargo-stylus`、`Cargo.lock`、`forge-std` 与 `web/node_modules`。
2. 升级 `scripts/deploy-sepolia.sh`、`scripts/deploy-sepolia.ps1` 与 `scripts/demo-sepolia-live.sh`（自动部署 `MockERC20` 6/8/18 位代币 + `StylusClearingEngine` + `SolidityClearingBenchmark`，执行真实存款、登记三角债务、EIP-712 批量拍卖并写入 `deployments/arbitrum-sepolia.json`）。
3. 新增 `deployments/orbit-clearing-rollup-config.json` 与 `docs/orbit-institutional-appchain.md`（详述 2026-10 主网激活暂停应对、Orbit 专链配置、`ArbWasmCache` 竞价盈亏平衡测算与 365 天 `codehashKeepalive` 续期方案），重构夺冠版 `README.md`。

## 验收判据（Acceptance Criteria）

* 部署配置、Orbit 专链文档、基准表标记块与全部跨平台脚本通过 `archcheck` 及全量单测门禁（退出码 `0`）。
