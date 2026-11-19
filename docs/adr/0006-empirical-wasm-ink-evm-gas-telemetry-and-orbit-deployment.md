# ADR-0006：紧凑结构体 ABI、零 Unsafe 实测遥测流水线与 Sepolia/Orbit 双轨部署策略

* **状态**：已采纳（Accepted）
* **日期**：2026-11-17
* **关联术语**：`清算批次`、`结算回执`、`原子拒止回滚`（见 [`CONTEXT.md`](../../CONTEXT.md)）

## 背景与问题

1. 首版 `settleBatch` 使用 17 个散装平行数组，易造成 EVM 栈深压力与前端编码错位；`clearing-stylus` 中使用 `unsafe RawCall` 且缺少子包级 `Stylus.toml` 与 `mini-alloc`；`clearing-cli` 未接入纯 Rust `secp256k1` 恢复导致离线重放带签名批次报错。
2. 基准报告若依赖手写多项式或人工抄录极易在 `README.md` 与报告文件间产生数值漂移。
3. 根据 [Arbitrum 官方新 Stylus 激活暂停公告（2026-10-02）](https://docs.arbitrum.io/notices/stylus-activation-pause-notice)，Arbitrum Security Council 当前在 Arbitrum One 与 Nova 上暂停了新 Stylus 合约的 `activation` 步骤，而 **Arbitrum Sepolia 测试网（Chain ID `421614`）与自定义 Arbitrum Orbit 链完全支持新 Stylus 合约部署与激活**。

## 决策内容

1. **三参数紧凑结构体 ABI 与零 `unsafe` WASM 构建**：
   * 统一 `ISettlementEngine::settleBatch(address[] participants, ObligationInput[] obligations, SignedTradeIntent[] intents)` 结构体签名；
   * 分拆根工作区 `Stylus.toml` 与子包 `crates/clearing-stylus/Stylus.toml`，启用 `stylus-sdk` 的 `mini-alloc` 特性，改用安全高层接口 `stylus_sdk::call::static_call` 调用 `0x01` 预编译并开启 `#![forbid(unsafe_code)]`；
   * 在 `clearing-cli` 与 `clearing-stylus` `[dev-dependencies]` 接入纯 Rust `k256`（`ecdsa`），彻底移除 `OfflineNullVerifier`，实现 100% 黄金向量真实签名重放。
2. **链上 `evm_ink_left()` 遥测 + Foundry 512 位 `mulDiv` 实测单一数据源（Rule `A7`）**：
   * `StylusClearingEngine` 通过 [`self.vm().evm_ink_left()` 与 `ink_to_gas`](https://docs.arbitrum.io/stylus/fundamentals/global-variables-and-functions) 发射 `BatchTelemetry` 与 `MarketCleared` 事件；
   * `SolidityClearingBenchmark.sol` 内置 512 位无中间溢出 `_mulDivFloor`/`_mulDivCeil` 与安全有符号转换，消除 `Panic(0x11)` 漂移；
   * 由 `scripts/generate-benchmarks.py` 维护唯一权威产物 `docs/benchmarks/measured-gas-artifacts.json` 并自动同步渲染 `docs/benchmarks/gas-comparison-report.md` 与 `README.md` 标记区块，由 `tools/archcheck/check.py` 规则 `A7` 强制拦截任何不一致。
3. **Arbitrum Sepolia 实盘激活 + Orbit 机构清算专链双轨交付**：
   * 提供真实浏览器 ESM `web/dist/rpc-client.mjs` JSON-RPC 客户端（`eth_call` / `eth_estimateGas` 双合约同屏对比，连接失败显式报错，绝不静默伪造上链成功）；
   * 面向 **Arbitrum Sepolia (`421614`)** 提供完整部署激活与链上实盘对标脚本，并配套 **Arbitrum Orbit 机构级 L3 清算专链配置**与 `ArbWasmCache` / `codehashKeepalive` 运维规范。

## 权衡与后果

* **正面收益**：完全契合 Arbitrum 生态当前技术现状与 [Open House 评审标准](https://www.hackquest.io/hackathons/Arbitrum-Open-House-Dubai-Online-Buildathon)，实现代码安全性、可编译性、基准真实性与前端可验证性的全闭环。
* **代价与约束**：本机发布前须执行 `bash scripts/check.sh --strict`（或 `pwsh -File scripts/check.ps1 -Strict`）及 `scripts/deploy-sepolia.sh` 刷新真机链上回执。
