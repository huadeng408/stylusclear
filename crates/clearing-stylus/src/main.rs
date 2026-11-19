#![cfg_attr(not(feature = "export-abi"), no_main)]

#[cfg(feature = "export-abi")]
fn main() {
    use std::io::{self, Write};
    let mut out = io::stdout().lock();
    let _ = out.write_all(clearing_stylus::SOLIDITY_ABI_SPEC.as_bytes());
    let _ = out.write_all(b"\n");
}
