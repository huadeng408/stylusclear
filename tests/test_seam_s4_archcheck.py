"""Seam S4 tests: positive and negative regression checks for tools/archcheck/check.py."""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

from tools.archcheck.check import check_repo

ROOT = Path(__file__).resolve().parents[1]

SYNTHETIC_FILES = (
    "Cargo.toml",
    "Cargo.lock",
    "rust-toolchain.toml",
    "CONTEXT.md",
    "README.md",
    "SUBMISSION.md",
    "Dockerfile.stylus-reproducible",
    "2-DEPLOY-AND-PUSH.cmd",
    "SHA256SUMS.txt",
    "artifacts/clearing_stylus.wasm",
    "artifacts/clearing_stylus.initcode.hex",
    "artifacts/contracts-compiled.json",
    "web/app.mjs",
    "web/index.html",
    "web/rpc-client.ts",
    "web/engine-ui.mjs",
    "web/benchmarks.generated.mjs",
    "web/dist/rpc-client.mjs",
    "web/.nojekyll",
    "deployments/arbitrum-sepolia.json",
    "deployments/robinhood-testnet.json",
    "web/deployments/arbitrum-sepolia.json",
    "web/deployments/robinhood-testnet.json",
    "contracts/src/ISettlementEngine.sol",
    "contracts/src/SolidityClearingBenchmark.sol",
    "contracts/src/StylusAtomicFactory.sol",
    "docs/assets/gas-comparison-chart.svg",
    "docs/assets/gas-comparison-chart.png",
    "docs/assets/workbench-institutional-mesh.png",
    "docs/assets/workbench-fail-closed-guard.png",
    "docs/benchmarks/gas-comparison-report.md",
    "docs/benchmarks/measured-gas-artifacts.json",
    "docs/security/z3-formal-proofs.json",
    "tools/formal/prove_invariants_z3.py",
    "scripts/check.sh",
    "scripts/generate-benchmarks.py",
    "scripts/optimize-wasm-mvp.py",
    "scripts/deploy-common.sh",
    "scripts/deploy-sepolia.sh",
    "scripts/deploy-robinhood-testnet.sh",
    "scripts/demo-sepolia-live.sh",
    "scripts/build-final-video.sh",
    "scripts/verify-web-e2e-chromium.py",
    ".github/workflows/ci.yml",
    ".github/workflows/pages.yml",
)


def _copy_synthetic_repo(tmp_path: Path) -> None:
    for rel in SYNTHETIC_FILES:
        src = ROOT / rel
        dst = tmp_path / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    for d in ("crates", "docs/tickets"):
        if (ROOT / d).exists():
            shutil.copytree(ROOT / d, tmp_path / d, dirs_exist_ok=True)


def test_s4_current_repo_passes_strict() -> None:
    errs = check_repo(ROOT, strict=True)
    assert errs == [], f"Repo failed strict archcheck: {errs}"


def test_s4_negative_mutations_caught(tmp_path: Path) -> None:
    _copy_synthetic_repo(tmp_path)
    assert check_repo(tmp_path, strict=True) == []

    # Negative 1: port 4173 leak
    (tmp_path / "README.md").write_text("Open http://localhost:4173 now\n", encoding="utf-8")
    assert any("4173" in e for e in check_repo(tmp_path, strict=True))
    shutil.copy2(ROOT / "README.md", tmp_path / "README.md")

    # Negative 2: legacy 500 bps cap leak
    (tmp_path / "SUBMISSION.md").write_text("cap = min(mm_bps, 500)\n", encoding="utf-8")
    assert any("500 bps" in e for e in check_repo(tmp_path, strict=True))
    shutil.copy2(ROOT / "SUBMISSION.md", tmp_path / "SUBMISSION.md")

    # Negative 3: missing --locked / 1.100.0 / version_133 in Dockerfile & rust-toolchain.toml
    (tmp_path / "Dockerfile.stylus-reproducible").write_text("FROM rust:1.85\nCOPY Cargo.toml ./\n", encoding="utf-8")
    dk_errs = check_repo(tmp_path, strict=True)
    assert any("--locked" in e for e in dk_errs)
    assert any("1.100.0" in e for e in dk_errs)
    assert any("version_133" in e for e in dk_errs)
    shutil.copy2(ROOT / "Dockerfile.stylus-reproducible", tmp_path / "Dockerfile.stylus-reproducible")

    (tmp_path / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.91.0"\n', encoding="utf-8")
    assert any("1.100.0" in e for e in check_repo(tmp_path, strict=True))
    shutil.copy2(ROOT / "rust-toolchain.toml", tmp_path / "rust-toolchain.toml")

    # Negative 4: pages.yml missing web/app.mjs
    (tmp_path / ".github/workflows/pages.yml").write_text("steps:\n  - run: cp web/index.html _site/\n", encoding="utf-8")
    assert any("web/app.mjs" in e for e in check_repo(tmp_path, strict=True))
    shutil.copy2(ROOT / ".github/workflows/pages.yml", tmp_path / ".github/workflows/pages.yml")

    # Negative 5: deploy script asset key drift, missing atomicFactoryContract, ETH_PRIVATE_KEY & activationGas removal
    orig_sep = (ROOT / "scripts/deploy-sepolia.sh").read_text(encoding="utf-8")
    (tmp_path / "scripts/deploy-sepolia.sh").write_text(orig_sep.replace("assets.usdcMock6", "assets.USDC"), encoding="utf-8", newline="\n")
    assert any("checkpoint asset keys" in e for e in check_repo(tmp_path, strict=True))

    (tmp_path / "scripts/deploy-sepolia.sh").write_text(orig_sep.replace("atomicFactoryContract", "stylusAtomicFactoryAddress"), encoding="utf-8", newline="\n")
    assert any("atomicFactoryContract" in e for e in check_repo(tmp_path, strict=True))
    shutil.copy2(ROOT / "scripts/deploy-sepolia.sh", tmp_path / "scripts/deploy-sepolia.sh")

    orig_common = (ROOT / "scripts/deploy-common.sh").read_text(encoding="utf-8")
    (tmp_path / "scripts/deploy-common.sh").write_text(
        orig_common.replace("activationGas()(uint64)", "stylusVersion()(uint16)") + '\nexport ETH_PRIVATE_KEY="x"\n',
        encoding="utf-8",
        newline="\n",
    )
    cm_errs = check_repo(tmp_path, strict=True)
    assert any("activationGas()" in e for e in cm_errs)
    assert any("ETH_PRIVATE_KEY" in e for e in cm_errs)
    shutil.copy2(ROOT / "scripts/deploy-common.sh", tmp_path / "scripts/deploy-common.sh")


def test_s4_catches_broken_ps1_param_order() -> None:
    from tools.archcheck.check import _check_ps1_param_order

    assert _check_ps1_param_order('param([string]$TargetDir = "C:\\a")\n$ErrorActionPreference = "Stop"\n') is True
    assert _check_ps1_param_order('$ErrorActionPreference = "Stop"\nparam([string]$TargetDir = "C:\\a")\n') is False


def test_s4_render_from_json_keeps_sha256sums_strict_valid(tmp_path: Path) -> None:
    _copy_synthetic_repo(tmp_path)
    art_p = tmp_path / "docs/benchmarks/measured-gas-artifacts.json"
    art = json.loads(art_p.read_text(encoding="utf-8"))
    art["calibration_status"] = "dual_chain_onchain_verified"
    art_p.write_text(json.dumps(art, indent=2) + "\n", encoding="utf-8", newline="\n")

    subprocess.run([sys.executable, str(tmp_path / "scripts/generate-benchmarks.py"), "--render-from-json"], check=True)
    assert check_repo(tmp_path, strict=True) == []
