"""Seam S4 tests: positive and negative regression checks for tools/archcheck/check.py."""
from __future__ import annotations

import shutil
from pathlib import Path

from tools.archcheck.check import check_repo

ROOT = Path(__file__).resolve().parents[1]


def test_s4_current_repo_passes_strict() -> None:
    errs = check_repo(ROOT, strict=True)
    assert errs == [], f"Repo failed strict archcheck: {errs}"


def test_s4_negative_mutations_caught(tmp_path: Path) -> None:
    # Build minimal synthetic tree from current repo essentials
    for rel in [
        "Cargo.toml",
        "Cargo.lock",
        "CONTEXT.md",
        "README.md",
        "SUBMISSION.md",
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
        "scripts/check.sh",
        "scripts/optimize-wasm-mvp.py",
        "scripts/deploy-robinhood-testnet.sh",
        "scripts/build-final-video.sh",
        "docs/benchmarks/measured-gas-artifacts.json",
    ]:
        src = ROOT / rel
        dst = tmp_path / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    for d in ("crates", "docs/tickets"):
        if (ROOT / d).exists():
            shutil.copytree(ROOT / d, tmp_path / d, dirs_exist_ok=True)

    assert check_repo(tmp_path, strict=True) == []

    # Negative 1: port 4173 leak
    (tmp_path / "README.md").write_text("Open http://localhost:4173 now\n", encoding="utf-8")
    assert any("4173" in e for e in check_repo(tmp_path, strict=True))
    shutil.copy2(ROOT / "README.md", tmp_path / "README.md")

    # Negative 2: legacy 500 bps cap leak
    (tmp_path / "SUBMISSION.md").write_text("cap = min(mm_bps, 500)\n", encoding="utf-8")
    assert any("500 bps" in e for e in check_repo(tmp_path, strict=True))
    shutil.copy2(ROOT / "SUBMISSION.md", tmp_path / "SUBMISSION.md")

    # Negative 3: missing --locked in Dockerfile
    (tmp_path / "Dockerfile.stylus-reproducible").write_text("FROM rust:1.85\nCOPY Cargo.toml ./\n", encoding="utf-8")
    assert any("--locked" in e for e in check_repo(tmp_path, strict=True))
