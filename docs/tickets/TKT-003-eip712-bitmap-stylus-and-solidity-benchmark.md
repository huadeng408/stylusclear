# TKT-003：双模 EIP-712 / Bitmap Nonce 鉴权、Stylus WASM 合约与 Solidity 差分基准

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-002`
* **Testing Seam**: `Seam S1`, `Seam S2`

## 交付行为（Vertical Slice Behavior）

1. 实现 `授权见证` 双模校验（`DirectCaller` + 符合 [EIP-712](https://eips.ethereum.org/EIPS/eip-712) 域隔离与 `s` 值低半区检查的离线签名恢复）与 `word_pos + bit_pos` 无序位图防重放。
2. 编写 `crates/clearing-stylus`（基于 [`stylus-sdk 0.10.10`](https://docs.rs/crate/stylus-sdk/latest) 与 [`stylus-test`](https://crates.io/crates/stylus-test) `TestVM`），导出标准 `ISettlementEngine` Solidity ABI。
3. 编写同构 `contracts/src/SolidityClearingBenchmark.sol` 与 Foundry 差分测试套件 `contracts/test/ClearingDifferential.t.sol`，输出 Stylus WASM Ink 折算 Gas 与 EVM Gas 对比模型。

## 验收判据（Acceptance Criteria）

* 同一账户使用不同 `bit_pos` 并发提交多笔 EIP-712 签名意图全部成功，重复提交已消费 `bit_pos` 立即触发 `NonceAlreadyUsed`；
* 篡改 `chainId`、`verifyingContract`、限价或超过 `deadline_epoch` 的意图 100% 拒止；
* Rust 核心、Stylus 合约与 Solidity 基准合约的方法签名、错误选择器及黄金批次结算结果完全一致。
