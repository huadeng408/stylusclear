# StylusClear Domain Ubiquitous Language (`CONTEXT.md`)

This glossary defines the pure institutional clearing and risk domain terms shared across specifications, architecture records, and operator interfaces.

| Canonical Term (Chinese) | Canonical Term (English) | Domain Definition |
| :--- | :--- | :--- |
| 参与账户 | Participant Account | An institutional trading desk or market maker holding multi-asset collateral and bilateral payables inside the clearing house. |
| 双边确认债务 | Confirmed Bilateral Obligation | A mutually acknowledged payable from a debtor participant to a creditor participant denominated in a registered settlement asset. |
| 多边环路压缩 | Multilateral Cycle Compression | Deterministic graph reduction that identifies directed payable cycles in canonical participant order and cancels the minimum bottleneck obligation without moving collateral. |
| 统一出清价批量拍卖 | Uniform Clearing Price Batch Auction | Discrete-time two-sided call market that selects a single equilibrium clearing price maximizing matched volume within the reference oracle band while guaranteeing per-lot limit-price satisfaction. |
| 风险折算有效抵押品 | Haircut-Adjusted Effective Collateral | Conservative valuation of positive asset holdings after applying asset-specific valuation haircuts against reference mark prices. |
| 初始保证金盈余 | Initial Margin Surplus | Excess of effective collateral over initial margin requirements across all open short liabilities, required before taking new risk. |
| 账户健康度单调性 | Account Health Monotonicity | Fail-closed settlement rule requiring that any participant already below initial margin must strictly improve or preserve net equity and maintenance health across a batch. |
| 强制减仓清算 | Underwater Liquidation | Controlled third-party debt repayment against an account below maintenance health, seizing collateral within an adaptive bonus ceiling while strictly improving borrower health and preserving double-entry conservation. |
| 最小计量尾差归集 | Sub-Quantum Dust Sweep | Accounting closure mechanism for vault assets whose external token granularity is coarser than internal accounting precision, sweeping sub-unit positive dust or closing sub-unit residual debt without stranding collateral. |
