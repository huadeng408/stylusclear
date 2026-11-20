#!/usr/bin/env python3
"""StylusClear v1.2.0 Static Architecture, Zero-Leak, Script Hygiene & Parity Checker."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
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
    "2-DEPLOY-AND-PUSH.cmd",
    "SHA256SUMS.txt",
    "artifacts/clearing_stylus.wasm",
    "artifacts/clearing_stylus.initcode.hex",
    "artifacts/contracts-compiled.json",
    "contracts/src/ISettlementEngine.sol",
    "contracts/src/SolidityClearingBenchmark.sol",
    "contracts/src/StylusAtomicFactory.sol",
    "deployments/arbitrum-sepolia.json",
    "deployments/robinhood-testnet.json",
    "web/deployments/arbitrum-sepolia.json",
    "web/deployments/robinhood-testnet.json",
    "web/.nojekyll",
    "web/app.mjs",
    "tools/formal/prove_invariants_z3.py",
    "docs/security/z3-formal-proofs.json",
    "docs/assets/gas-comparison-chart.svg",
    "docs/assets/gas-comparison-chart.png",
    "scripts/deploy-robinhood-testnet.sh",
    "scripts/build-final-video.sh",
    "scripts/verify-web-e2e-chromium.py",
]


def _brotli_q11(data: bytes) -> bytes:
    try:
        import brotli

        return brotli.compress(data, quality=11)
    except ImportError:
        b_cli = shutil.which("brotli")
        if b_cli:
            return subprocess.run([b_cli, "-q", "11", "-c"], input=data, capture_output=True, check=True).stdout
        raise RuntimeError("Python brotli or brotli CLI required") from None


def _check_ps1_param_order(text: str) -> bool:
    """Return True if param(...) appears before any executable statement (or is absent)."""
    lines = text.splitlines()
    in_block_comment = False
    for raw in lines:
        s = raw.strip()
        if in_block_comment:
            if "#>" in s:
                in_block_comment = False
            continue
        if not s or s.startswith("#"):
            continue
        if s.startswith("<#"):
            if "#>" not in s:
                in_block_comment = True
            continue
        if s.lower().startswith("[cmdletbinding"):
            continue
        if re.match(r"^param\s*\(", s, re.IGNORECASE):
            return True
        # First non-comment statement is not param(); ensure param() does not appear later at top level
        break
    return re.search(r"(?im)^\s*param\s*\(", text) is None


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

    # 2) Dockerfile.stylus-reproducible must include Cargo.lock, --locked, .cargo, binaryen, and non-root USER
    dk = (root / "Dockerfile.stylus-reproducible").read_text(encoding="utf-8")
    for tok in ("Cargo.lock", "--locked", "binaryen", ".cargo", "USER "):
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
            if "__pycache__" in f.parts or f.name == "check.py" or f.suffix in (".pyc", ".png", ".wasm", ".mp4", ".wav", ".bundle"):
                continue
            txt = f.read_text(encoding="utf-8", errors="ignore")
            for rx, msg in FORBIDDEN_GLOBAL_PATTERNS:
                if rx.search(txt):
                    errors.append(f"{f.relative_to(root)}: {msg}")

    # 5b) Script hygiene: LF without BOM for *.sh, no --private-key CLI arg; CRLF + valid UTF-8 + param() first for *.ps1
    scripts_dir = root / "scripts"
    if scripts_dir.exists():
        for shf in sorted(scripts_dir.glob("*.sh")):
            raw = shf.read_bytes()
            if raw.startswith(b"\xef\xbb\xbf"):
                errors.append(f"{shf.relative_to(root)}: shell script must not contain UTF-8 BOM")
            if b"\r\n" in raw:
                errors.append(f"{shf.relative_to(root)}: shell script must use LF line endings")
            txt = raw.decode("utf-8", errors="replace")
            if re.search(r"--private-key\b", txt):
                errors.append(f"{shf.relative_to(root)}: forbidden plaintext --private-key CLI argument")
        for psf in sorted(scripts_dir.glob("*.ps1")):
            raw = psf.read_bytes()
            try:
                txt = raw.decode("utf-8-sig")
            except UnicodeDecodeError:
                errors.append(f"{psf.relative_to(root)}: PowerShell script is not valid UTF-8")
                continue
            if b"\n" in raw and b"\r\n" not in raw:
                errors.append(f"{psf.relative_to(root)}: PowerShell script must use CRLF line endings")
            if not _check_ps1_param_order(txt):
                errors.append(f"{psf.relative_to(root)}: param(...) block must precede executable statements")

    # 5c) Web CSP & zero innerHTML gate
    web_idx = root / "web" / "index.html"
    if web_idx.exists():
        wtxt = web_idx.read_text(encoding="utf-8")
        if re.search(r"script-src[^;\"']*unsafe-inline", wtxt):
            errors.append("web/index.html CSP script-src must not allow 'unsafe-inline'")
    web_app = root / "web" / "app.mjs"
    if web_app.exists() and ".innerHTML" in web_app.read_text(encoding="utf-8"):
        errors.append("web/app.mjs must not use innerHTML")

    # 5d) Markdown broken URL with unescaped spaces check
    for md_target in [root / "README.md", root / "SUBMISSION.md", *(root / "docs").rglob("*.md")]:
        if md_target.exists() and md_target.is_file():
            mtxt = md_target.read_text(encoding="utf-8", errors="ignore")
            for m in re.finditer(r"\]\((https?://[^)\n]+)\)", mtxt):
                if " " in m.group(1):
                    errors.append(f"{md_target.relative_to(root)}: broken Markdown URL with unescaped spaces: {m.group(1)[:60]}")

    # 5e) CI workflow must install ruff & mypy
    ci_yml = root / ".github" / "workflows" / "ci.yml"
    if ci_yml.exists():
        cit = ci_yml.read_text(encoding="utf-8")
        for req_pkg in ("ruff", "mypy"):
            if req_pkg not in cit:
                errors.append(f".github/workflows/ci.yml missing required QA tool '{req_pkg}'")

    # 5f) Cross-language 19 custom error parity (Solidity ISettlementEngine.sol vs web/rpc-client.ts)
    sol_iface = (root / "contracts" / "src" / "ISettlementEngine.sol").read_text(encoding="utf-8")
    sol_errs = set(re.findall(r"\berror\s+([A-Z][A-Za-z0-9_]+)\s*\(", sol_iface))
    ts_rpc = root / "web" / "rpc-client.ts"
    if ts_rpc.exists() and sol_errs:
        ts_txt = ts_rpc.read_text(encoding="utf-8")
        ts_errs = set(re.findall(r"\berror\s+([A-Z][A-Za-z0-9_]+)\s*\(", ts_txt))
        if sol_errs != ts_errs:
            errors.append(f"Custom error ABI drift between ISettlementEngine.sol ({len(sol_errs)}) and web/rpc-client.ts ({len(ts_errs)})")

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
        wasm_bytes = (root / "artifacts" / "clearing_stylus.wasm").read_bytes()
        actual_sha = hashlib.sha256(wasm_bytes).hexdigest()
        if wb.get("sha256") != actual_sha:
            errors.append(f"artifacts/clearing_stylus.wasm SHA-256 drift: artifact={actual_sha[:16]} vs json={str(wb.get('sha256'))[:16]}")

        # Verify clearing_stylus.initcode.hex matches Brotli-q11(clearing_stylus.wasm) + 0xEFF00000
        comp = _brotli_q11(wasm_bytes)
        payload = b"\xef\xf0\x00\x00" + comp
        plen = len(payload)
        expected_init = bytes([0x61, (plen >> 8) & 0xFF, plen & 0xFF, 0x80, 0x60, 0x0C, 0x60, 0x00, 0x39, 0x60, 0x00, 0xF3]) + payload
        actual_init_hex = (root / "artifacts" / "clearing_stylus.initcode.hex").read_text(encoding="utf-8").strip().lower()
        if actual_init_hex != "0x" + expected_init.hex():
            errors.append("artifacts/clearing_stylus.initcode.hex drifted from artifacts/clearing_stylus.wasm")

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
        if (
            not m_ver
            or m_ver.group(1) != art.get("schema_version")
            or m_ver.group(1) != z3_rep.get("schema_version")
            or m_ver.group(1) != sep.get("schemaVersion")
            or m_ver.group(1) != rob.get("schemaVersion")
        ):
            errors.append("Version mismatch across Cargo.toml, measured-gas-artifacts.json, z3-formal-proofs.json, and deployments/*.json")

        # Verify SHA256SUMS.txt
        sums_file = root / "SHA256SUMS.txt"
        for line in sums_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                errors.append(f"Malformed line in SHA256SUMS.txt: {line}")
                continue
            exp_h, rel_p = parts[0].lower(), parts[1].lstrip("*")
            target_f = root / rel_p
            if not target_f.exists():
                errors.append(f"SHA256SUMS.txt references missing file: {rel_p}")
            else:
                got_h = hashlib.sha256(target_f.read_bytes()).hexdigest()
                if got_h != exp_h:
                    errors.append(f"SHA256SUMS.txt mismatch for {rel_p}: expected {exp_h[:12]} got {got_h[:12]}")

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
