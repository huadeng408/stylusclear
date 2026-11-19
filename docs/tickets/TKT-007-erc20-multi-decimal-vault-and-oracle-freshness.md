# TKT-007：跨 VM 多精度 `IERC20` 托管金库、喂价时效门禁与完备只读视图/事件

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-006`
* **Testing Seam**: `Seam S1`, `Seam S2`

## 交付行为（Vertical Slice Behavior）

1. 在 Stylus 合约（`sol_interface! IERC20`）与 Solidity 基准合约（`IERC20` + `MockERC20.sol`）实现支持 `decimals <= 18`（如 6 位 `USDC`、8 位 `WBTC`、18 位 `WETH`）自动缩放至 `WAD` 的 `deposit` 与 `withdraw`，提现遵循 Checks-Effects-Interactions 并强制核验提款后保证金充裕度与非透支约束。
2. 增加 `updateMarkPrice` 与 `maxPriceStaleness` 喂价过期门禁（超时报 `StaleMarkPrice`），并将 `seedAccountBalance` 限制在显式开启 `benchmarkSeedingEnabled` 且未绑定真实外部代币的测试槽位。
3. 暴露 `assetCount`、`getAssetConfig`、`getConfirmedObligation`、`getAccountRisk`、`getFeeVault`、`domainSeparator` 只读接口及 `CollateralDeposited`、`CollateralWithdrawn`、`ObligationRegistered`、`MarketCleared` 事件。

## 验收判据（Acceptance Criteria）

* `10,000e6 USDC` 充值精确记账为 `10,000e18 WAD`，持仓占保期间超额提款触发回滚，释放敞口后提款准确退回 `6` 位精度代币；
* 超过 `maxPriceStaleness` 的批次结算触发 `StaleMarkPrice`。
