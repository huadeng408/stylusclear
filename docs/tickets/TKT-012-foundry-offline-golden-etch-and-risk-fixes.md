# TKT-012：修复 Foundry 零依赖离线构建、`golden_batches.json` 原生验签、512 位保护带与预言机/跨币种步长漏洞

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-011`
* **Testing Seam**: `Seam S1`, `Seam S2`

## 验收标准（Acceptance Criteria）
1. 删除悬空 `foundry.toml` `remappings` 及脚本/CI 中废弃的 `forge install --no-commit`。
2. `ClearingDifferential.t.sol` 使用 `vm.parseUint(vm.parseJsonString(...))`、合法 JSONPath `['0']` 及 `vm.etch` 原位校验 `golden_01..04` 全部原始签名向量。
3. `SolidityClearingBenchmark.sol` 统一采用 `FullMath512.mulDivCeil(priceDiff, BPS_DENOM, refPrice) > maxPriceDeviationBps` 消除 256 位乘法溢出。
4. 四端同步实装“带负债 `withdraw` 强制校验 `StaleMarkPrice`、无负债随时提款”及跨币种 `ref_tick = (ref_price / 10^9) * 10^9` 碎股步长对齐。
