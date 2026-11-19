# ADR-0001：采用 18 位 Checked 定点整数算术与安全侧有向舍入（零浮点约束）

* **状态**：已采纳（Accepted）
* **日期**：2026-11-17
* **关联术语**：`参考标记价格`、`估值折扣率`、`初始保证金要求`、`维持保证金要求`、`账户健康度`、`原子拒止回滚`（见 [`CONTEXT.md`](../../CONTEXT.md)）

## 背景与问题

`StylusClear` 需要在 Arbitrum Stylus（Rust 编译至 WASM）与等价 Solidity EVM 基准合约中运行完全一致的多边净额冲销、统一出清价求解与跨抵押品保证金核算。根据 [`stylus-sdk 0.10.10` 官方文档](https://docs.rs/crate/stylus-sdk/latest) 与 [Stylus WebAssembly 运行时规范](https://docs.arbitrum.io/stylus/concepts/webassembly)，**Stylus WASM 虚拟机不支持浮点数指令（`f32` / `f64`）及 SIMD**；同时，链上清算引擎若在乘除折算中使用无向截断或未检查溢出算术，极易引发灰尘套利（Dust Drain）导致 `资产守恒` 破裂或高杠杆边缘账户穿仓。

## 决策内容

1. **全链路零浮点禁令**：核心引擎（`clearing-core`）、Stylus 合约（`clearing-stylus`）与 CLI 重放器严禁出现任何 `f32`、`f64` 类型或浮点字面量，由 `tools/archcheck` 静态扫描强制拦截。
2. **256 位 18 位十进制 Checked 定点数（`WAD = 10^18`，`BPS = 10^4`）**：
   * 底层基于 `alloy-primitives`（`U256` / `I256`）封装 `Wad` 与 `SignedWad` 值类型；
   * 所有加、减、乘、除运算一律走 `checked_add` / `checked_sub` / `checked_mul` / `checked_div`，乘除中间态提升至 512 位宽（或无溢出分解算法）防止 `U256 * U256` 中途截断，任何上溢、下溢或除零一律返回显式 `ClearingError::MathOverflow` / `DivisionByZero` 触发 `原子拒止回滚`，禁止使用 `unwrap()`、`expect()` 或 `saturating_*` 掩盖算术异常。
3. **协议安全侧有向舍入（Directional Safety Rounding）**：
   * **估值向下取整（`mul_wad_floor`）**：计算参与账户 `抵押资产` 折后有效价值（$\lfloor \text{Amount} \times \text{Price} \times (1 - \text{Haircut}) / \text{WAD}^2 \rfloor$）时一律向下取整，绝不高估抵押品净值；
   * **义务与保证金向上取整（`mul_wad_ceil`）**：计算 `组合净敞口`、`初始保证金要求` 与 `维持保证金要求` 时一律向上取整，绝不低估风险负债；
   * **拍卖配额余数归零保护**：按比例分摊成交量时采用向下取整（Floor），剩余极小未配平零头按确定性账户顺序逐位补齐或留存未成交，确保总买方成交量与总卖方成交量逐位相等（严格满足 `资产守恒`）。

## 权衡与后果

* **正面收益**：100% 契合 Stylus WASM 无浮点硬件语义，消除跨平台（x86_64、ARM64、WASM32、EVM）舍入漂移，从数学根源上杜绝单 Wei 舍入漏洞侵蚀清算所偿付能力。
* **代价与约束**：相比原生 `u64/u128` 运算，`U256` 宽整数乘除在宿主演算时指令数略多，但在 [Arbitrum Stylus Gas/Ink 定价体系](https://docs.arbitrum.io/stylus/concepts/gas-metering) 下，WASM 线性内存内的 `U256` 循环迭代成本仍比 EVM Solidity 同构实现低一个数量级以上。
