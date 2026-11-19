# TKT-005：静态架构门禁 `tools/archcheck`、跨平台 `check.sh`/`check.ps1`、CI 与双轴代码审查

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-003`, `TKT-004`
* **Testing Seam**: `Seam S1`–`Seam S4`

## 交付行为（Vertical Slice Behavior）

1. 实现 `tools/archcheck/check.py` 与正反违规夹具测试 `tests/test_archcheck.py`（检查零浮点、禁止核心层 `unwrap()/expect()`、`CONTEXT.md` 零实现污染、Cargo Release WASM 体积优化配置、Rust/Solidity/参考核错误码与 ABI 对齐、文档完备性）。
2. 实现 `scripts/check.sh`、`scripts/check.ps1` 与 `.github/workflows/ci.yml`。
3. 编写参赛中英双语 `README.md`（覆盖架构图解、快速复现命令、Stylus WASM vs Solidity 量化对比与目录索引），执行 Standards + Spec 双轴独立审查，修复全部问题并完成全量门禁与 Git 提交。

## 验收判据（Acceptance Criteria）

* `bash scripts/check.sh` 跑通全部静态门禁、正反违规夹具测试、Python 256 位黄金向量与 EIP-712/位图测试、Node ESM 前端状态机测试，退出码严格为 `0`；
* 注入任一违规负样本时 `tools/archcheck/check.py` 稳定返回非零退出码。
