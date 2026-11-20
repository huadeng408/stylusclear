#!/usr/bin/env python3
"""Official Binaryen wasm-opt reproducible WASM 1.0 MVP pipeline (AIP-31605 compliant).

Performs ZERO custom WASM binary section splicing or Python byte mutation.
Lowers bulk-memory and sign-extension ops solely through official Binaryen passes,
then validates strict WASM 1.0 MVP compliance via `wasm-opt --mvp-features` and
measures Brotli-q11 size (< 24,576 B legacy cap; < 98,304 B ArbOS 61 cap).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


def find_wasm_opt() -> str:
    candidates = [
        shutil.which("wasm-opt"),
        str(Path.home() / ".cache/stylusclear_entity_sandbox/bin/wasm-opt"),
    ]
    for c in candidates:
        if c and Path(c).exists():
            return c
    raise RuntimeError("wasm-opt not found in PATH or stylusclear_entity_sandbox")


def brotli_q11_size(data: bytes) -> int:
    try:
        import brotli  # type: ignore
        return len(brotli.compress(data, quality=11))
    except ImportError:
        b_cli = shutil.which("brotli")
        if b_cli:
            proc = subprocess.run([b_cli, "-q", "11", "-c"], input=data, capture_output=True, check=True)
            return len(proc.stdout)
        raise RuntimeError("Python 'brotli' module or 'brotli' CLI required") from None


def optimize_to_mvp(src: Path, dst: Path) -> dict:
    wasm_opt = find_wasm_opt()
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        wasm_opt,
        str(src),
        "-o",
        str(dst),
        "--enable-bulk-memory",
        "--enable-sign-ext",
        "--llvm-memory-copy-fill-lowering",
        "--signext-lowering",
        "-Oz",
        "--converge",
        "--low-memory-unused",
        "--zero-filled-memory",
        "--duplicate-function-elimination",
        "--merge-similar-functions",
        "--merge-blocks",
        "--code-folding",
        "--coalesce-locals-learning",
        "--reorder-functions",
        "--reorder-locals",
        "--strip-debug",
        "--strip-producers",
        "--strip-target-features",
        "--strip-dwarf",
    ]
    subprocess.run(cmd, check=True)
    # Strict WASM 1.0 MVP validator pass (rejects any 0xC0..0xC4 sign-ext, 0xFC bulk-memory, 0xFD SIMD, float, or reftype)
    subprocess.run([wasm_opt, "--mvp-features", str(dst), "-o", os.devnull], check=True)

    dis_name = "wasm-dis.exe" if sys.platform == "win32" else "wasm-dis"
    dis_tool = str(Path(wasm_opt).with_name(dis_name))
    zero_float = False
    if Path(dis_tool).exists():
        wat = subprocess.run([dis_tool, str(dst)], capture_output=True, text=True, encoding="utf-8", errors="replace", check=True).stdout
        if re.search(r"\b(f32|f64)\.", wat) or re.search(r"memory\.(copy|fill)|i(32|64)\.extend(8|16|32)_s", wat):
            raise RuntimeError("Post-MVP or floating-point opcode detected in optimized WASM")
        zero_float = True

    raw = dst.read_bytes()
    b_len = brotli_q11_size(raw)
    if b_len + 4 > 24_576:
        raise RuntimeError(f"Brotli-q11 + 4B Stylus header ({b_len + 4} B) exceeds 24,576 B legacy Stylus limit")
    return {
        "wasm_path": str(dst),
        "wasm_raw_bytes": len(raw),
        "wasm_brotli_q11_bytes": b_len,
        "wasm_brotli_with_header_bytes": b_len + 4,
        "legacy_24kb_headroom_bytes": 24_576 - (b_len + 4),
        "arbos61_96kb_headroom_bytes": 98_304 - (b_len + 4),
        "wasm_sha256": hashlib.sha256(raw).hexdigest(),
        "zero_float_opcodes_verified": zero_float,
        "zero_post_mvp_opcodes_verified": True,
        "custom_byte_mutation": False,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    meta = optimize_to_mvp(args.input, args.output)
    if args.json:
        print(json.dumps(meta, indent=2))
    else:
        print(
            f"[optimize-wasm-mvp] OK raw={meta['wasm_raw_bytes']}B "
            f"brotli_q11={meta['wasm_brotli_q11_bytes']}B sha256={meta['wasm_sha256'][:16]}..."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
