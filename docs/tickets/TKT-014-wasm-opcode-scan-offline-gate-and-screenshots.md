# TKT-014：WASM 字节码零浮点扫描器、`.vm_deps` 离线全工具链门禁与无头 Chromium 高清看板出图

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: `TKT-011`, `TKT-012`, `TKT-013`
* **Testing Seam**: `Seam S3`, `Seam S4`

## 验收标准（Acceptance Criteria）
1. `scripts/generate-benchmarks.py` 内置 WASM 二进制节解析器（校验 Type/Global/Code 节零 `f32`/`f64` 类型与浮点指令）及 Brotli 11 级体积核验（`< 24,576 B`）。
2. `scripts/check.sh --strict --offline` 自动识别并挂载 `.vm_deps`（兼容整包与分卷）完成离线 Rust 1.91 WASM 编译、Foundry 实测校准与 `archcheck --strict` 门禁校验。
3. 通过无头 Chromium (`1440x920`) 渲染保存 `docs/assets/workbench-institutional-mesh.png` 与 `docs/assets/workbench-fail-closed-guard.png`，经 `view_file` 质检无截断后嵌入 `README.md`。
