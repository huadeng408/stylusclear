# TKT-013：修复前端工作台 Stage 2 真验签、`viem` 客户端与跨语言预设场景 100% 等价

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-012`
* **Testing Seam**: `Seam S3`

## 验收标准（Acceptance Criteria）
1. `web/engine-ui.mjs` 在 Stage 1 与 Stage 2 完整执行 `DIRECT` 主调方核验与真实 secp256k1 EIP-712 签名恢复核验；预设场景非主调方委托全部附带 `chainId = 421614` 规范签名。
2. `tests/test_seam_s3_workbench.mjs` 自动调用参考 CLI 校验三大预设场景在 JS、Python（及可用时的 Rust CLI）下输出完全一致的回执或错误码。
3. `web/index.html` 钱包签名自动同步更新 `accounts[0].address`，自动读取 `deployments/arbitrum-sepolia.json` 预填合约地址，且前端基准数字与 `measured-gas-artifacts.json` 完全同源。
