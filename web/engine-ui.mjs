/**
 * StylusClear v1.2.0 Isomorphic Clearing, Liquidation & Mesh Engine for Web Workbench
 * - Zero plaintext funded private keys (D-13): keyless eth_call + cryptographic random nonceWord
 * - O(V^2) 2-Origin BFS cycle netting + memoized 64-desk mesh (<5ms slider latency, D-14)
 * - Full 4-asset support (USDC/USDG, WETH, ARB, NVDAx) + 512-bit UCPBA IR + adaptive floor liquidation
 */
import { SETTLEMENT_ENGINE_ABI, SUPPORTED_NETWORKS, isValidDeployedAddress, normalizeBigIntId, simulateSettleBatchKeyless } from "./dist/rpc-client.mjs";

export const WAD = 10n ** 18n;
export const BPS_DENOM = 10_000n;
export const MIN_INTENT_AMOUNT_WAD = 10n ** 9n;
export const LIQUIDATION_BONUS_CAP_BPS = 250n;

import { MEASURED_BENCHMARKS } from "./benchmarks.generated.mjs";

const WB = MEASURED_BENCHMARKS.wasmBinary || MEASURED_BENCHMARKS.wasm_binary;
export const MEASURED_BENCHMARK_SUMMARY = {
  schemaVersion: MEASURED_BENCHMARKS.schemaVersion || MEASURED_BENCHMARKS.schema_version,
  wasmRawBytes: WB.raw_bytes,
  wasmBrotliBytes: WB.brotli_q11_bytes,
  wasmSha256: WB.sha256,
  arbitrumSingleBlockGasLimit: MEASURED_BENCHMARKS.arbitrumSingleBlockGasLimit || MEASURED_BENCHMARKS.arbitrum_single_block_gas_limit || 32_000_000,
  workloads: MEASURED_BENCHMARKS.workloads,
};

export const STANDARD_ASSETS = [
  { assetId: 0, symbol: "USDC / USDG", decimals: 6, markPriceWad: 1n * WAD, haircutBps: 0n, imBps: 500n, mmBps: 250n },
  { assetId: 1, symbol: "WETH", decimals: 18, markPriceWad: 2850n * WAD, haircutBps: 500n, imBps: 1000n, mmBps: 500n },
  { assetId: 2, symbol: "ARB", decimals: 18, markPriceWad: 1n * WAD, haircutBps: 1000n, imBps: 1200n, mmBps: 600n },
  { assetId: 3, symbol: "NVDAx (RWA)", decimals: 18, markPriceWad: 140n * WAD, haircutBps: 1000n, imBps: 1200n, mmBps: 600n },
];

export function generateEphemeralNonceWord() {
  if (globalThis.crypto && typeof globalThis.crypto.getRandomValues === "function") {
    const arr = new Uint32Array(2);
    globalThis.crypto.getRandomValues(arr);
    return (BigInt(arr[0]) << 32n) | BigInt(arr[1]) | 1_000_000n;
  }
  return BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 999));
}

export function mulDivFloor(a, b, d) {
  if (d <= 0n) throw new Error("DivisionByZero");
  return (a * b) / d;
}

export function mulDivCeil(a, b, d) {
  if (d <= 0n) throw new Error("DivisionByZero");
  const p = a * b;
  return p === 0n ? 0n : (p + d - 1n) / d;
}

export function computeLiquidationBonusBps(mmBps) {
  const half = BigInt(mmBps) / 2n;
  return half < LIQUIDATION_BONUS_CAP_BPS ? half : LIQUIDATION_BONUS_CAP_BPS;
}

export function evaluateAccountRisk(balancesWad, assets = STANDARD_ASSETS) {
  let gross = 0n, eff = 0n, liab = 0n, im = 0n, mm = 0n;
  for (let i = 0; i < assets.length; i++) {
    const bal = BigInt(balancesWad[i] ?? 0n);
    const cfg = assets[i];
    if (bal > 0n) {
      const val = mulDivFloor(bal, cfg.markPriceWad, WAD);
      const scaled = mulDivFloor(val, BPS_DENOM - cfg.haircutBps, BPS_DENOM);
      gross += val;
      eff += scaled;
    } else if (bal < 0n) {
      const mag = -bal;
      const val = mulDivCeil(mag, cfg.markPriceWad, WAD);
      liab += val;
      im += mulDivCeil(val, BPS_DENOM + cfg.imBps, BPS_DENOM);
      mm += mulDivCeil(val, BPS_DENOM + cfg.mmBps, BPS_DENOM);
    }
  }
  return {
    grossCollateralWad: gross,
    effectiveCollateralWad: eff,
    totalLiabilityWad: liab,
    requiredImWad: im,
    requiredMmWad: mm,
    netEquityWad: gross - liab,
    healthWad: eff - mm,
    imSurplusWad: eff - im,
  };
}

export function previewUnderwaterLiquidation({
  underwaterBalances,
  liquidatorBalances,
  debtAsset = 1,
  collateralAsset = 0,
  repayAmountWad,
  assets = STANDARD_ASSETS,
}) {
  const repayReq = BigInt(repayAmountWad);
  if (
    debtAsset < 0 || debtAsset >= assets.length ||
    collateralAsset < 0 || collateralAsset >= assets.length ||
    debtAsset === collateralAsset ||
    repayReq <= 0n
  ) {
    return { ok: false, error: "InvalidIntent" };
  }
  const uBals = underwaterBalances.map(BigInt);
  const lBals = liquidatorBalances.map(BigInt);
  const preU = evaluateAccountRisk(uBals, assets);
  if (preU.healthWad >= 0n || uBals[debtAsset] >= 0n || uBals[collateralAsset] <= 0n) {
    return { ok: false, error: "InvalidIntent" };
  }
  const absDebt = -uBals[debtAsset];
  if (repayReq < MIN_INTENT_AMOUNT_WAD) {
    return { ok: false, error: "InvalidIntent" };
  }
  const availColl = uBals[collateralAsset];
  const cappedRepay = repayReq < absDebt ? repayReq : absDebt;
  const bonusBps = computeLiquidationBonusBps(assets[debtAsset].mmBps);
  const bonusFactor = BPS_DENOM + bonusBps;

  const quoteRepay = mulDivFloor(cappedRepay, assets[debtAsset].markPriceWad, assets[collateralAsset].markPriceWad);
  const rawSeize = mulDivFloor(quoteRepay, bonusFactor, BPS_DENOM);

  let actualRepay = cappedRepay;
  let actualSeize = rawSeize;
  let cappedByCollateral = false;
  if (rawSeize > availColl) {
    cappedByCollateral = true;
    const maxQuote = mulDivFloor(availColl, BPS_DENOM, bonusFactor);
    const backRepay = mulDivFloor(maxQuote, assets[collateralAsset].markPriceWad, assets[debtAsset].markPriceWad);
    actualRepay = cappedRepay < backRepay ? cappedRepay : backRepay;
    actualSeize = availColl;
  }
  const fullDebtClearance = actualRepay === absDebt;
  if (actualSeize === 0n || actualRepay === 0n || (!fullDebtClearance && actualRepay < MIN_INTENT_AMOUNT_WAD)) {
    return { ok: false, error: "InvalidIntent" };
  }
  if (lBals[debtAsset] < actualRepay) {
    return { ok: false, error: "InsufficientWithdrawableBalance" };
  }
  const postUBals = [...uBals];
  const postLBals = [...lBals];
  postUBals[debtAsset] += actualRepay;
  postUBals[collateralAsset] -= actualSeize;
  postLBals[debtAsset] -= actualRepay;
  postLBals[collateralAsset] += actualSeize;

  const postU = evaluateAccountRisk(postUBals, assets);
  const postL = evaluateAccountRisk(postLBals, assets);
  const collExhausted = postUBals[collateralAsset] === 0n;
  const healthOk = collExhausted
    ? (postU.healthWad >= preU.healthWad && postU.totalLiabilityWad < preU.totalLiabilityWad)
    : (postU.healthWad > preU.healthWad);
  if (!healthOk) return { ok: false, error: "HealthMonotonicityViolated" };
  if (postL.imSurplusWad < 0n) return { ok: false, error: "InsufficientInitialMargin" };

  return {
    ok: true,
    bonusBps: Number(bonusBps),
    cappedByCollateral,
    repaidDebtWad: actualRepay,
    seizedCollateralWad: actualSeize,
    preHealthWad: preU.healthWad,
    postHealthWad: postU.healthWad,
  };
}

function findCycleBfs2Origin(start, n, mat) {
  const r1 = new Int16Array(n).fill(-1);
  const r2 = new Int16Array(n).fill(-1);
  const qNode = new Int16Array(n * 2);
  const qOrig = new Int16Array(n * 2);
  const qPar = new Int16Array(n * 2).fill(-1);
  let head = 0, tail = 0;

  for (let f = start + 1; f < n; f++) {
    if (mat[start * n + f] > 0n) {
      r1[f] = f;
      qNode[tail] = f;
      qOrig[tail] = f;
      tail++;
    }
  }
  while (head < tail) {
    const qi = head++;
    const u = qNode[qi];
    const orig = qOrig[qi];
    if (orig !== u && mat[u * n + start] > 0n) {
      const rev = [];
      let cur = qi;
      while (cur !== -1) {
        rev.push(qNode[cur]);
        cur = qPar[cur];
      }
      rev.reverse();
      return [start, ...rev];
    }
    for (let nxt = start + 1; nxt < n; nxt++) {
      if (mat[u * n + nxt] > 0n) {
        if (r1[nxt] === -1) {
          r1[nxt] = orig;
          qNode[tail] = nxt;
          qOrig[tail] = orig;
          qPar[tail] = qi;
          tail++;
        } else if (r1[nxt] !== orig && r2[nxt] === -1) {
          r2[nxt] = orig;
          qNode[tail] = nxt;
          qOrig[tail] = orig;
          qPar[tail] = qi;
          tail++;
        }
      }
    }
  }
  for (let f = start + 1; f < n; f++) {
    if (mat[start * n + f] > 0n && mat[f * n + start] > 0n) return [start, f];
  }
  return null;
}

const _meshCache = new Map();

export function simulateScaleMeshFast(deskCount) {
  const n = Math.max(4, Math.min(64, Number(deskCount)));
  if (_meshCache.has(n)) return _meshCache.get(n);

  const mat = new Array(n * n).fill(0n);
  const edges = [];
  let grossWad = 0n;
  for (let i = 0; i < n; i++) {
    const nxt = (i + 1) % n;
    const amt = BigInt(120 + (i % 7) * 15) * WAD;
    mat[i * n + nxt] += amt;
    edges.push({ debtor: i, creditor: nxt, amountWad: amt });
    grossWad += amt;
    if (i % 2 === 0 && edges.length < 128) {
      const chord = (i + 3) % n;
      if (chord !== i) {
        const cAmt = BigInt(65 + (i % 5) * 10) * WAD;
        mat[i * n + chord] += cAmt;
        edges.push({ debtor: i, creditor: chord, amountWad: cAmt });
        grossWad += cAmt;
      }
    }
  }

  let cycles = 0;
  let compressedWad = 0n;
  for (let s = 0; s < n; s++) {
    while (true) {
      const path = findCycleBfs2Origin(s, n, mat);
      if (!path) break;
      let bn = mat[path[0] * n + path[1]];
      for (let k = 1; k < path.length; k++) {
        const w = mat[path[k] * n + path[(k + 1) % path.length]];
        if (w < bn) bn = w;
      }
      for (let k = 0; k < path.length; k++) {
        mat[path[k] * n + path[(k + 1) % path.length]] -= bn;
      }
      compressedWad += bn * BigInt(path.length);
      cycles++;
    }
  }
  let residualWad = 0n;
  const residualEdges = [];
  for (let u = 0; u < n; u++) {
    for (let v = 0; v < n; v++) {
      if (mat[u * n + v] > 0n) {
        residualWad += mat[u * n + v];
        residualEdges.push({ debtor: u, creditor: v, amountWad: mat[u * n + v] });
      }
    }
  }

  const result = {
    deskCount: n,
    obligationCount: edges.length,
    cyclesEliminated: cycles,
    grossObligationWad: grossWad,
    compressedWad,
    residualDebtWad: residualWad,
    compressionRatioPct: Number((compressedWad * 10000n) / grossWad) / 100,
    nodeLabels: Array.from({ length: n }, (_, idx) =>
      n <= 4 ? ["Alpha", "Bravo", "Charlie", "Delta"][idx] : `D${String(idx + 1).padStart(2, "0")}`
    ),
    edges,
    residualEdges,
  };
  _meshCache.set(n, result);
  return result;
}

export const PRESET_SCENARIOS = {
  institutionalMesh: {
    id: "institutionalMesh",
    title: "Scenario 1 — 4-Desk Multilateral Ring + WETH UCPBA Fill",
    expectedStatus: "SETTLED",
    expectedError: null,
    desks: [
      { name: "Desk Alpha", shortLabel: "Alpha", address: "0x1111111111111111111111111111111111111111", preBalances: [25000n * WAD, 8n * WAD, 5000n * WAD, 40n * WAD], balances: [20350n * WAD, 10n * WAD, 5000n * WAD, 40n * WAD] },
      { name: "Desk Bravo", shortLabel: "Bravo", address: "0x2222222222222222222222222222222222222222", preBalances: [22000n * WAD, 10n * WAD, 4000n * WAD, 25n * WAD], balances: [26650n * WAD, 8n * WAD, 4000n * WAD, 25n * WAD] },
      { name: "Desk Charlie", shortLabel: "Charlie", address: "0x3333333333333333333333333333333333333333", preBalances: [19000n * WAD, 6n * WAD, 8000n * WAD, 30n * WAD], balances: [19000n * WAD, 6n * WAD, 8000n * WAD, 30n * WAD] },
      { name: "Desk Delta", shortLabel: "Delta", address: "0x4444444444444444444444444444444444444444", preBalances: [31000n * WAD, 12n * WAD, 6000n * WAD, 50n * WAD], balances: [31000n * WAD, 12n * WAD, 6000n * WAD, 50n * WAD] },
    ],
    grossObligationUsd: "13,200.00",
    netResidualUsd: "1,050.00",
    cyclesEliminated: 2,
    matchedVolumeSummary: "2.00 WETH @ $2,850.00",
  },
  oracleBandGuard: {
    id: "oracleBandGuard",
    title: "Scenario 2 — Fail-Closed Oracle Deviation Guard (>20% Band)",
    expectedStatus: "REVERTED_GUARD",
    expectedError: "LimitPriceViolated",
    desks: [
      { name: "Desk Alpha", shortLabel: "Alpha", address: "0x1111111111111111111111111111111111111111", balances: [25000n * WAD, 8n * WAD, 5000n * WAD, 40n * WAD] },
      { name: "Desk Bravo", shortLabel: "Bravo", address: "0x2222222222222222222222222222222222222222", balances: [22000n * WAD, 10n * WAD, 4000n * WAD, 25n * WAD] },
      { name: "Desk Charlie", shortLabel: "Charlie", address: "0x3333333333333333333333333333333333333333", balances: [19000n * WAD, 6n * WAD, 8000n * WAD, 30n * WAD] },
      { name: "Desk Delta", shortLabel: "Delta", address: "0x4444444444444444444444444444444444444444", balances: [31000n * WAD, 12n * WAD, 6000n * WAD, 50n * WAD] },
    ],
    grossObligationUsd: "13,200.00",
    netResidualUsd: "0.00 (Atomic Rollback)",
    cyclesEliminated: 0,
    matchedVolumeSummary: "Rejected: Crossed at $3,600.00 (+26.3% > ±20.0% band)",
  },
  marginShortfallGuard: {
    id: "marginShortfallGuard",
    title: "Scenario 3 — Fail-Closed Initial Margin Guard (IM Deficit)",
    expectedStatus: "REVERTED_GUARD",
    expectedError: "InsufficientInitialMargin",
    desks: [
      { name: "Desk Alpha", shortLabel: "Alpha", address: "0x1111111111111111111111111111111111111111", balances: [400n * WAD, 0n, 0n, 0n] },
      { name: "Desk Bravo", shortLabel: "Bravo", address: "0x2222222222222222222222222222222222222222", balances: [35000n * WAD, 15n * WAD, 4000n * WAD, 25n * WAD] },
      { name: "Desk Charlie", shortLabel: "Charlie", address: "0x3333333333333333333333333333333333333333", balances: [19000n * WAD, 6n * WAD, 8000n * WAD, 30n * WAD] },
      { name: "Desk Delta", shortLabel: "Delta", address: "0x4444444444444444444444444444444444444444", balances: [31000n * WAD, 12n * WAD, 6000n * WAD, 50n * WAD] },
    ],
    grossObligationUsd: "8,500.00",
    netResidualUsd: "0.00 (Atomic Rollback)",
    cyclesEliminated: 0,
    matchedVolumeSummary: "Rejected: Desk Alpha Post-Batch IM Surplus -$5,342.50",
  },
  robinhoodUsdgMesh: {
    id: "robinhoodUsdgMesh",
    title: "Scenario 4 — Robinhood Chain Testnet (46630) USDG + NVDAx RWA Mesh",
    expectedStatus: "SETTLED",
    expectedError: null,
    desks: [
      { name: "Desk Alpha", shortLabel: "Alpha", address: "0x1111111111111111111111111111111111111111", preBalances: [40000n * WAD, 4n * WAD, 2000n * WAD, 120n * WAD], balances: [39300n * WAD, 4n * WAD, 2000n * WAD, 135n * WAD] },
      { name: "Desk Bravo", shortLabel: "Bravo", address: "0x2222222222222222222222222222222222222222", preBalances: [38000n * WAD, 5n * WAD, 3000n * WAD, 95n * WAD], balances: [38700n * WAD, 5n * WAD, 3000n * WAD, 80n * WAD] },
      { name: "Desk Charlie", shortLabel: "Charlie", address: "0x3333333333333333333333333333333333333333", preBalances: [29000n * WAD, 3n * WAD, 5000n * WAD, 150n * WAD], balances: [29000n * WAD, 3n * WAD, 5000n * WAD, 150n * WAD] },
      { name: "Desk Delta", shortLabel: "Delta", address: "0x4444444444444444444444444444444444444444", preBalances: [44000n * WAD, 6n * WAD, 4500n * WAD, 110n * WAD], balances: [44000n * WAD, 6n * WAD, 4500n * WAD, 110n * WAD] },
    ],
    grossObligationUsd: "24,000.00",
    netResidualUsd: "1,400.00",
    cyclesEliminated: 2,
    matchedVolumeSummary: "15.00 NVDAx @ $140.00 (Asset Slot 3 vs USDG Slot 0)",
  },
};

const ZERO_B32 = ("0x" + "00".repeat(32));

/**
 * Builds keyless eth_call simulation payloads (zero hardcoded private keys, fresh random nonceWord).
 */
export function buildLiveScenarioPayloads(scenarioId, deploymentConfig) {
  const chainId = normalizeBigIntId(deploymentConfig.chainId ?? 421614);
  const demoA = (deploymentConfig.demoTraderA || "0x1111111111111111111111111111111111111111");
  const demoB = (deploymentConfig.demoTraderB || "0x2222222222222222222222222222222222222222");
  const participants = [demoA, demoB];
  const nonceBase = (generateEphemeralNonceWord() << 8n) + 1n;
  const maxEpoch = 1_000_000_000n;

  if (scenarioId === "oracleBandGuard") {
    // Keyless single-caller guard probe: trader 0 submits opposing wash-trade / out-of-band intents under authMode=0
    // so both Stylus and Solidity deterministically revert InvalidIntent without embedding any private key.
    return {
      chainId,
      callerAddress: demoA,
      participants,
      obligations: [],
      intents: [
        { trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 0, v: 0, maxEpoch, amountWad: 1n * WAD, limitPriceWad: 3900n * WAD, nonce: nonceBase, r: ZERO_B32, s: ZERO_B32 },
        { trader: 0, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 0, v: 0, maxEpoch, amountWad: 1n * WAD, limitPriceWad: 3600n * WAD, nonce: nonceBase + 1n, r: ZERO_B32, s: ZERO_B32 },
      ],
    };
  }

  if (scenarioId === "marginShortfallGuard") {
    return {
      chainId,
      callerAddress: demoA,
      participants,
      obligations: [
        { debtor: 0, creditor: 1, assetId: 0, authMode: 1, v: 0, maxEpoch, amountWad: 999_999_000n * WAD, nonce: nonceBase, r: ZERO_B32, s: ZERO_B32 },
      ],
      intents: [],
    };
  }

  if (scenarioId === "robinhoodUsdgMesh") {
    return {
      chainId,
      callerAddress: demoA,
      participants,
      obligations: [
        { debtor: 0, creditor: 1, assetId: 0, authMode: 1, v: 0, maxEpoch, amountWad: 140n * WAD, nonce: nonceBase, r: ZERO_B32, s: ZERO_B32 },
      ],
      intents: [
        { trader: 0, baseAsset: 3, quoteAsset: 0, side: 0, authMode: 0, v: 0, maxEpoch, amountWad: 1n * WAD, limitPriceWad: 145n * WAD, nonce: nonceBase + 1n, r: ZERO_B32, s: ZERO_B32 },
      ],
    };
  }

  return {
    chainId,
    callerAddress: demoA,
    participants,
    obligations: [
      { debtor: 0, creditor: 1, assetId: 0, authMode: 1, v: 0, maxEpoch, amountWad: 250n * WAD, nonce: nonceBase, r: ZERO_B32, s: ZERO_B32 },
    ],
    intents: [],
  };
}

export { SETTLEMENT_ENGINE_ABI, SUPPORTED_NETWORKS, isValidDeployedAddress, normalizeBigIntId, simulateSettleBatchKeyless };
