# ADR-0005：双边债务确权机制、多精度跨 VM 代币托管金库与严苛保证金门禁

* **状态**：已采纳（Accepted）
* **日期**：2026-11-17
* **关联术语**：`已确权应付义务`、`托管抵押金库`、`参考价格时效窗口`、`出清价格保护带`、`最小有效委托量`、`健康度单调性`、`限价个体理性`（见 [`CONTEXT.md`](../../CONTEXT.md)）

## 背景与问题

在首版原型安全审计中暴露出三类关键风险：
1. **未确权应付边伪造风险（`F-01`）**：若 `settleBatch` 允许外部协调者提交未经债务人确认的裸应付边，攻击者可构造指向自身的虚假债务边并在不经过交易撮合的情况下划走受害账户正向余额或强加负债。
2. **等额负债置换绕过初始保证金与微单取整越界（`F-02` / `F-07`）**：仅在名义总负债上升时检查 `初始保证金要求`，会被“低保证金率负债置换高保证金率负债”或“零折扣现金换入高折扣资产”绕过；同时极微额部分成交在向上取整时可能使买方实付金额超出限价 `1 Wei`。
3. **跨虚拟机真实资产存管缺失（`F-02`）**：缺少真实 [Arbitrum Stylus 跨 VM `sol_interface!` 调用](https://docs.arbitrum.io/stylus/how-tos/importing-interfaces) 标准 ERC-20 合约的多精度存取款与喂价新鲜度校验。

## 决策内容

1. **强制双源 `已确权应付义务` 校验**：
   * **模式 0（`PreRegisteredLedger` 链上登记账本）**：债务人本人先行调用 `registerObligation(creditor, assetId, amountWad)` 写入链上 `confirmed_obligations` 映射；批处理引用该应付边时强制校验累计引用额不超过已登记余额，结算成功后扣减对应已登记额度。
   * **模式 1 / 2（`DirectDebtor` 本人直交或 `Eip712Obligation` 离线签名）**：验证 `caller == debtor` 或按 [EIP-712](https://eips.ethereum.org/EIPS/eip-712) 恢复 `ObligationAttestation(address debtor,address creditor,uint8 assetId,uint256 amountWad,uint64 maxEpoch,uint256 nonce)` 签名者等于 `debtor`，并消费债务人 `word_pos + bit_pos` 位图槽位。任何未确权债务一律返回 `UnauthorizedObligation` 或 `InvalidSignature` 回滚。
2. **收紧 Stage 4 保证金门禁、市场规范化与 `最小有效委托量` 量化步长**：
   * 凡账户在批次中发生交易成交或残余净债务扣款（`risk_active`），只要满足“批前 `im_surplus >= 0`”、“批后 `required_im` 增加”或“批后 `total_liability` 增加”任一条件，强制要求 `post_risk.im_surplus_wad >= 0`（否则报 `InsufficientInitialMargin`）；已低于初始保证金线的受限账户仅允许执行 `required_im` 与 `total_liability` 不增且 `im_surplus` 与 `health` 双单调不降的纯减险操作。
   * 强制要求交易对满足 `quote_asset < base_asset`、委托量 `>= MIN_INTENT_AMOUNT_WAD (10^9)`、非零成交出清价偏离 `参考标记价格` 不超过 `max_price_deviation_bps`（默认 `2000 bps = ±20%`），并按自适应量化步长（价格整除 `10^9` 时步长 `10^9`，否则步长 `10^18`）分配成交额，从代数上保证 `quote_in <= floor(fill_base * limit_price / WAD)` 恒成立。
3. **跨 VM `IERC20` 多精度金库与喂价新鲜度门禁**：
   * 资产配置绑定 ERC-20 地址与 `decimals (<= 18)`，`deposit` / `withdraw` 按 `10^(18 - decimals)` 在外部代币最小单位与内部 `WAD` 间无损换算；`withdraw` 遵循 Checks-Effects-Interactions 并在转账前校验提款后不产生裸透支且有负债账户仍满足 `im_surplus >= 0`（否则报 `InsufficientWithdrawableBalance` 或 `InsufficientInitialMargin`）；`seedAccountBalance` 受构造开关 `benchmarkSeedingEnabled` 严格门控且对绑定真实代币的资产默认禁用。
   * `settleBatch` 强制校验各资产 `block_timestamp - price_updated_at <= max_price_staleness`，过期报 `StaleMarkPrice`。

## 权衡与后果

* **正面收益**：彻底消除未授权债务盗币、负债置换穿仓与 1-Wei 限价越界漏洞，并直接展示 Arbitrum Stylus WASM 与 EVM ERC-20 代币合约的原生互操作能力。
* **代价与约束**：`ObligationInput` 结构体增加确权模式与签名元数据字段，通过重构为紧凑 3 参数结构体 ABI 抵消了栈槽开销。
