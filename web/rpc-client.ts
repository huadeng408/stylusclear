/**
 * StylusClear v1.0.0 Dual-Chain JSON-RPC & Keyless Simulation Client
 * Supports Arbitrum Sepolia (421614) & Robinhood Chain Testnet (46630) with full 29-method ABI parity.
 */
import { createPublicClient, decodeErrorResult, encodeFunctionData, http, parseAbi } from "viem";

export const SUPPORTED_NETWORKS = {
  421614: {
    chainId: 421614n,
    name: "Arbitrum Sepolia",
    rpcUrl: "https://sepolia-rollup.arbitrum.io/rpc",
    explorerUrl: "https://sepolia.arbiscan.io",
    deploymentFile: "./deployments/arbitrum-sepolia.json",
  },
  46630: {
    chainId: 46630n,
    name: "Robinhood Chain Testnet",
    rpcUrl: "https://rpc.testnet.chain.robinhood.com",
    explorerUrl: "https://explorer.testnet.chain.robinhood.com",
    deploymentFile: "./deployments/robinhood-testnet.json",
  },
} as const;

export const SETTLEMENT_ENGINE_ABI = parseAbi([
  "error MathOverflow()",
  "error DivisionByZero()",
  "error InvalidAssetConfig()",
  "error InvalidHaircut()",
  "error StaleMarkPrice()",
  "error BatchCapacityExceeded()",
  "error DuplicateParticipant()",
  "error InvalidObligation()",
  "error UnauthorizedObligation()",
  "error InvalidIntent()",
  "error ExpiredIntent()",
  "error UnauthorizedCaller()",
  "error InvalidSignature()",
  "error NonceAlreadyUsed()",
  "error AssetConservationViolated()",
  "error LimitPriceViolated()",
  "error InsufficientInitialMargin()",
  "error HealthMonotonicityViolated()",
  "error InsufficientWithdrawableBalance()",
  "function initialize(address initialAdmin, bool benchmarkSeedingEnabled) external",
  "function transferAdmin(address newAdmin) external",
  "function acceptAdmin() external",
  "function pendingAdmin() external view returns (address)",
  "function configureAsset(uint8 assetId, address token, uint8 decimals, uint256 markPriceWad, uint16 haircutBps, uint16 imBps, uint16 mmBps) external",
  "function updateMarkPrice(uint8 assetId, uint256 markPriceWad) external",
  "function setRiskWindows(uint64 maxStaleness, uint16 maxDeviationBps, bool permissionless) external",
  "function setApprovedSolver(address solver, bool approved) external",
  "function deposit(uint8 assetId, uint256 rawAmount) external returns (int256 newBalanceWad)",
  "function withdraw(uint8 assetId, uint256 rawAmount) external returns (int256 newBalanceWad)",
  "function repaySubQuantumDebt(uint8 assetId) external returns (int256 newBalanceWad)",
  "function absorbBadDebt(address underwater, uint8 debtAsset) external returns (uint256 absorbedWad)",
  "function sweepDustToFeeVault(uint8 assetId) external returns (uint256 dustWad)",
  "function sweepFeeVault(uint8 assetId, address recipient) external returns (uint256 sweptWad)",
  "function registerObligation(address creditor, uint8 assetId, uint256 amountWad) external returns (uint256 totalConfirmedWad)",
  "function revokeObligation(address creditor, uint8 assetId, uint256 amountWad) external returns (uint256 remainingConfirmedWad)",
  "function invalidateNonces(uint256 wordPos, uint256 mask) external returns (uint256 updatedWord)",
  "function liquidate(address underwater, uint8 debtAsset, uint8 collateralAsset, uint256 repayAmountWad) external returns (uint256 repaidDebtWad, uint256 seizedCollateralWad)",
  "function seedAccountBalance(address trader, uint8 assetId, int256 balanceWad) external",
  "function admin() external view returns (address)",
  "function benchmarkSeedingEnabled() external view returns (bool)",
  "function permissionlessSolver() external view returns (bool)",
  "function maxPriceStaleness() external view returns (uint64)",
  "function maxPriceDeviationBps() external view returns (uint16)",
  "function approvedSolvers(address solver) external view returns (bool)",
  "function assetCount() external view returns (uint8)",
  "function currentEpoch() external view returns (uint64)",
  "function domainSeparator() external view returns (bytes32)",
  "function getAccountBalance(address trader, uint8 assetId) external view returns (int256)",
  "function getConfirmedObligation(address debtor, address creditor, uint8 assetId) external view returns (uint256)",
  "function getFeeVault(uint8 assetId) external view returns (uint256)",
  "function getVaultPhysicalRaw(uint8 assetId) external view returns (uint256)",
  "function getNonceBitmap(address trader, uint256 wordPos) external view returns (uint256)",
  "function getPartialFill(address trader, uint256 nonce) external view returns (uint256)",
  "function getAssetConfig(uint8 assetId) external view returns (address token, uint8 decimals, uint256 markPriceWad, uint64 priceUpdatedAt, uint16 haircutBps, uint16 imBps, uint16 mmBps)",
  "function getAccountRisk(address trader) external view returns (uint256 effectiveCollateralWad, uint256 totalLiabilityWad, uint256 requiredImWad, uint256 requiredMmWad, int256 healthWad, int256 imSurplusWad)",
  "function settleBatch(address[] participants, (uint16 debtor, uint16 creditor, uint8 assetId, uint8 authMode, uint8 v, uint64 maxEpoch, uint256 amountWad, uint256 nonce, bytes32 r, bytes32 s)[] obligations, (uint16 trader, uint8 baseAsset, uint8 quoteAsset, uint8 side, uint8 authMode, uint8 v, uint64 maxEpoch, uint256 amountWad, uint256 limitPriceWad, uint256 nonce, bytes32 r, bytes32 s)[] intents) external returns (uint32 cyclesEliminated, uint256 totalMatchedVolumeWad)",
]);

export interface LiveBatchCallArgs {
  rpcUrl: string;
  engineAddress: string;
  callerAddress: string;
  chainId?: bigint | number | string;
  participants: `0x${string}`[];
  obligations: Array<{
    debtor: number;
    creditor: number;
    assetId: number;
    authMode: number;
    v: number;
    maxEpoch: bigint;
    amountWad: bigint;
    nonce: bigint;
    r: `0x${string}`;
    s: `0x${string}`;
  }>;
  intents: Array<{
    trader: number;
    baseAsset: number;
    quoteAsset: number;
    side: number;
    authMode: number;
    v: number;
    maxEpoch: bigint;
    amountWad: bigint;
    limitPriceWad: bigint;
    nonce: bigint;
    r: `0x${string}`;
    s: `0x${string}`;
  }>;
}

export interface LiveSimulationResult {
  ok: boolean;
  chainId: string;
  cyclesEliminated?: number;
  totalMatchedVolumeWad?: string;
  estimatedGas?: string;
  errorName?: string;
  rawRevertData?: string;
  unconfigured?: boolean;
}

export function isValidDeployedAddress(addr: string | null | undefined): addr is `0x${string}` {
  return typeof addr === "string" && /^0x[0-9a-fA-F]{40}$/.test(addr) && !/^0x0{40}$/.test(addr);
}

export function normalizeBigIntId(val: bigint | number | string): bigint {
  if (typeof val === "bigint") return val;
  if (typeof val === "string") return BigInt(val.trim());
  if (!Number.isSafeInteger(val) || val < 0) {
    throw new Error(`Unsafe numeric uint64/chainId: ${val}; pass string or bigint`);
  }
  return BigInt(val);
}

export async function simulateSettleBatchKeyless(args: LiveBatchCallArgs): Promise<LiveSimulationResult> {
  if (!isValidDeployedAddress(args.engineAddress)) {
    return {
      ok: false,
      chainId: args.chainId !== undefined ? normalizeBigIntId(args.chainId).toString() : "0",
      unconfigured: true,
      errorName: "EngineAddressNotDeployedYet",
    };
  }
  const client = createPublicClient({ transport: http(args.rpcUrl) });
  const chainIdBig = args.chainId !== undefined ? normalizeBigIntId(args.chainId) : BigInt(await client.getChainId());
  const data = encodeFunctionData({
    abi: SETTLEMENT_ENGINE_ABI,
    functionName: "settleBatch",
    args: [args.participants, args.obligations, args.intents],
  });

  try {
    const [callRes, gasEst] = await Promise.all([
      client.call({
        account: args.callerAddress as `0x${string}`,
        to: args.engineAddress,
        data,
      }),
      client.estimateGas({
        account: args.callerAddress as `0x${string}`,
        to: args.engineAddress,
        data,
      }),
    ]);
    const hex = callRes.data ?? "0x";
    let cycles = 0;
    let matched = 0n;
    if (hex.length >= 130) {
      cycles = Number(BigInt("0x" + hex.slice(2, 66)));
      matched = BigInt("0x" + hex.slice(66, 130));
    }
    return {
      ok: true,
      chainId: chainIdBig.toString(),
      cyclesEliminated: cycles,
      totalMatchedVolumeWad: matched.toString(),
      estimatedGas: gasEst.toString(),
    };
  } catch (err: unknown) {
    const raw = extractRevertHex(err);
    if (raw && raw.length >= 10) {
      try {
        const decoded = decodeErrorResult({ abi: SETTLEMENT_ENGINE_ABI, data: raw as `0x${string}` });
        return {
          ok: false,
          chainId: chainIdBig.toString(),
          errorName: decoded.errorName,
          rawRevertData: raw,
        };
      } catch {
        return { ok: false, chainId: chainIdBig.toString(), errorName: "UnknownCustomError", rawRevertData: raw };
      }
    }
    return {
      ok: false,
      chainId: chainIdBig.toString(),
      errorName: err instanceof Error ? err.message : String(err),
    };
  }
}

function extractRevertHex(err: unknown): string | null {
  const seen = new Set<unknown>();
  let cur: any = err;
  while (cur && typeof cur === "object" && !seen.has(cur)) {
    seen.add(cur);
    if (typeof cur.data === "string" && cur.data.startsWith("0x")) return cur.data;
    if (cur.data && typeof cur.data.data === "string" && cur.data.data.startsWith("0x")) return cur.data.data;
    if (typeof cur.raw === "string" && cur.raw.startsWith("0x")) return cur.raw;
    cur = cur.cause;
  }
  const fullMsg = err instanceof Error ? err.message : String(err);
  const m = fullMsg.match(/(?:data|revert(?:ed)?[^0-9a-fA-F]*)(0x[0-9a-fA-F]{8})(?![0-9a-fA-F])/i);
  return m ? m[1] : null;
}
