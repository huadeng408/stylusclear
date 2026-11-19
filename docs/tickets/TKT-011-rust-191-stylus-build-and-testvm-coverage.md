# TKT-011：打通 Rust `1.91.0` + `stylus-sdk 0.10.10` 真编译、`TestVM` 跨 VM 全覆盖与 ABI 导出校验

* **Status**: `completed`
* **Spec**: [`SPEC-001`](../specs/SPEC-001-stylusclear-batch-clearing-engine.md)
* **Blocked by**: None
* **Testing Seam**: `Seam S1`, `Seam S2`

## 验收标准（Acceptance Criteria）
1. 根 `Cargo.toml` 为 `k256` 开启 `features = ["ecdsa", "alloc"]`，`clearing-cli` 与 `clearing-stylus` `[dev-dependencies]` 启用 `k256/std`。
2. `crates/clearing-stylus/Cargo.toml` 显式声明 `[[bin]] name = "clearing-stylus-abi"` 并绑定 `required-features = ["export-abi"]`，消除宿主测试与 Clippy 的 WASM `vm_hooks` 链接冲突。
3. `crates/clearing-stylus/src/lib.rs` 补齐 `TestVM` `mock_call`（6 位 `USDC` `deposit`/`withdraw`）、`mock_static_call`（`0x01` `ecrecover`）及带负债过期喂价拒止单测，消除全部 `clippy -D warnings` 告警。
