# ADR-0003：双模意图准入（链上直调 + EIP-712 中继）与无序位图防重放

* **状态**：已采纳（Accepted）
* **日期**：2026-11-17
* **关联术语**：`交易意图`、`授权见证`、`无序防重放槽位`、`批次纪元`、`原子拒止回滚`（见 [`CONTEXT.md`](../../CONTEXT.md)）

## 背景与问题

在批量拍卖清算场景中，高频做市商与跨市场套利机器人通常在链下并行维护多档报价，由批次协调者（Relayer / Keeper）将多方离线签名的 `交易意图` 聚合在单笔 Arbitrum 交易中送入清算合约；与此同时，链上智能合约金库（Vault）或普通交易者也需要不经第三方中继直接提交意图。若采用传统以太坊顺序递增 Nonce（Sequential Nonce），做市商一旦撤回或超时失效某一笔早期报价，后续所有已签发报价将因队头阻塞（Head-of-Line Blocking）集体作废。

## 决策内容

1. **双模 `授权见证` 校验架构**：
   * **模式 A（链上直调 `DirectCaller`）**：调用者直接向合约登记或附带本人意图，鉴权层核验 `msg_sender == intent.trader` 且 `current_epoch <= intent.deadline_epoch`；
   * **模式 B（离线结构化签名 `Eip712Signed`）**：按照 [EIP-712 类型化结构数据哈希与签名标准](https://eips.ethereum.org/EIPS/eip-712)，绑定 `domainSeparator = keccak256(EIP712Domain("StylusClear", "1", chainId, verifyingContract))`，计算 `TradeIntent` 结构哈希并通过宿主 `ecrecover`（或可注入签名验证端口）恢复签名者地址，强制核验非零地址、`recovered == intent.trader`、低阶延展性保护（`s <= secp256k1n / 2`）及 `deadline_epoch` 未过期。
2. **`word_pos + bit_pos` 无序位图防重放（Unordered Bitmap Nonce）**：
   * 将每个 `参与账户` 的 256 位 `nonce` 拆解为高 248 位词索引 `word_pos = nonce >> 8` 与低 8 位比特偏移 `bit_pos = nonce & 0xff`；
   * 状态层维护映射 `nonce_bitmap[trader][word_pos] -> U256`；
   * 消费某槽位时检查 `(word >> bit_pos) & 1 == 0`，若已置位立即报 `ClearingError::NonceAlreadyUsed`；批量清算通过三不变量终审门禁后，将同一 `(trader, word_pos)` 下的多个已消费 `bit_pos` 合并按位或（Bitwise OR）一次性写回存储，兼顾并发灵活性与存储槽复用。

## 权衡与后果

* **正面收益**：单个 256 位存储槽可承载同一交易者 256 笔无序并发意图的防重放状态，热槽修改（Warm SSTORE）相比逐笔独立布尔映射大幅降低存储成本，且完美支持绑定链 ID 与合约地址的跨链/跨部署重放隔离。
* **代价与约束**：客户端与离线签名工具需遵循 `nonce = (word_pos << 8) | bit_pos` 编码约定，我们在 CLI 与交互式前端工作台中统一内置该编码辅助函数。
