# TKT-004：CLI 确定性重放器、交互式演示工作台与 Arbitrum 部署脚本

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-003`
* **Testing Seam**: `Seam S3`

## 交付行为（Vertical Slice Behavior）

1. 实现 `crates/clearing-cli`（支持 `replay` 与 `benchmark` 子命令，输出结构化 JSON 与 Markdown 基准报告）。
2. 构建 `web/` 轻量级零重型构建交互式演示工作台（`index.html` + ESM 核心状态机 `engine-ui.mjs` + TypeScript `viem` 链上适配器 `rpc-client.ts`），支持离线确定性重放与连接本地 Nitro/Anvil 或 Arbitrum Sepolia RPC，并使用 `node --test` 覆盖前端状态机与交易编码单测。
3. 编写 `scripts/deploy-sepolia.sh` 与 `scripts/deploy-orbit.sh`（集成 `cargo stylus check`、`cargo stylus deploy` 与 `forge create` 对标部署流程）。

## 验收判据（Acceptance Criteria）

* 重放器与前端 ESM 状态机在全部黄金场景（三角/五角债务压缩 + 批量拍卖 + 穿仓原子拦截）下与后端核心逐位一致；
* 生成完整的 `docs/benchmarks/gas-comparison-report.md` 实证对比报表。
