# TKT-006：双边债务确权防盗币、保证金置换绕过封堵、市场规范化与限价零越界保护

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: None
* **Testing Seam**: `Seam S1`, `Seam S2`

## 交付行为（Vertical Slice Behavior）

1. 升级应付义务为双源确权模型（`PreRegisteredLedger` 已登记额度核验 + `DirectDebtor` / `Eip712Obligation` `ObligationAttestation` 签名与位图防重放），彻底封堵 `$19,000` 未授权伪造债务边盗币漏洞（`F-01`）。
2. 收紧 Stage 4 初始保证金与健康度单调性门禁：原达标账户主动交易/残余债务交割后、或任何导致 `required_im_wad` / `total_liability_wad` 增加的活动必须满足 `im_surplus_wad >= 0`，封堵低 IM 换高 IM 负债及高折扣资产置换穿仓漏洞。
3. 强制市场规范方向 `quote_asset < base_asset`、委托最小粒度 `MIN_INTENT_AMOUNT_WAD = 10^9`、`max_price_deviation_bps` 偏离熔断及自适应步长分配，消除买方 `1-Wei` 向上取整限价越界（`F-07`）。
4. 修正 `CONTEXT.md` 双向/多边债务环路定义。

## 验收判据（Acceptance Criteria）

* 未登记且无债务人有效签名的应付边 100% 返回 `UnauthorizedObligation` 或 `InvalidSignature`；
* 等额低 IM 债务置换高 IM 债务或现金换高折扣资产跌破 IM 线 100% 返回 `InsufficientInitialMargin`；
* 任意部分成交场景下买方 `quote_in <= floor(fill_base * limit_price_wad / WAD)` 恒成立。
