# TKT-001：256 位 Checked 定点数学与确定性多边环路压缩最小结算闭环

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: None（根工单）
* **Testing Seam**: `Seam S1`（`clearing_core::execute_clearing_batch` & 同构黄金向量核验接口）

## 交付行为（Vertical Slice Behavior）

1. 实现 `Wad`（`10^18`）与 `SignedWad` 256 位 Checked 定点数运算及安全侧有向舍入（`mul_wad_floor`、`mul_wad_ceil`、`div_wad_floor`、`div_wad_ceil`），任何上溢/下溢/除零返回确定性 `ClearingError`。
2. 实现基于 Canonical-Order DFS 的 `多边环路压缩`，消除单资产与多资产 `义务有向图` 中的全部三角、四角及交叠 `债务环路`，保证所有 `参与账户` 净应收应付头寸严格不变。
3. 打通 `execute_clearing_batch` 根闭环与 `资产守恒` 门禁，同步落地同构 256 位黄金向量首轮红绿单测。

## 验收判据（Acceptance Criteria）

* 三角闭环（A→B 100, B→C 100, C→A 100）完全归零，压缩率 100%；
* 复合交叠多环（含部分瓶颈边）按最小字典序环路确定性压缩至有向无环图（DAG），各账户净余额代数和严格为 0；
* `U256::MAX` 邻域乘法与除零输入精确触发 `MathOverflow` / `DivisionByZero` 回滚。
