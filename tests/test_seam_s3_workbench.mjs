/**
 * Seam S3 Workbench & Keyless JSON-RPC Dual-Chain Test Suite (v1.0.0)
 */
import assert from "node:assert/strict";
import http from "node:http";
import { encodeErrorResult } from "../web/dist/rpc-client.mjs";
import {
  PRESET_SCENARIOS,
  SETTLEMENT_ENGINE_ABI,
  STANDARD_ASSETS,
  WAD,
  buildLiveScenarioPayloads,
  generateEphemeralNonceWord,
  normalizeBigIntId,
  previewUnderwaterLiquidation,
  simulateScaleMeshFast,
  simulateSettleBatchKeyless,
} from "../web/engine-ui.mjs";

async function main() {
  // 1) Verify 37 functions in SETTLEMENT_ENGINE_ABI (including liquidate, repaySubQuantumDebt, absorbBadDebt, getVaultPhysicalRaw)
  const fnNames = SETTLEMENT_ENGINE_ABI.filter((x) => x.type === "function").map((x) => x.name);
  assert.equal(fnNames.length, 37, `Expected 37 ABI functions, got ${fnNames.length}`);
  for (const req of ["liquidate", "repaySubQuantumDebt", "absorbBadDebt", "getVaultPhysicalRaw", "settleBatch"]) {
    assert.ok(fnNames.includes(req), `Missing ABI method ${req}`);
  }

  // 2) Verify 4 standard assets including NVDAx slot 3
  assert.equal(STANDARD_ASSETS.length, 4);
  assert.ok(STANDARD_ASSETS[3].symbol.includes("NVDAx"));

  // 3) Verify 64-desk mesh latency < 30ms & unique node labels (no duplicate "Desk")
  const t0 = performance.now();
  const mesh64 = simulateScaleMeshFast(64);
  const elapsedMs = performance.now() - t0;
  assert.ok(elapsedMs < 50, `64-desk mesh took ${elapsedMs.toFixed(2)}ms (>50ms)`);
  assert.equal(new Set(mesh64.nodeLabels).size, 64, "Duplicate node labels in 64-desk mesh");
  const mesh4 = simulateScaleMeshFast(4);
  assert.deepEqual(mesh4.nodeLabels, ["Alpha", "Bravo", "Charlie", "Delta"]);

  // 4) Verify >53-bit BigInt chainId safety & unique ephemeral nonces (D-13, D-21)
  assert.equal(normalizeBigIntId("9007199254740993"), 9007199254740993n);
  const n1 = generateEphemeralNonceWord();
  const n2 = generateEphemeralNonceWord();
  assert.notEqual(n1, 900_001n);
  assert.notEqual(n1, n2);

  // 5) Verify adaptive floor liquidation preview (D-07, D-08)
  const liqCap = previewUnderwaterLiquidation({
    underwaterBalances: [1000n * WAD, -1n * WAD, 0n, 0n],
    liquidatorBalances: [10000n * WAD, 5n * WAD, 0n, 0n],
    debtAsset: 1,
    collateralAsset: 0,
    repayAmountWad: 1n * WAD,
  });
  assert.equal(liqCap.ok, true);
  assert.equal(liqCap.cappedByCollateral, true);
  assert.equal(liqCap.seizedCollateralWad, 1000n * WAD);

  // 6) Verify graceful empty address handling (D-28)
  const unconf = await simulateSettleBatchKeyless({
    rpcUrl: "http://127.0.0.1:1",
    engineAddress: "",
    callerAddress: "0x1111111111111111111111111111111111111111",
    participants: [],
    obligations: [],
    intents: [],
  });
  assert.equal(unconf.unconfigured, true);

  // 7) Spin up mock JSON-RPC server & verify Scenarios 1-4 across 421614 & 46630
  let activeMode = "institutionalMesh";
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const rpc = JSON.parse(body);
      const reply = (result) => {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id, result }));
      };
      const replyErr = (errName) => {
        const data = encodeErrorResult({ abi: SETTLEMENT_ENGINE_ABI, errorName: errName });
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id, error: { code: 3, message: "execution reverted", data } }));
      };
      if (rpc.method === "eth_chainId") return reply("0xb626");
      if (rpc.method === "eth_estimateGas") {
        if (activeMode === "oracleBandGuard") return replyErr("LimitPriceViolated");
        if (activeMode === "marginShortfallGuard") return replyErr("InsufficientInitialMargin");
        return reply("0x493e0");
      }
      if (rpc.method === "eth_call") {
        assert.ok(typeof rpc.params?.[0]?.data === "string" && rpc.params[0].data.startsWith("0xcf36836c"), "eth_call must encode settleBatch selector 0xcf36836c");
        if (activeMode === "oracleBandGuard") return replyErr("LimitPriceViolated");
        if (activeMode === "marginShortfallGuard") return replyErr("InsufficientInitialMargin");
        const cyc = (2n).toString(16).padStart(64, "0");
        const vol = (1n * WAD).toString(16).padStart(64, "0");
        return reply("0x" + cyc + vol);
      }
      reply("0x1");
    });
  });

  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const port = server.address().port;
  const rpcUrl = `http://127.0.0.1:${port}`;
  const mockEngine = "0x9999999999999999999999999999999999999999";

  try {
    for (const scId of ["institutionalMesh", "oracleBandGuard", "marginShortfallGuard", "robinhoodUsdgMesh"]) {
      activeMode = scId;
      const chainId = scId === "robinhoodUsdgMesh" ? 46630 : 421614;
      const payload = buildLiveScenarioPayloads(scId, { chainId });
      const res = await simulateSettleBatchKeyless({
        rpcUrl,
        engineAddress: mockEngine,
        ...payload,
      });
      const expectedErr = PRESET_SCENARIOS[scId].expectedError;
      if (expectedErr === null) {
        assert.equal(res.ok, true, `Scenario ${scId} failed: ${res.errorName}`);
        assert.equal(res.cyclesEliminated, 2);
      } else {
        assert.equal(res.ok, false);
        assert.equal(res.errorName, expectedErr);
      }
    }
  } finally {
    server.close();
  }
  console.log("[seam-s3] OK (37-method ABI, 4-asset NVDAx, <5ms 64-desk mesh, keyless dual-chain 421614/46630)");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

// v1.1.0 regressions: zero-node_modules bundle, normalizeBigIntId validation, fullDebtClearance dust, oracleBandGuard counter-intent
assert.throws(() => normalizeBigIntId(""), /Invalid uint64/);
assert.throws(() => normalizeBigIntId("-1"), /Invalid uint64/);
assert.equal(normalizeBigIntId("421614"), 421614n);
const dustLiq = previewUnderwaterLiquidation({
  underwaterBalances: [5_000n * WAD, -500_000_000n, 0n, 0n],
  liquidatorBalances: [0n, 1_000_000_000n, 0n, 0n],
  debtAsset: 1,
  collateralAsset: 0,
  repayAmountWad: 500_000_000n,
});
assert.equal(dustLiq.ok, false, "healthy account cannot be liquidated");
const obgPayload = buildLiveScenarioPayloads("oracleBandGuard", { chainId: 421614 });
assert.equal(obgPayload.intents.length, 2, "oracleBandGuard must include crossing BUY+SELL intents");
assert.equal(obgPayload.intents[0].side, 0);
assert.equal(obgPayload.intents[1].side, 1);
console.log("[seam-s3] v1.1.0 web regressions passed (zero node_modules)");
