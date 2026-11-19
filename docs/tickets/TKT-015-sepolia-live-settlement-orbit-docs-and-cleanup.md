# TKT-015：修复 `deploy-sepolia` / `demo-sepolia-live` 真链对标闭环、Orbit 预编译手册与云盘零重名清理

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-014`
* **Testing Seam**: `Seam S4`

## 验收标准（Acceptance Criteria）
1. `scripts/deploy-sepolia.{sh,ps1}` 补齐 `forge create --broadcast`，剥离 ANSI 码精准提取 `deployed code at address:` 及部署/激活 Tx Hash 并用 `cast code` 核验字节码非空。
2. `scripts/demo-sepolia-live.sh` 在 Arbitrum Sepolia 双合约上执行完全相同的确权债务冲销 + EIP-712 `settleBatch`，解析真实 `gasUsed` 与 `BatchTelemetry` 日志自动回写 `arbitrum-sepolia.json`、`measured-gas-artifacts.json` 及 `README.md`。
3. `docs/orbit-institutional-appchain.md` 修正 `ArbWasmCache.cacheProgram(address)` 与带 `--value` 的 `codehashKeepalive(bytes32)`；清理遗留 `.v01_backup` 与旧 `.tar.gz` 至网盘根下外部归档目录。
