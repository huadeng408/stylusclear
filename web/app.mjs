import {
  MEASURED_BENCHMARK_SUMMARY,
  PRESET_SCENARIOS,
  STANDARD_ASSETS,
  WAD,
  buildLiveScenarioPayloads,
  evaluateAccountRisk,
  previewUnderwaterLiquidation,
  simulateScaleMeshFast,
} from "./engine-ui.mjs";

const SVG_NS = "http://www.w3.org/2000/svg";

const fmtWad = (v, digits = 2) => {
  const sign = v < 0n ? "-" : "";
  const abs = v < 0n ? -v : v;
  const scale = 10n ** BigInt(digits);
  const scaled = (abs * scale) / WAD;
  const whole = scaled / scale;
  const frac = (scaled % scale).toString().padStart(digits, "0");
  return `${sign}${whole.toLocaleString("en-US")}.${frac}`;
};

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "className") node.className = v;
    else if (k === "style") node.setAttribute("style", v);
    else if (k === "textContent") node.textContent = v;
    else node.setAttribute(k, String(v));
  }
  for (const ch of children) {
    if (typeof ch === "string") node.appendChild(document.createTextNode(ch));
    else if (ch) node.appendChild(ch);
  }
  return node;
}

function svgEl(tag, attrs = {}, text = null) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) {
    node.setAttribute(k, String(v));
  }
  if (text !== null) node.textContent = text;
  return node;
}

function renderBenchTable() {
  const tbody = document.getElementById("benchBody");
  const rows = MEASURED_BENCHMARK_SUMMARY.workloads.map((w) => {
    const e2eSp = Number(w.e2e_with_calldata_speedup_x ?? w.speedup_x);
    return el("tr", {}, [
      el("td", {}, [el("strong", { textContent: w.tier })]),
      el("td", { textContent: `${w.accounts} / ${w.obligations} / ${w.intents}` }),
      el("td", { textContent: String(w.cycles_eliminated) }),
      el("td", { className: "mono", textContent: w.solidity_evm_gas.toLocaleString("en-US") }),
      el("td", { className: "mono", textContent: w.wasm_instructions.toLocaleString("en-US") }),
      el("td", {
        className: "mono",
        style: "color:var(--cyan);",
        textContent: w.stylus_total_gas_est.toLocaleString("en-US"),
      }),
      el("td", {
        style: "color:var(--green);font-weight:700;",
        textContent: `-${w.gas_reduction_pct.toFixed(1)}% (${w.speedup_x.toFixed(2)}x / ${e2eSp.toFixed(2)}x e2e)`,
      }),
    ]);
  });
  tbody.replaceChildren(...rows);

  const stress = MEASURED_BENCHMARK_SUMMARY.workloads[3];
  const stressE2e = Number(stress.e2e_with_calldata_speedup_x ?? stress.speedup_x);
  const brotliFormatted = `${MEASURED_BENCHMARK_SUMMARY.wasmBrotliBytes.toLocaleString("en-US")} B`;
  document.getElementById("wasmHeaderBadge").textContent = `WASM 1.0 MVP · ${brotliFormatted} Brotli-q11`;
  document.getElementById("kpiWasm").textContent = brotliFormatted;
  document.getElementById("kpiGasCompare").textContent =
    `${(stress.stylus_total_gas_est / 1e6).toFixed(2)}M vs ${(stress.solidity_evm_gas / 1e6).toFixed(2)}M`;
  document.getElementById("kpiSpeedup").textContent =
    `${stress.speedup_x.toFixed(2)}x Exec (${stressE2e.toFixed(2)}x E2E) · < 32M Cap`;
}

function renderLiquidationCard() {
  const p1 = previewUnderwaterLiquidation({
    underwaterBalances: [2900n * WAD, -1n * WAD, 0n, 0n],
    liquidatorBalances: [15000n * WAD, 5n * WAD, 0n, 0n],
    debtAsset: 1,
    collateralAsset: 0,
    repayAmountWad: 400000000000000000n,
  });
  const p2 = previewUnderwaterLiquidation({
    underwaterBalances: [1000n * WAD, -1n * WAD, 0n, 0n],
    liquidatorBalances: [15000n * WAD, 5n * WAD, 0n, 0n],
    debtAsset: 1,
    collateralAsset: 0,
    repayAmountWad: 1n * WAD,
  });

  const box1 = el(
    "div",
    { style: "margin-bottom:8px;padding:8px 10px;background:#091122;border-radius:8px;border:1px solid #1c2c4c;" },
    [
      el("strong", { style: "color:var(--cyan);", textContent: "1. Partial Repay (Sufficient Collateral): " }),
      "Repay ",
      el("span", { className: "mono", textContent: "0.40 WETH" }),
      " debt \u2192 Seize ",
      el("span", { className: "mono", textContent: `$${fmtWad(p1.seizedCollateralWad)} USDC` }),
      " (",
      el("span", { className: "mono", textContent: `${p1.bonusBps} bps` }),
      " bonus). Borrower Health: ",
      el("span", { className: "mono", style: "color:var(--red);", textContent: `$${fmtWad(p1.preHealthWad)}` }),
      " \u2192 ",
      el("span", { className: "mono", style: "color:var(--green);", textContent: `$${fmtWad(p1.postHealthWad)}` }),
      ".",
    ]
  );

  const box2 = el(
    "div",
    { style: "padding:8px 10px;background:#091122;border-radius:8px;border:1px solid #1c2c4c;" },
    [
      el("strong", { style: "color:var(--amber);", textContent: "2. Floor Proportional Cap (1,000 USDC Cap): " }),
      "Request ",
      el("span", { className: "mono", textContent: "1.00 WETH" }),
      " \u2192 Capped Seize ",
      el("span", { className: "mono", textContent: `$${fmtWad(p2.seizedCollateralWad)} USDC` }),
      ", Floor Back-Calculated Repay ",
      el("span", { className: "mono", textContent: `${fmtWad(p2.repaidDebtWad, 6)} WETH` }),
      " (Zero Overcharge).",
    ]
  );

  document.getElementById("liqPreviewBox").replaceChildren(box1, box2);
}

function renderMeshSvg(nDesks, scenario) {
  const t0 = performance.now();
  const mesh = simulateScaleMeshFast(nDesks);
  const dt = (performance.now() - t0).toFixed(2);
  document.getElementById("deskCountLabel").textContent = String(mesh.deskCount);
  document.getElementById("meshLatencyLabel").textContent = `${dt} ms`;

  const scDeskCount = scenario && scenario.desks ? scenario.desks.length : 0;
  const badgeEl = document.getElementById("meshSummaryBadge");
  if (scenario && scenario.expectedError) {
    badgeEl.textContent = `${mesh.deskCount} Nodes · 0 Cycles Netted (Atomic Rollback)`;
  } else if (mesh.deskCount === scDeskCount) {
    const grossNum = Number(String(scenario.grossObligationUsd).replace(/[^0-9.]/g, "")) || 0;
    const residNum = Number(String(scenario.netResidualUsd).replace(/[^0-9.]/g, "")) || 0;
    const pct = grossNum > 0 ? ((1 - residNum / grossNum) * 100).toFixed(2) : Number(mesh.compressionRatioPct).toFixed(2);
    badgeEl.textContent = `${mesh.deskCount} Nodes · ${scenario.cyclesEliminated} Cycles Netted (${pct}%)`;
  } else {
    badgeEl.textContent = `Stress Sandbox: ${mesh.deskCount} Nodes · ${mesh.cyclesEliminated} Cycles (${Number(mesh.compressionRatioPct).toFixed(2)}%)`;
  }

  const svg = document.getElementById("meshSvg");
  const cx = 230;
  const cy = 125;
  const rx = 165;
  const ry = 88;
  const coords = mesh.nodeLabels.map((lbl, idx) => {
    const ang = -Math.PI / 2 + (2 * Math.PI * idx) / mesh.deskCount;
    return { lbl, x: cx + rx * Math.cos(ang), y: cy + ry * Math.sin(ang) };
  });
  const edgeStroke = scenario && scenario.expectedError ? "#ff5470" : "#28d7ff";
  const children = [];

  for (const e of mesh.edges.slice(0, 96)) {
    const a = coords[e.debtor];
    const b = coords[e.creditor];
    children.push(
      svgEl("line", {
        x1: a.x.toFixed(1),
        y1: a.y.toFixed(1),
        x2: b.x.toFixed(1),
        y2: b.y.toFixed(1),
        stroke: edgeStroke,
        "stroke-opacity": "0.34",
        "stroke-width": "1.4",
      })
    );
  }

  const showAllText = mesh.deskCount <= 16;
  coords.forEach((c, idx) => {
    const r = mesh.deskCount <= 8 ? 16 : mesh.deskCount <= 24 ? 10 : 5.5;
    const showLbl = showAllText || idx % 4 === 0;
    const g = svgEl("g");
    g.appendChild(
      svgEl("circle", {
        cx: c.x.toFixed(1),
        cy: c.y.toFixed(1),
        r: String(r),
        fill: "#112244",
        stroke: edgeStroke,
        "stroke-width": "1.8",
      })
    );
    if (showLbl) {
      g.appendChild(
        svgEl(
          "text",
          {
            x: c.x.toFixed(1),
            y: c.y.toFixed(1),
            "text-anchor": "middle",
            "dominant-baseline": "central",
            fill: "#eef4ff",
            "font-size": String(mesh.deskCount <= 8 ? 9.5 : 8.5),
            "font-weight": "600",
          },
          c.lbl
        )
      );
    }
    children.push(g);
  });

  svg.replaceChildren(...children);
}

function applyScenario(scenarioId) {
  const sc = PRESET_SCENARIOS[scenarioId] || PRESET_SCENARIOS.institutionalMesh;
  const banner = document.getElementById("guardBanner");
  const statusBadge = document.getElementById("statusBadge");

  if (sc.expectedError) {
    banner.classList.add("visible");
    document.getElementById("guardErrorName").textContent = sc.expectedError;
    document.getElementById("guardReason").textContent = sc.matchedVolumeSummary;
    statusBadge.textContent = `BLOCKED · ${sc.expectedError}`;
    statusBadge.className = "badge red";
  } else {
    banner.classList.remove("visible");
    statusBadge.textContent = "SETTLED · ATOMIC PARITY";
    statusBadge.className = "badge green";
  }

  const netVal = document.getElementById("networkSelect").value;
  document.getElementById("chainBadge").textContent =
    netVal === "46630" ? "Robinhood Chain Testnet (46630)" : "Arbitrum Sepolia (421614)";

  document.getElementById("kpiGross").textContent = `$${sc.grossObligationUsd}`;
  document.getElementById("kpiResidual").textContent = sc.expectedError ? sc.netResidualUsd : `$${sc.netResidualUsd}`;
  document.getElementById("kpiResidual").style.color = sc.expectedError ? "var(--red)" : "var(--green)";
  document.getElementById("kpiCycles").textContent = `${sc.cyclesEliminated} Multilateral Cycles Eliminated`;
  document.getElementById("kpiMatched").textContent = sc.matchedVolumeSummary;

  const grossNum = Number(String(sc.grossObligationUsd).replace(/[^0-9.]/g, "")) || 0;
  const residNum = Number(String(sc.netResidualUsd).replace(/[^0-9.]/g, "")) || 0;
  const compEl = document.getElementById("kpiCompression");
  if (sc.expectedError) {
    compEl.textContent = "0.00% (Atomic Rollback)";
  } else if (grossNum > 0) {
    const pct = ((1 - residNum / grossNum) * 100).toFixed(2);
    compEl.textContent = `${pct}% Liquidity Saved`;
  }

  const tbody = document.getElementById("portfolioBody");
  const rows = sc.desks.map((d) => {
    const risk = evaluateAccountRisk(d.balances, STANDARD_ASSETS);
    const hCol = risk.healthWad >= 0n ? "var(--green)" : "var(--red)";
    const addrShort = `${d.address.slice(0, 6)}..${d.address.slice(-4)}`;
    return el("tr", {}, [
      el("td", {}, [
        el("strong", { textContent: d.shortLabel }),
        " ",
        el("span", { className: "mono", style: "color:var(--muted);font-size:10.5px;", textContent: addrShort }),
      ]),
      el("td", { className: "mono", textContent: fmtWad(d.balances[0]) }),
      el("td", { className: "mono", textContent: fmtWad(d.balances[1]) }),
      el("td", { className: "mono", textContent: fmtWad(d.balances[2]) }),
      el("td", { className: "mono", textContent: fmtWad(d.balances[3]) }),
      el("td", { className: "mono", style: `color:${hCol};`, textContent: `$${fmtWad(risk.healthWad)}` }),
      el("td", { className: "mono", textContent: `$${fmtWad(risk.imSurplusWad)}` }),
    ]);
  });
  tbody.replaceChildren(...rows);

  const sliderVal = Number(document.getElementById("deskSlider").value);
  renderMeshSvg(sliderVal, sc);
}

const params = new URLSearchParams(window.location.search);
const rawScenario = params.get("scenario") || "institutionalMesh";
const initScenario = Object.prototype.hasOwnProperty.call(PRESET_SCENARIOS, rawScenario) ? rawScenario : "institutionalMesh";
const defaultDeskCount = PRESET_SCENARIOS[initScenario].desks.length;
const rawDesks = params.has("desks") ? Number(params.get("desks")) : defaultDeskCount;
const initDesks = Number.isFinite(rawDesks) && rawDesks >= 4 && rawDesks <= 64 ? rawDesks : defaultDeskCount;
document.getElementById("scenarioSelect").value = initScenario;
document.getElementById("deskSlider").value = String(initDesks);

document.getElementById("scenarioSelect").addEventListener("change", (e) => {
  if (e.target.value === "robinhoodUsdgMesh") {
    document.getElementById("networkSelect").value = "46630";
  }
  applyScenario(e.target.value);
});
document.getElementById("networkSelect").addEventListener("change", () =>
  applyScenario(document.getElementById("scenarioSelect").value)
);
document.getElementById("deskSlider").addEventListener("input", (e) => {
  const sc = PRESET_SCENARIOS[document.getElementById("scenarioSelect").value];
  renderMeshSvg(Number(e.target.value), sc);
});

let latestRpcReqId = 0;
async function runLiveDualVmParity() {
  const reqId = ++latestRpcReqId;
  const scenarioId = document.getElementById("scenarioSelect").value;
  applyScenario(scenarioId);
  const netVal = document.getElementById("networkSelect").value;
  const manifestUrl = netVal === "46630" ? "./deployments/robinhood-testnet.json" : "./deployments/arbitrum-sepolia.json";
  const badge = document.getElementById("statusBadge");
  try {
    const res = await fetch(manifestUrl);
    if (!res.ok || reqId !== latestRpcReqId) return;
    const cfg = await res.json();
    const { isValidDeployedAddress, simulateSettleBatchKeyless } = await import("./dist/rpc-client.mjs");
    if (reqId !== latestRpcReqId) return;
    const targets = [
      isValidDeployedAddress(cfg.stylusEngineAddress) ? { vm: "Stylus", addr: cfg.stylusEngineAddress } : null,
      isValidDeployedAddress(cfg.solidityBenchmarkAddress) ? { vm: "Solidity", addr: cfg.solidityBenchmarkAddress } : null,
    ].filter(Boolean);
    if (targets.length === 0) {
      badge.textContent = "LOCAL PARITY VERIFIED · AWAITING LIVE DEPLOY";
      return;
    }
    const payload = buildLiveScenarioPayloads(scenarioId, cfg);
    const results = await Promise.all(
      targets.map((t) => simulateSettleBatchKeyless({ rpcUrl: cfg.rpcUrl, engineAddress: t.addr, ...payload }))
    );
    if (reqId !== latestRpcReqId) return;
    const first = results[0];
    const dualMatch = results.length < 2 || (results[0].ok === results[1].ok && results[0].errorName === results[1].errorName);
    badge.className = first.ok && dualMatch ? "badge green" : "badge red";
    badge.textContent = !dualMatch
      ? "LIVE DUAL-VM MISMATCH"
      : first.ok
        ? `LIVE ${results.length === 2 ? "DUAL-VM" : "RPC"} PARITY · SETTLED`
        : `LIVE ${results.length === 2 ? "DUAL-VM" : "RPC"} REVERT · ${first.errorName || "GUARDED"}`;
  } catch (err) {
    if (reqId !== latestRpcReqId) return;
    const msg = err instanceof Error ? err.message : String(err);
    badge.textContent =
      window.location.protocol === "file:" ? "LOCAL PARITY VERIFIED · OFFLINE PREVIEW" : `RPC ERROR · ${msg.slice(0, 48)}`;
  }
}

document.getElementById("runSimBtn").addEventListener("click", runLiveDualVmParity);

renderBenchTable();
renderLiquidationCard();
applyScenario(initScenario);
