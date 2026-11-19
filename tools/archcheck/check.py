#!/usr/bin/env python3
"""StylusClear v1.0.0 Static Architecture, Zero-Leak & Six-Endpoint Parity Checker."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

FORBIDDEN_GLOBAL_PATTERNS = [
    (re.compile(r"min\(\s*mm_bps\s*,\s*500"), "Legacy 500 bps liquidation cap drift"),
    (re.compile(r"localhost:4173|127\.0\.0\.1:4173|:4173\b"), "Legacy port 4173 reference (must use 8080)"),
    (re.compile(r"ready-for-agent|subagent_id|invoke_subagent"), "Internal agent workflow token leak"),
    (re.compile(r"nonceWord\s*=\s*900_?001n"), "Hardcoded one-shot demo nonceWord=900_001n"),
    (re.compile(r"/home/spark/\.cache/stylusclear_entity_sandbox"), "Sandbox absolute path leak in repository"),
]

REQUIRED_FILES = [
    "Cargo.toml",
    "Cargo.lock",
    "Dockerfile.stylus-reproducible",
    "artifacts/clearing_stylus.wasm",
    "contracts/src/ISettlementEngine.sol",
    "contracts/src/SolidityClearingBenchmark.sol",
    "contracts/src/StylusAtomicFactory.sol",
    "deployments/arbitrum-sepolia.json",
    "deployments/robinhood-testnet.json",
    "web/deployments/arbitrum-sepolia.json",
    "web/deployments/robinhood-testnet.json",
    "web/.nojekyll",
    "tools/formal/prove_invariants_z3.py",
    "docs/security/z3-formal-proofs.json",
    "scripts/deploy-robinhood-testnet.sh",
    "scripts/build-final-video.sh",
]


def check_repo(root: Path, strict: bool = False) -> list[str]:
    errors: list[str] = []
    for rel in REQUIRED_FILES:
        if not (root / rel).exists():
            errors.append(f"Missing required file: {rel}")

    if errors:
        return errors

    # 0) No stale duplicate formal verification report
    if (root / "docs" / "benchmarks" / "formal-verification-report.json").exists():
        errors.append("Stale duplicate docs/benchmarks/formal-verification-report.json must be removed")

    # 1) CONTEXT.md pure domain vocabulary check (Rule A1)
    ctx_text = (root / "CONTEXT.md").read_text(encoding="utf-8")
    for banned in ("U256", "I256", "uint256"):
        if re.search(rf"\b{re.escape(banned)}\b", ctx_text):
            errors.append(f"CONTEXT.md leaks implementation token: {banned}")
    if re.search(r"(?<!\S)\.(?:rs|sol)\b|\w\.(?:rs|sol)\b", ctx_text):
        errors.append("CONTEXT.md leaks .rs/.sol file extension")

    # 2) Dockerfile.stylus-reproducible must include Cargo.lock, --locked, .cargo, and binaryen
    dk = (root / "Dockerfile.stylus-reproducible").read_text(encoding="utf-8")
    for tok in ("Cargo.lock", "--locked", "binaryen", ".cargo"):
        if tok not in dk:
            errors.append(f"Dockerfile.stylus-reproducible missing '{tok}'")

    # 3) check.sh must NOT monkey-patch stylus-sdk
    chk = (root / "scripts" / "check.sh").read_text(encoding="utf-8")
    if "sed -i" in chk and "stylus-sdk" in chk:
        errors.append("scripts/check.sh contains forbidden stylus-sdk monkey-patch")

    # 4) optimize-wasm-mvp.py must NOT mutate custom WASM binary sections manually
    opt_py = (root / "scripts" / "optimize-wasm-mvp.py").read_text(encoding="utf-8")
    if '"custom_byte_mutation": False' not in opt_py or "wasm-opt" not in opt_py:
        errors.append("scripts/optimize-wasm-mvp.py must use official wasm-opt with zero byte mutation")

    # 5) Scan source & docs for forbidden patterns
    scan_dirs = ["crates", "contracts", "scripts", "tools", "web", "docs", "README.md", "SUBMISSION.md"]
    for item in scan_dirs:
        p = root / item
        files = [p] if p.is_file() else [f for f in p.rglob("*") if f.is_file()]
        for f in files:
            if "__pycache__" in f.parts or f.name in ("check.py", "check.sh", "verify-judge-60s.sh") or f.suffix in (".pyc", ".png", ".wasm", ".mp4", ".wav", ".bundle"):
                continue
            txt = f.read_text(encoding="utf-8", errors="ignore")
            for rx, msg in FORBIDDEN_GLOBAL_PATTERNS:
                if rx.search(txt):
                    errors.append(f"{f.relative_to(root)}: {msg}")

    # 6) Ticket DAG metadata check
    tickets_dir = root / "docs" / "tickets"
    if tickets_dir.exists():
        for tf in sorted(tickets_dir.glob("TKT-*.md")):
            ttxt = tf.read_text(encoding="utf-8")
            if not (re.search(r"Blocked\s+by\b", ttxt, re.IGNORECASE) and re.search(r"Seam\b", ttxt, re.IGNORECASE)):
                errors.append(f"{tf.relative_to(root)}: missing 'Blocked by:' or 'Testing Seam:'")

    # 7) Dual-chain deployment schema parity & web/deployments mirror parity
    sep = json.loads((root / "deployments" / "arbitrum-sepolia.json").read_text(encoding="utf-8"))
    rob = json.loads((root / "deployments" / "robinhood-testnet.json").read_text(encoding="utf-8"))
    web_sep = json.loads((root / "web" / "deployments" / "arbitrum-sepolia.json").read_text(encoding="utf-8"))
    web_rob = json.loads((root / "web" / "deployments" / "robinhood-testnet.json").read_text(encoding="utf-8"))
    if sep != web_sep:
        errors.append("deployments/arbitrum-sepolia.json drifted from web/deployments/arbitrum-sepolia.json")
    if rob != web_rob:
        errors.append("deployments/robinhood-testnet.json drifted from web/deployments/robinhood-testnet.json")
    if sep.get("chainId") != 421614 or len(sep.get("assets", {})) != 4:
        errors.append("deployments/arbitrum-sepolia.json must target chainId 421614 with 4 assets")
    if rob.get("chainId") != 46630 or len(rob.get("assets", {})) != 4:
        errors.append("deployments/robinhood-testnet.json must target chainId 46630 with 4 assets")

    if strict:
        art = json.loads((root / "docs" / "benchmarks" / "measured-gas-artifacts.json").read_text(encoding="utf-8"))
        if art.get("calibration_status") not in (
            "host_replay_analytical_and_foundry_measured",
            "host_wasm_and_foundry_measured",
            "arbitrum_sepolia_onchain_verified",
            "dual_chain_onchain_verified",
        ):
            errors.append(f"Uncalibrated benchmark status: {art.get('calibration_status')}")
        wb = art.get("wasm_binary", {})
        if not (0 < int(wb.get("brotli_q11_bytes", 99999)) + 4 <= 24_576):
            errors.append("WASM Brotli-q11 size + 4B header exceeds 24,576 B cap")
        actual_sha = hashlib.sha256((root / "artifacts" / "clearing_stylus.wasm").read_bytes()).hexdigest()
        if wb.get("sha256") != actual_sha:
            errors.append(f"artifacts/clearing_stylus.wasm SHA-256 drift: artifact={actual_sha[:16]} vs json={str(wb.get('sha256'))[:16]}")
        for w in art.get("workloads", []):
            if int(w.get("solidity_evm_gas", 32_000_000)) >= 32_000_000:
                errors.append(f"Workload {w.get('tier')} exceeds 32M Arbitrum block gas cap")

        z3_rep = json.loads((root / "docs" / "security" / "z3-formal-proofs.json").read_text(encoding="utf-8"))
        if not z3_rep.get("all_unsat") or int(z3_rep.get("theorems_proved", 0)) < 6:
            errors.append("z3-formal-proofs.json must have 6/6 PROVED_UNSAT")
        fuzz = z3_rep.get("hypothesis_differential_fuzz", {})
        if not fuzz.get("cli_replay_cross_checked") or int(fuzz.get("cli_binary_differential_examples", 0)) < 50:
            errors.append("z3-formal-proofs.json must have cli_replay_cross_checked=true with >=50 CLI differential examples")

        cargo_txt = (root / "Cargo.toml").read_text(encoding="utf-8")
        m_ver = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', cargo_txt)
        if not m_ver or m_ver.group(1) != art.get("schema_version") or m_ver.group(1) != z3_rep.get("schema_version"):
            errors.append("Version mismatch across Cargo.toml, measured-gas-artifacts.json, and z3-formal-proofs.json")

    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", type=Path, default=Path("."))
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    errs = check_repo(args.root.resolve(), strict=args.strict)
    if errs:
        for e in errs:
            print(f"[archcheck] FAIL: {e}", file=sys.stderr)
        return 1
    tag = "[strict-calibrated]" if args.strict else "[standard]"
    print(f"[archcheck] OK {tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
