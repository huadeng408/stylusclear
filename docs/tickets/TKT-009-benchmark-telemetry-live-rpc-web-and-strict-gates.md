# TKT-009：链上 Ink / Foundry Gas 单一权威基准流水线、真实 JSON-RPC 前端工作台与硬门禁 `A6/A7`

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-008`
* **Testing Seam**: `Seam S3`, `Seam S4`

## 交付行为（Vertical Slice Behavior）

1. 在 Stylus 合约接入 `evm_ink_left()` / `ink_to_gas` 遥测事件 `BatchTelemetry`，编写 `scripts/generate-benchmarks.py` 生成唯一权威 `docs/benchmarks/measured-gas-artifacts.json` 并自动同步 `gas-comparison-report.md` 与 `README.md`，在 `tools/archcheck/check.py` 新增规则 `A7` 拦截任何数值漂移。
2. 实现零外部 CDN 依赖的 `web/rpc-client.ts` 与浏览器直接可加载的 `web/dist/rpc-client.mjs`，修复 `web/index.html` 假下拉框与 `Number(BigInt)` 精度丢失，真实发送 `eth_chainId`、`eth_call` 与 `eth_estimateGas` 双合约同屏对比并在连接失败时显式报红。
3. 升级 `scripts/check.sh`、`scripts/check.ps1`（支持 `--strict` / `-Strict` 全工具链硬门禁与 WASM `<24 KB` / 零浮点字节码扫描）及 `.github/workflows/ci.yml`（锁定 Rust `1.91.0`）。

## 验收判据（Acceptance Criteria）

* 本地模拟 JSON-RPC 节点测试验证前端真实发送双合约 `eth_call` / `eth_estimateGas`，断连时显式返回 `RpcConnectionError`；
* 修改 `README.md` 任意基准数字时 `archcheck` 规则 `A7` 立即返回非零退出码。
