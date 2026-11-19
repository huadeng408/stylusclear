# TKT-008：紧凑 3 参数结构体 ABI、零 Unsafe Stylus 构建、`clearing-cli` `k256` 真验签与 Solidity 512 位算术

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-006`, `TKT-007`
* **Testing Seam**: `Seam S2`, `Seam S3`

## 交付行为（Vertical Slice Behavior）

1. 拆分根工作区 `Stylus.toml` 与子包 `crates/clearing-stylus/Stylus.toml`，启用 `mini-alloc`，改用 `stylus_sdk::call::static_call` 消除 `unsafe` 并开启 `#![forbid(unsafe_code)]`，将容量校验前置至任何 `SLOAD` 之前。
2. 将 `settleBatch` 17 个散装数组收敛为 `(address[] participants, ObligationInput[] obligations, SignedTradeIntent[] intents)` 紧凑结构体 ABI，四端同步。
3. 在 `clearing-cli` 与 `clearing-stylus` `[dev-dependencies]` 接入纯 Rust `k256` 实现真实 `ecrecover`，彻底删除 `OfflineNullVerifier`，输出完整 `SettlementReceipt` JSON。
4. 在 `SolidityClearingBenchmark.sol` 实现 512 位无中间溢出 `_mulDivFloor`/`_mulDivCeil` 与安全有符号转换，在 `ClearingDifferential.t.sol` 补齐黄金向量与 Fuzz 差分测试。

## 验收判据（Acceptance Criteria）

* `clearing-cli replay tests/vectors/sample_batch.json` 真实恢复 EIP-712 签名并返回退出码 `0`；
* Solidity 端大数边界统一返回 `MathOverflow()` 自定义错误而非 `Panic(0x11)`。
