# ADR-0004：Cargo 三层同心圆工作区与跨环境逐位黄金向量验证架构

* **状态**：已采纳（Accepted）
* **日期**：2026-11-17
* **关联术语**：`清算批次`、`结算回执`、`原子拒止回滚`（见 [`CONTEXT.md`](../../CONTEXT.md)）

## 背景与问题

项目同时面临两项工程诉求：
1. 在本机（Windows 11 + WSL2）及 Arbitrum Sepolia / Orbit 链上，代码需遵循 [Arbitrum 官方 Rust 跨链端共享类型最佳实践](https://blog.arbitrum.foundation/rust-onchain-a-backend-engineers-guide-to-stylus/)，通过 [`stylus-sdk 0.10.10`](https://docs.rs/crate/stylus-sdk/latest)、[`stylus-test`](https://crates.io/crates/stylus-test) 与 Foundry `forge test` 完成链上 WASM 与等价 Solidity 基准合约的 ABI 互操作及差分 Gas 对标；
2. 在受限无网云端 CI / 评审环境中，容器未必预装 `rustc` 与 `foundry`，依据仓库工程规范（见 `agents.md` 第五节自动检查），验证门禁绝不允许退化为“仅做文本检查而跳过核心业务逻辑测试”。

## 决策内容

1. **Rust Cargo Workspace 三层同心圆解耦**：
   * `crates/clearing-core`：`#![cfg_attr(not(feature = "std"), no_std)]` + `extern crate alloc` 纯领域算法与 256 位 Checked 定点数学核，零宿主环境依赖，暴露最高层确定性函数接口 `execute_clearing_batch(...) -> Result<BatchOutcome, ClearingError>`；
   * `crates/clearing-stylus`：薄存储与 ABI 外壳，使用 `sol_storage!`、`#[entrypoint]` 与 `#[public]` 桥接链上状态槽、EIP-712 宿主 `ecrecover` 与事件发射，并集成 `stylus-test::TestVM` 合约级单测；
   * `crates/clearing-cli`：开启 `std` 特性的命令行确定性重放器与 Stylus Ink / Solidity Gas 量化基准报告生成器。
2. **同构 Solidity 基准与黄金测试向量（Golden Vectors）双轨核验**：
   * 在 `contracts/src/SolidityClearingBenchmark.sol` 中使用 Solidity 0.8.24 实现与 `clearing-core` 相同数学规约的环路压缩、统一出清拍卖与保证金校验，由 `contracts/test/ClearingDifferential.t.sol` 对照同一批黄金向量执行 ABI 与 Gas 差分断言；
   * 在 `tests/vectors/golden_batches.json` 固化标准清算批次、极端溢出边界、恶意重放与不变量违例回滚向量，并配套零外部依赖的 Python 3.11 原生大整数同构核验引擎（`tools/ref_sim/`）与 Node.js ESM 前端核心单测（`node --test`）；
   * 统一入口 `scripts/check.sh` 与 `scripts/check.ps1` 强制串联：① `tools/archcheck` 静态架构门禁（含正反违规夹具自检）→ ② Python/Node 256 位逐位黄金向量与前端逻辑全量单测 → ③ 自动探测并在具备 `cargo` / `forge` 时执行 `cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace`、`cargo stylus check` 与 `forge test`。

## 权衡与后果

* **正面收益**：既保证了本机与链上原生 Arbitrum Stylus 0.10.10 工程规范 100% 正宗可编译部署，又使任何无 Rust/Foundry 的轻量 CI 容器也能跑通真实的 256 位定点算术、图环路消解、EIP-712 验签与架构门禁红绿回归。
* **代价与约束**：Rust `clearing-core`、Solidity `SolidityClearingBenchmark.sol` 与 `tools/ref_sim` 必须共享同一份 `golden_batches.json` 契约定义，由 `tools/archcheck` 强制校验三端错误码、常量与 ABI 签名严格同步。
