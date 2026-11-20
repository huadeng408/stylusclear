// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SolidityClearingBenchmark} from "../src/SolidityClearingBenchmark.sol";
import {ISettlementEngine} from "../src/ISettlementEngine.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {StylusAtomicFactory} from "../src/StylusAtomicFactory.sol";

interface Vm {
    function addr(uint256 privateKey) external returns (address);
    function prank(address caller) external;
    function warp(uint256 newTimestamp) external;
    function deal(address who, uint256 newBalance) external;
    function chainId(uint256 newChainId) external;
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function cool(address target) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function expectRevert(bytes4 revertData) external;
    function readFile(string calldata path) external view returns (string memory);
    function parseUint(string calldata stringifiedValue) external pure returns (uint256);
    function parseInt(string calldata stringifiedValue) external pure returns (int256);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory);
}

/// @dev Test-only harness initializing storage slots after `vm.etch` without polluting production ABI (`MED-01`).
contract GoldenHarness is SolidityClearingBenchmark {
    constructor(address admin_, bool seeding_) SolidityClearingBenchmark(admin_, seeding_) {}

    function harnessInitAfterEtch(address admin_, uint64 batchEpoch) external {
        if (_admin != address(0)) revert UnauthorizedCaller();
        _admin = admin_;
        _benchmarkSeedingEnabled = true;
        _unlocked = 1;
        _permissionlessSolver = true;
        _currentEpoch = batchEpoch;
        _maxPriceStaleness = 3600;
        _maxPriceDeviationBps = 2000;
        _approvedSolvers[admin_] = true;
    }
}

/// @title ClearingDifferentialTest
/// @notice Isolated Golden-Vector JSON Tests, v0.5 Exploit Regressions, Liquidation & Multi-Decimal Fuzz Suite.
contract ClearingDifferentialTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant WAD = 1e18;
    address internal constant GOLDEN_VERIFYING_CONTRACT = 0x2222222222222222222222222222222222222222;

    SolidityClearingBenchmark internal engine;
    MockERC20 internal usdc6;
    MockERC20 internal weth18;
    MockERC20 internal arb18;

    function setUp() public virtual {
        vm.chainId(421614);
        vm.warp(1_000);
        engine = new SolidityClearingBenchmark(address(this), true);
        usdc6 = new MockERC20("USD Coin", "USDC", 6);
        weth18 = new MockERC20("Wrapped Ether", "WETH", 18);
        arb18 = new MockERC20("Arbitrum", "ARB", 18);

        engine.configureAsset(0, address(usdc6), 6, 1 * WAD, 0, 500, 250);
        engine.configureAsset(1, address(weth18), 18, 2500 * WAD, 500, 1000, 500);
        engine.configureAsset(2, address(arb18), 18, 12e17, 1500, 1500, 800);
    }

    function _mountGoldenEngine(uint64 epochTs, uint64 batchEpoch) internal returns (GoldenHarness g) {
        GoldenHarness tpl = new GoldenHarness(address(this), true);
        vm.etch(GOLDEN_VERIFYING_CONTRACT, address(tpl).code);
        g = GoldenHarness(GOLDEN_VERIFYING_CONTRACT);
        g.harnessInitAfterEtch(address(this), batchEpoch);
        vm.warp(990);
        g.configureAsset(0, address(0), 6, 1 * WAD, 0, 500, 250);
        g.configureAsset(1, address(0), 18, 2500 * WAD, 500, 1000, 500);
        g.configureAsset(2, address(0), 18, 12e17, 1500, 1500, 800);
        vm.warp(epochTs);
    }

    function testGolden01_MixedLedgerEip712DirectCycleAndUcpbaSuccess() public {
        string memory rawJson = vm.readFile("tests/vectors/golden_batches.json");
        GoldenHarness g0 = _mountGoldenEngine(1_000, 42);
        address a0 = vm.parseJsonAddress(rawJson, "$[0].input.accounts[0].address");
        address a1 = vm.parseJsonAddress(rawJson, "$[0].input.accounts[1].address");
        address relayer = vm.parseJsonAddress(rawJson, "$[0].input.accounts[2].address");

        g0.seedAccountBalance(a0, 0, vm.parseInt(vm.parseJsonString(rawJson, "$[0].input.accounts[0].balances[0]")));
        g0.seedAccountBalance(a1, 1, vm.parseInt(vm.parseJsonString(rawJson, "$[0].input.accounts[1].balances[1]")));

        vm.prank(a0);
        g0.registerObligation(a1, 0, vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.obligations[0].amount_wad")));

        address[] memory parts0 = new address[](3);
        parts0[0] = a0;
        parts0[1] = a1;
        parts0[2] = relayer;

        ISettlementEngine.ObligationInput[] memory obs0 = new ISettlementEngine.ObligationInput[](3);
        obs0[0] = ISettlementEngine.ObligationInput({
            debtor: 0,
            creditor: 1,
            assetId: 0,
            authMode: 0,
            v: 0,
            maxEpoch: 0,
            amountWad: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.obligations[0].amount_wad")),
            nonce: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        obs0[1] = ISettlementEngine.ObligationInput({
            debtor: 1,
            creditor: 2,
            assetId: 0,
            authMode: 2,
            v: uint8(vm.parseJsonUint(rawJson, "$[0].input.obligations[1].auth.v")),
            maxEpoch: uint64(vm.parseJsonUint(rawJson, "$[0].input.obligations[1].max_epoch")),
            amountWad: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.obligations[1].amount_wad")),
            nonce: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.obligations[1].nonce")),
            r: vm.parseJsonBytes32(rawJson, "$[0].input.obligations[1].auth.r"),
            s: vm.parseJsonBytes32(rawJson, "$[0].input.obligations[1].auth.s")
        });
        obs0[2] = ISettlementEngine.ObligationInput({
            debtor: 2,
            creditor: 0,
            assetId: 0,
            authMode: 1,
            v: 0,
            maxEpoch: uint64(vm.parseJsonUint(rawJson, "$[0].input.obligations[2].max_epoch")),
            amountWad: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.obligations[2].amount_wad")),
            nonce: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.obligations[2].nonce")),
            r: bytes32(0),
            s: bytes32(0)
        });

        ISettlementEngine.SignedTradeIntent[] memory its0 = new ISettlementEngine.SignedTradeIntent[](2);
        its0[0] = ISettlementEngine.SignedTradeIntent({
            trader: 0,
            baseAsset: 1,
            quoteAsset: 0,
            side: 0,
            authMode: 1,
            v: uint8(vm.parseJsonUint(rawJson, "$[0].input.intents[0].auth.v")),
            maxEpoch: uint64(vm.parseJsonUint(rawJson, "$[0].input.intents[0].max_epoch")),
            amountWad: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.intents[0].amount_wad")),
            limitPriceWad: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.intents[0].limit_price_wad")),
            nonce: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.intents[0].nonce")),
            r: vm.parseJsonBytes32(rawJson, "$[0].input.intents[0].auth.r"),
            s: vm.parseJsonBytes32(rawJson, "$[0].input.intents[0].auth.s")
        });
        its0[1] = ISettlementEngine.SignedTradeIntent({
            trader: 1,
            baseAsset: 1,
            quoteAsset: 0,
            side: 1,
            authMode: 1,
            v: uint8(vm.parseJsonUint(rawJson, "$[0].input.intents[1].auth.v")),
            maxEpoch: uint64(vm.parseJsonUint(rawJson, "$[0].input.intents[1].max_epoch")),
            amountWad: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.intents[1].amount_wad")),
            limitPriceWad: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.intents[1].limit_price_wad")),
            nonce: vm.parseUint(vm.parseJsonString(rawJson, "$[0].input.intents[1].nonce")),
            r: vm.parseJsonBytes32(rawJson, "$[0].input.intents[1].auth.r"),
            s: vm.parseJsonBytes32(rawJson, "$[0].input.intents[1].auth.s")
        });

        vm.prank(relayer);
        (uint32 cyc0, uint256 matchedVol0) = g0.settleBatch(parts0, obs0, its0);

        uint256 expCycles = vm.parseJsonUint(rawJson, "$[0].expected_receipt.cycles_eliminated");
        uint256 expCompressed0 = vm.parseUint(vm.parseJsonString(rawJson, "$[0].expected_receipt.compressed_volume_by_asset['0']"));
        uint256 expClearPrice = vm.parseUint(vm.parseJsonString(rawJson, "$[0].expected_receipt.auctions[0].clearing_price_wad"));
        uint256 expMatchedVol = vm.parseUint(vm.parseJsonString(rawJson, "$[0].expected_receipt.auctions[0].matched_volume_wad"));
        int256 expAcc0Usdc = vm.parseInt(vm.parseJsonString(rawJson, "$[0].expected_receipt.post_accounts[0].balances[0]"));
        int256 expAcc0Weth = vm.parseInt(vm.parseJsonString(rawJson, "$[0].expected_receipt.post_accounts[0].balances[1]"));

        require(cyc0 == expCycles && expCompressed0 == 2400 * WAD && expClearPrice == 2500 * WAD, "golden_01 cycle/price mismatch");
        require(matchedVol0 == expMatchedVol, "golden_01 matched volume mismatch");
        require(g0.getAccountBalance(a0, 0) == expAcc0Usdc, "golden_01 acc0 USDC mismatch");
        require(g0.getAccountBalance(a0, 1) == expAcc0Weth, "golden_01 acc0 WETH mismatch");
    }

    function testGolden02_F01UnsignedObligationDrainRejected() public {
        string memory rawJson = vm.readFile("tests/vectors/golden_batches.json");
        GoldenHarness g1 = _mountGoldenEngine(1_000, 43);
        address a0 = vm.parseJsonAddress(rawJson, "$[1].input.accounts[0].address");
        address relayer = vm.parseJsonAddress(rawJson, "$[1].input.accounts[1].address");

        g1.seedAccountBalance(a0, 0, int256(10_000 * WAD));
        g1.seedAccountBalance(a0, 1, int256(4 * WAD));

        address[] memory parts1 = new address[](2);
        parts1[0] = a0;
        parts1[1] = relayer;
        ISettlementEngine.ObligationInput[] memory obs1 = new ISettlementEngine.ObligationInput[](1);
        obs1[0] = ISettlementEngine.ObligationInput({
            debtor: 0,
            creditor: 1,
            assetId: 0,
            authMode: 0,
            v: 0,
            maxEpoch: 0,
            amountWad: vm.parseUint(vm.parseJsonString(rawJson, "$[1].input.obligations[0].amount_wad")),
            nonce: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        ISettlementEngine.SignedTradeIntent[] memory emptyIts = new ISettlementEngine.SignedTradeIntent[](0);

        vm.prank(relayer);
        vm.expectRevert(ISettlementEngine.UnauthorizedObligation.selector);
        g1.settleBatch(parts1, obs1, emptyIts);
    }

    function testGolden03_F02OverLeveragedShortRollback() public {
        string memory rawJson = vm.readFile("tests/vectors/golden_batches.json");
        GoldenHarness g2 = _mountGoldenEngine(1_000, 44);
        address relayer = vm.parseJsonAddress(rawJson, "$[2].input.accounts[0].address");
        address a1 = vm.parseJsonAddress(rawJson, "$[2].input.accounts[1].address");

        g2.seedAccountBalance(relayer, 0, int256(10_000 * WAD));
        g2.seedAccountBalance(a1, 2, int256(400 * WAD));

        address[] memory parts2 = new address[](2);
        parts2[0] = relayer;
        parts2[1] = a1;
        ISettlementEngine.ObligationInput[] memory emptyObs = new ISettlementEngine.ObligationInput[](0);
        ISettlementEngine.SignedTradeIntent[] memory its2 = new ISettlementEngine.SignedTradeIntent[](2);
        its2[0] = ISettlementEngine.SignedTradeIntent({
            trader: 0,
            baseAsset: 1,
            quoteAsset: 0,
            side: 0,
            authMode: 0,
            v: 0,
            maxEpoch: 100,
            amountWad: 2 * WAD,
            limitPriceWad: 2500 * WAD,
            nonce: 1,
            r: bytes32(0),
            s: bytes32(0)
        });
        its2[1] = ISettlementEngine.SignedTradeIntent({
            trader: 1,
            baseAsset: 1,
            quoteAsset: 0,
            side: 1,
            authMode: 1,
            v: uint8(vm.parseJsonUint(rawJson, "$[2].input.intents[1].auth.v")),
            maxEpoch: 100,
            amountWad: 2 * WAD,
            limitPriceWad: 2500 * WAD,
            nonce: 2,
            r: vm.parseJsonBytes32(rawJson, "$[2].input.intents[1].auth.r"),
            s: vm.parseJsonBytes32(rawJson, "$[2].input.intents[1].auth.s")
        });

        vm.prank(relayer);
        vm.expectRevert(ISettlementEngine.InsufficientInitialMargin.selector);
        g2.settleBatch(parts2, emptyObs, its2);
    }

    function testGolden04_StaleMarkPriceRejected() public {
        string memory rawJson = vm.readFile("tests/vectors/golden_batches.json");
        GoldenHarness g3 = _mountGoldenEngine(6_000, 45);
        address relayer = vm.parseJsonAddress(rawJson, "$[3].input.accounts[0].address");

        address[] memory parts3 = new address[](1);
        parts3[0] = relayer;
        ISettlementEngine.ObligationInput[] memory emptyObs = new ISettlementEngine.ObligationInput[](0);
        ISettlementEngine.SignedTradeIntent[] memory emptyIts = new ISettlementEngine.SignedTradeIntent[](0);

        vm.prank(relayer);
        vm.expectRevert(ISettlementEngine.StaleMarkPrice.selector);
        g3.settleBatch(parts3, emptyObs, emptyIts);
    }

    function testV05_ImmutableAssetDecimalsWashTradeLiquidationAndDustSweep() public {
        // 1. CRIT-01: Overwriting initialized asset decimals or duplicating token address reverts
        vm.expectRevert(ISettlementEngine.InvalidAssetConfig.selector);
        engine.configureAsset(0, address(usdc6), 18, 1 * WAD, 0, 500, 250);

        vm.expectRevert(ISettlementEngine.InvalidAssetConfig.selector);
        engine.configureAsset(3, address(usdc6), 6, 1 * WAD, 0, 500, 250);

        // 2. CRIT-02: Self-trade wash volume & empty batch Epoch DoS revert
        address alice = address(0xA11CE);
        address bob = vm.addr(0xB0B);
        usdc6.mint(alice, 10_000e6);
        weth18.mint(bob, 5e18);
        vm.prank(alice);
        usdc6.approve(address(engine), type(uint256).max);
        vm.prank(alice);
        engine.deposit(0, 10_000e6);
        vm.prank(bob);
        weth18.approve(address(engine), type(uint256).max);
        vm.prank(bob);
        engine.deposit(1, 5e18);

        address[] memory p1 = new address[](1);
        p1[0] = alice;
        ISettlementEngine.ObligationInput[] memory noObs = new ISettlementEngine.ObligationInput[](0);
        ISettlementEngine.SignedTradeIntent[] memory noIts = new ISettlementEngine.SignedTradeIntent[](0);
        vm.prank(alice);
        vm.expectRevert(ISettlementEngine.InvalidIntent.selector);
        engine.settleBatch(p1, noObs, noIts);

        ISettlementEngine.SignedTradeIntent[] memory washIts = new ISettlementEngine.SignedTradeIntent[](2);
        washIts[0] = ISettlementEngine.SignedTradeIntent({trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 0, v: 0, maxEpoch: 50, amountWad: 1 * WAD, limitPriceWad: 2500 * WAD, nonce: 1, r: bytes32(0), s: bytes32(0)});
        washIts[1] = ISettlementEngine.SignedTradeIntent({trader: 0, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 0, v: 0, maxEpoch: 50, amountWad: 1 * WAD, limitPriceWad: 2500 * WAD, nonce: 2, r: bytes32(0), s: bytes32(0)});
        vm.prank(alice);
        vm.expectRevert(ISettlementEngine.InvalidIntent.selector);
        engine.settleBatch(p1, noObs, washIts);

        // 3. CRIT-03: Sub-quantum 6-decimal USDC dust sweeps cleanly to feeVault -> 100% ERC-20 custody solvency!
        address[] memory pair = new address[](2);
        pair[0] = alice;
        pair[1] = bob;
        uint256 oddLot = 1_000_000_001_000_000_000; // 1.000000001 WETH -> 2500.0000025 USDC (0.5 micro-USDC each!)
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(
            0xB0B,
            keccak256(abi.encodePacked("\x19\x01", engine.domainSeparator(), keccak256(abi.encode(engine.TRADE_INTENT_TYPEHASH(), bob, uint8(1), uint8(0), uint8(1), oddLot, 2500 * WAD, uint64(50), uint256(1)))))
        );
        ISettlementEngine.SignedTradeIntent[] memory oddIts = new ISettlementEngine.SignedTradeIntent[](2);
        oddIts[0] = ISettlementEngine.SignedTradeIntent({trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 0, v: 0, maxEpoch: 50, amountWad: oddLot, limitPriceWad: 2500 * WAD, nonce: 7, r: bytes32(0), s: bytes32(0)});
        oddIts[1] = ISettlementEngine.SignedTradeIntent({trader: 1, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 1, v: vB, maxEpoch: 50, amountWad: oddLot, limitPriceWad: 2500 * WAD, nonce: 1, r: rB, s: sB});
        vm.prank(alice);
        engine.settleBatch(pair, noObs, oddIts);

        vm.prank(alice);
        uint256 dAlice = engine.sweepDustToFeeVault(0);
        vm.prank(bob);
        uint256 dBob = engine.sweepDustToFeeVault(0);
        require(dAlice + dBob == 1e12, "sub-quantum dust must sum to 1 raw micro-USDC");
        uint256 swept = engine.sweepFeeVault(0, address(this));
        require(swept == 1e12 && usdc6.balanceOf(address(this)) == 1, "feeVault sweeps final 1 raw USDC cleanly");

        // 4. CRIT-03: Permissionless liquidation closes underwater short
        SolidityClearingBenchmark liqSim = new SolidityClearingBenchmark(address(this), true);
        liqSim.configureAsset(0, address(0), 6, 1 * WAD, 0, 500, 250);
        liqSim.configureAsset(1, address(0), 18, 2850 * WAD, 500, 1000, 500);
        address underwater = address(0xDEAD1);
        address liquidator = address(0xCAFE1);
        liqSim.seedAccountBalance(underwater, 0, int256(2900 * WAD));
        liqSim.seedAccountBalance(underwater, 1, -int256(1 * WAD));
        liqSim.seedAccountBalance(liquidator, 1, int256(5 * WAD));
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = liqSim.liquidate(underwater, 1, 0, 1 * WAD);
        require(repaid == 992_725_716_730_851_519 && seized == 2900 * WAD, "proportional cap liquidation mismatch");
        require(liqSim.getAccountBalance(underwater, 1) == -7_274_283_269_148_481, "residual debt mismatch");

        // TKT-022: Collateral-capped 1,000 USDC + high-price 512-bit safety
        SolidityClearingBenchmark capSim = new SolidityClearingBenchmark(address(this), true);
        capSim.configureAsset(0, address(0), 6, 1 * WAD, 0, 500, 250);
        capSim.configureAsset(1, address(0), 18, 2850 * WAD, 500, 1000, 500);
        capSim.seedAccountBalance(underwater, 0, int256(1000 * WAD));
        capSim.seedAccountBalance(underwater, 1, -int256(1 * WAD));
        capSim.seedAccountBalance(liquidator, 1, int256(5 * WAD));
        vm.prank(liquidator);
        (uint256 cRepaid, uint256 cSeized) = capSim.liquidate(underwater, 1, 0, 1 * WAD);
        require(cSeized == 1000 * WAD && cRepaid == 342_319_212_665_810_868, "1000 USDC cap mismatch");

        uint256 hiPx = 2 * (10 ** 73);
        SolidityClearingBenchmark hiSim = new SolidityClearingBenchmark(address(this), true);
        hiSim.configureAsset(0, address(0), 18, hiPx, 0, 500, 250);
        hiSim.configureAsset(1, address(0), 18, hiPx, 500, 1000, 500);
        hiSim.seedAccountBalance(underwater, 0, int256(uint256(2_050_000_000)));
        hiSim.seedAccountBalance(underwater, 1, -int256(uint256(2_000_000_000)));
        hiSim.seedAccountBalance(liquidator, 1, int256(uint256(10_000_000_000)));
        vm.prank(liquidator);
        (uint256 hRepaid, uint256 hSeized) = hiSim.liquidate(underwater, 1, 0, 1_000_000_000);
        require(hRepaid == 1_000_000_000 && hSeized == 1_025_000_000, "high-price 512-bit liquidation failed");
    }

    function testCrit01_InsolventHaircutSwapLosingNetEquityReverts() public {
        SolidityClearingBenchmark sim = new SolidityClearingBenchmark(address(this), true);
        sim.configureAsset(0, address(0), 6, 1 * WAD, 0, 500, 250);
        sim.configureAsset(1, address(0), 18, 2500 * WAD, 500, 1000, 500);
        sim.configureAsset(2, address(0), 18, 12e17, 1500, 1500, 800);

        address distressed = address(0xD101);
        uint256 pkLp = 0x9911;
        address lp = vm.addr(pkLp);

        sim.seedAccountBalance(distressed, 1, -450_000_000_000_000_000);
        sim.seedAccountBalance(distressed, 2, int256(1_000 * WAD));
        sim.seedAccountBalance(lp, 0, int256(5_000 * WAD));
        sim.seedAccountBalance(lp, 1, int256(1 * WAD));

        uint256 px = 105e16;
        (uint8 vLp, bytes32 rLp, bytes32 sLp) = vm.sign(
            pkLp,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    sim.domainSeparator(),
                    keccak256(abi.encode(sim.TRADE_INTENT_TYPEHASH(), lp, uint8(2), uint8(0), uint8(0), 1_000 * WAD, px, uint64(10), uint256(1)))
                )
            )
        );

        address[] memory parts = new address[](2);
        parts[0] = distressed;
        parts[1] = lp;
        ISettlementEngine.ObligationInput[] memory emptyObs = new ISettlementEngine.ObligationInput[](0);
        ISettlementEngine.SignedTradeIntent[] memory its = new ISettlementEngine.SignedTradeIntent[](2);
        its[0] = ISettlementEngine.SignedTradeIntent({
            trader: 0,
            baseAsset: 2,
            quoteAsset: 0,
            side: 1,
            authMode: 0,
            v: 0,
            maxEpoch: 10,
            amountWad: 1_000 * WAD,
            limitPriceWad: px,
            nonce: 1,
            r: bytes32(0),
            s: bytes32(0)
        });
        its[1] = ISettlementEngine.SignedTradeIntent({
            trader: 1,
            baseAsset: 2,
            quoteAsset: 0,
            side: 0,
            authMode: 1,
            v: vLp,
            maxEpoch: 10,
            amountWad: 1_000 * WAD,
            limitPriceWad: px,
            nonce: 1,
            r: rLp,
            s: sLp
        });

        vm.prank(distressed);
        vm.expectRevert(ISettlementEngine.HealthMonotonicityViolated.selector);
        sim.settleBatch(parts, emptyObs, its);
    }

    function testF02_MultiDecimalVaultAndDebtGatedStaleOracleWithdraw() public {
        uint256 pkBuyer = 0x1010;
        uint256 pkSeller = 0x2020;
        address buyer = vm.addr(pkBuyer);
        address seller = vm.addr(pkSeller);

        usdc6.mint(buyer, 6_000e6);
        usdc6.mint(seller, 600e6);

        vm.prank(buyer);
        usdc6.approve(address(engine), type(uint256).max);
        vm.prank(buyer);
        int256 bBal = engine.deposit(0, 6_000e6);
        require(bBal == int256(6_000 * WAD), "6-decimal USDC must scale to 6000 WAD");

        vm.prank(seller);
        usdc6.approve(address(engine), type(uint256).max);
        vm.prank(seller);
        engine.deposit(0, 600e6);

        address[] memory participants = new address[](2);
        participants[0] = buyer;
        participants[1] = seller;

        bytes32 domSep = engine.domainSeparator();
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(
            pkBuyer,
            keccak256(abi.encodePacked("\x19\x01", domSep, keccak256(abi.encode(engine.TRADE_INTENT_TYPEHASH(), buyer, uint8(1), uint8(0), uint8(0), 1 * WAD, 2500 * WAD, uint64(50), uint256(1)))))
        );
        (uint8 vS, bytes32 rS, bytes32 sS) = vm.sign(
            pkSeller,
            keccak256(abi.encodePacked("\x19\x01", domSep, keccak256(abi.encode(engine.TRADE_INTENT_TYPEHASH(), seller, uint8(1), uint8(0), uint8(1), 1 * WAD, 2500 * WAD, uint64(50), uint256(2)))))
        );

        ISettlementEngine.ObligationInput[] memory emptyObs = new ISettlementEngine.ObligationInput[](0);
        ISettlementEngine.SignedTradeIntent[] memory intents = new ISettlementEngine.SignedTradeIntent[](2);
        intents[0] = ISettlementEngine.SignedTradeIntent({trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 1, v: vB, maxEpoch: 50, amountWad: 1 * WAD, limitPriceWad: 2500 * WAD, nonce: 1, r: rB, s: sB});
        intents[1] = ISettlementEngine.SignedTradeIntent({trader: 1, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 1, v: vS, maxEpoch: 50, amountWad: 1 * WAD, limitPriceWad: 2500 * WAD, nonce: 2, r: rS, s: sS});

        engine.settleBatch(participants, emptyObs, intents);

        vm.prank(seller);
        vm.expectRevert(ISettlementEngine.InsufficientInitialMargin.selector);
        engine.withdraw(0, 400e6);

        vm.warp(6_000);
        vm.prank(seller);
        vm.expectRevert(ISettlementEngine.StaleMarkPrice.selector);
        engine.withdraw(0, 100e6);

        // HIGH-04: Nonce cancellation works unconditionally even during StaleMarkPrice!
        vm.prank(seller);
        uint256 maskAfter = engine.invalidateNonces(0, 0xFF00);
        require((maskAfter & 0xFF00) == 0xFF00, "invalidateNonces must succeed during stale oracle");

        vm.prank(buyer);
        engine.withdraw(0, 500e6);
        require(usdc6.balanceOf(buyer) == 500e6, "debt-free buyer must withdraw during stale oracle");

        engine.updateMarkPrice(0, 1 * WAD);
        engine.updateMarkPrice(1, 2500 * WAD);
        vm.prank(seller);
        engine.withdraw(0, 300e6);
        require(usdc6.balanceOf(seller) == 300e6, "expected 300e6 raw USDC withdrawn with unused asset stale");
    }

    function testTkt012_CrossPairRefTickClearsFractionalOrder() public {
        SolidityClearingBenchmark sim = new SolidityClearingBenchmark(address(this), true);
        sim.configureAsset(0, address(0), 6, 1 * WAD, 0, 500, 250);
        sim.configureAsset(1, address(0), 18, 2499 * WAD, 500, 1000, 500);
        sim.configureAsset(2, address(0), 18, 12e17, 1500, 1500, 800);

        address buyer = address(0xD001);
        uint256 pkSeller = 0x8181;
        address seller = vm.addr(pkSeller);
        sim.seedAccountBalance(buyer, 1, int256(1 * WAD));
        sim.seedAccountBalance(seller, 2, int256(2 * WAD));

        uint256 halfArb = 5e17;
        uint256 bidP = 500_000_000_000_000;
        uint256 askP = 460_000_000_000_000;
        (uint8 vS, bytes32 rS, bytes32 sS) = vm.sign(
            pkSeller,
            keccak256(abi.encodePacked("\x19\x01", sim.domainSeparator(), keccak256(abi.encode(sim.TRADE_INTENT_TYPEHASH(), seller, uint8(2), uint8(1), uint8(1), halfArb, askP, uint64(20), uint256(1)))))
        );

        address[] memory parts = new address[](2);
        parts[0] = buyer;
        parts[1] = seller;
        ISettlementEngine.ObligationInput[] memory emptyObs = new ISettlementEngine.ObligationInput[](0);
        ISettlementEngine.SignedTradeIntent[] memory its = new ISettlementEngine.SignedTradeIntent[](2);
        its[0] = ISettlementEngine.SignedTradeIntent({trader: 0, baseAsset: 2, quoteAsset: 1, side: 0, authMode: 0, v: 0, maxEpoch: 20, amountWad: halfArb, limitPriceWad: bidP, nonce: 1, r: bytes32(0), s: bytes32(0)});
        its[1] = ISettlementEngine.SignedTradeIntent({trader: 1, baseAsset: 2, quoteAsset: 1, side: 1, authMode: 1, v: vS, maxEpoch: 20, amountWad: halfArb, limitPriceWad: askP, nonce: 1, r: rS, s: sS});

        vm.prank(buyer);
        (, uint256 matched) = sim.settleBatch(parts, emptyObs, its);
        require(matched == halfArb, "0.5 ARB fractional cross-pair order must clear at refTick");
    }

    function testFuzz_CycleCompressionConservesNetPositions(uint64 w01, uint64 w12, uint64 w20) public {
        uint256 a01 = (uint256(w01) % 5_000 + 1) * 1e15;
        uint256 a12 = (uint256(w12) % 5_000 + 1) * 1e15;
        uint256 a20 = (uint256(w20) % 5_000 + 1) * 1e15;

        SolidityClearingBenchmark sim = new SolidityClearingBenchmark(address(this), true);
        sim.configureAsset(0, address(0), 6, 1 * WAD, 0, 500, 250);

        address p0 = address(0x1001);
        address p1 = address(0x1002);
        address p2 = address(0x1003);
        sim.seedAccountBalance(p0, 0, int256(20_000 * WAD));
        sim.seedAccountBalance(p1, 0, int256(20_000 * WAD));
        sim.seedAccountBalance(p2, 0, int256(20_000 * WAD));

        vm.prank(p0);
        sim.registerObligation(p1, 0, a01);
        vm.prank(p1);
        sim.registerObligation(p2, 0, a12);
        vm.prank(p2);
        sim.registerObligation(p0, 0, a20);

        address[] memory parts = new address[](3);
        parts[0] = p0;
        parts[1] = p1;
        parts[2] = p2;
        ISettlementEngine.ObligationInput[] memory obs = new ISettlementEngine.ObligationInput[](3);
        obs[0] = ISettlementEngine.ObligationInput({debtor: 0, creditor: 1, assetId: 0, authMode: 0, v: 0, maxEpoch: 0, amountWad: a01, nonce: 0, r: bytes32(0), s: bytes32(0)});
        obs[1] = ISettlementEngine.ObligationInput({debtor: 1, creditor: 2, assetId: 0, authMode: 0, v: 0, maxEpoch: 0, amountWad: a12, nonce: 0, r: bytes32(0), s: bytes32(0)});
        obs[2] = ISettlementEngine.ObligationInput({debtor: 2, creditor: 0, assetId: 0, authMode: 0, v: 0, maxEpoch: 0, amountWad: a20, nonce: 0, r: bytes32(0), s: bytes32(0)});
        ISettlementEngine.SignedTradeIntent[] memory emptyIntents = new ISettlementEngine.SignedTradeIntent[](0);

        (uint32 cyc, ) = sim.settleBatch(parts, obs, emptyIntents);
        require(cyc == 1, "triangle cycle must always eliminate 1 cycle");

        int256 sumAfter = sim.getAccountBalance(p0, 0) + sim.getAccountBalance(p1, 0) + sim.getAccountBalance(p2, 0);
        require(sumAfter == int256(60_000 * WAD), "exact zero-sum conservation violated");
    }

    function testFuzz_UnalignedPriceProRataAndDustConservation(uint64 b1Raw, uint64 b2Raw, uint64 s1Raw, uint32 weiJitter) public {
        uint256 b1Amt = (uint256(b1Raw) % 5_000 + 1) * 1e9;
        uint256 b2Amt = (uint256(b2Raw) % 5_000 + 1) * 1e9;
        uint256 s1Amt = (uint256(s1Raw) % 8_000 + 1) * 1e9;
        uint256 bid1P = 2515 * WAD + (uint256(weiJitter) % 999_999_999);
        uint256 bid2P = 2505 * WAD + ((uint256(weiJitter) * 7) % 999_999_999);
        uint256 ask1P = 2485 * WAD + ((uint256(weiJitter) * 13) % 999_999_999);

        SolidityClearingBenchmark sim = new SolidityClearingBenchmark(address(this), true);
        sim.configureAsset(0, address(0), 6, 1 * WAD, 0, 500, 250);
        sim.configureAsset(1, address(0), 18, 2500 * WAD, 500, 1000, 500);

        uint256 pkB1 = 0xA11;
        uint256 pkB2 = 0xA22;
        uint256 pkS1 = 0xB33;
        address b1Addr = vm.addr(pkB1);
        address b2Addr = vm.addr(pkB2);
        address s1Addr = vm.addr(pkS1);
        sim.seedAccountBalance(b1Addr, 0, int256(50_000 * WAD));
        sim.seedAccountBalance(b2Addr, 0, int256(50_000 * WAD));
        sim.seedAccountBalance(s1Addr, 1, int256(20 * WAD));

        bytes32 dom = sim.domainSeparator();
        (uint8 vb1, bytes32 rb1, bytes32 sb1) = vm.sign(
            pkB1,
            keccak256(abi.encodePacked("\x19\x01", dom, keccak256(abi.encode(sim.TRADE_INTENT_TYPEHASH(), b1Addr, uint8(1), uint8(0), uint8(0), b1Amt, bid1P, uint64(10), uint256(1)))))
        );
        (uint8 vb2, bytes32 rb2, bytes32 sb2) = vm.sign(
            pkB2,
            keccak256(abi.encodePacked("\x19\x01", dom, keccak256(abi.encode(sim.TRADE_INTENT_TYPEHASH(), b2Addr, uint8(1), uint8(0), uint8(0), b2Amt, bid2P, uint64(10), uint256(2)))))
        );
        (uint8 vs1, bytes32 rs1, bytes32 ss1) = vm.sign(
            pkS1,
            keccak256(abi.encodePacked("\x19\x01", dom, keccak256(abi.encode(sim.TRADE_INTENT_TYPEHASH(), s1Addr, uint8(1), uint8(0), uint8(1), s1Amt, ask1P, uint64(10), uint256(3)))))
        );

        address[] memory parts = new address[](3);
        parts[0] = b1Addr;
        parts[1] = b2Addr;
        parts[2] = s1Addr;
        ISettlementEngine.ObligationInput[] memory emptyObs = new ISettlementEngine.ObligationInput[](0);
        ISettlementEngine.SignedTradeIntent[] memory its = new ISettlementEngine.SignedTradeIntent[](3);
        its[0] = ISettlementEngine.SignedTradeIntent({trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 1, v: vb1, maxEpoch: 10, amountWad: b1Amt, limitPriceWad: bid1P, nonce: 1, r: rb1, s: sb1});
        its[1] = ISettlementEngine.SignedTradeIntent({trader: 1, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 1, v: vb2, maxEpoch: 10, amountWad: b2Amt, limitPriceWad: bid2P, nonce: 2, r: rb2, s: sb2});
        its[2] = ISettlementEngine.SignedTradeIntent({trader: 2, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 1, v: vs1, maxEpoch: 10, amountWad: s1Amt, limitPriceWad: ask1P, nonce: 3, r: rs1, s: ss1});

        sim.settleBatch(parts, emptyObs, its);
        int256 usdcSum = sim.getAccountBalance(b1Addr, 0) + sim.getAccountBalance(b2Addr, 0) + sim.getAccountBalance(s1Addr, 0) + int256(sim.getFeeVault(0));
        int256 wethSum = sim.getAccountBalance(b1Addr, 1) + sim.getAccountBalance(b2Addr, 1) + sim.getAccountBalance(s1Addr, 1) + int256(sim.getFeeVault(1));
        require(usdcSum == int256(100_000 * WAD), "USDC zero-sum violated");
        require(wethSum == int256(20 * WAD), "WETH zero-sum violated");
    }

    function testV07_PartialFillsSubQuantumRepayBadDebtAtomicFactoryAndCircuitBreakers() public {
        // 1. Atomic CREATE2 + initialize factory (`D-33`) + two-step admin (`D-32`)
        StylusAtomicFactory factory = new StylusAtomicFactory();
        bytes memory initCode = abi.encodePacked(
            type(SolidityClearingBenchmark).creationCode,
            abi.encode(address(0), false)
        );
        address deployed = factory.deployAndInitialize(initCode, bytes32(uint256(0x707)), address(this), true);
        SolidityClearingBenchmark sim = SolidityClearingBenchmark(deployed);
        require(sim.admin() == address(this), "atomic factory admin mismatch");

        address candAdmin = address(0xAD77);
        sim.transferAdmin(candAdmin);
        require(sim.pendingAdmin() == candAdmin, "pendingAdmin not recorded");
        vm.prank(candAdmin);
        sim.acceptAdmin();
        require(sim.admin() == candAdmin, "acceptAdmin failed");
        vm.prank(candAdmin);
        sim.transferAdmin(address(this));
        sim.acceptAdmin();

        // 2. Configure tight-MM stablecoins + WETH, verify 50% mark price step circuit breaker (`D-32`)
        MockERC20 usdg6 = new MockERC20("Global Dollar", "USDG", 6);
        sim.configureAsset(0, address(usdg6), 6, 1 * WAD, 0, 200, 100); // mmBps = 100 -> bonus = 50 bps (`D-01`)
        sim.configureAsset(1, address(0), 18, 2500 * WAD, 500, 1000, 500);
        sim.configureAsset(2, address(0), 6, 1 * WAD, 0, 200, 100);

        vm.expectRevert(ISettlementEngine.InvalidAssetConfig.selector);
        sim.updateMarkPrice(1, 4000 * WAD); // > +50% step rejected

        // 3. Tight-MM stablecoin liquidation (`mmBps = 100` -> `bonusBps = 50` avoids deadlock, `D-01`)
        address uwStable = address(0x57AB1E);
        address liqDesk = address(0x7100);
        usdg6.mint(uwStable, 10_050e6);
        vm.prank(uwStable);
        usdg6.approve(address(sim), type(uint256).max);
        vm.prank(uwStable);
        sim.deposit(0, 10_050e6);
        sim.seedAccountBalance(uwStable, 2, -int256(10_000 * WAD));
        sim.seedAccountBalance(liqDesk, 2, int256(20_000 * WAD));
        vm.prank(liqDesk);
        (uint256 repS, uint256 szS) = sim.liquidate(uwStable, 2, 0, 5_000 * WAD);
        require(repS == 5_000 * WAD && szS == 5_025 * WAD, "tight-MM 50 bps liquidation mismatch");

        // 4. Cumulative EIP-712 partial fill across two batches (`D-18`)
        uint256 pkBuyer = 0x4411;
        address buyer = vm.addr(pkBuyer);
        address s1 = address(0x5511);
        address s2 = address(0x5522);
        usdg6.mint(buyer, 10_000e6);
        vm.prank(buyer);
        usdg6.approve(address(sim), type(uint256).max);
        vm.prank(buyer);
        sim.deposit(0, 10_000e6);
        sim.seedAccountBalance(s1, 1, int256(1 * WAD));
        sim.seedAccountBalance(s2, 1, int256(2 * WAD));

        bytes32 dom = sim.domainSeparator();
        uint256 bNonce = 99;
        (uint8 vb, bytes32 rb, bytes32 sb) = vm.sign(
            pkBuyer,
            keccak256(abi.encodePacked("\x19\x01", dom, keccak256(abi.encode(sim.TRADE_INTENT_TYPEHASH(), buyer, uint8(1), uint8(0), uint8(0), 2 * WAD, 2500 * WAD, uint64(50), bNonce))))
        );

        address[] memory pBatch1 = new address[](2);
        pBatch1[0] = buyer;
        pBatch1[1] = s1;
        ISettlementEngine.ObligationInput[] memory noObs = new ISettlementEngine.ObligationInput[](0);
        ISettlementEngine.SignedTradeIntent[] memory its1 = new ISettlementEngine.SignedTradeIntent[](2);
        its1[0] = ISettlementEngine.SignedTradeIntent({trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 1, v: vb, maxEpoch: 50, amountWad: 2 * WAD, limitPriceWad: 2500 * WAD, nonce: bNonce, r: rb, s: sb});
        its1[1] = ISettlementEngine.SignedTradeIntent({trader: 1, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 0, v: 0, maxEpoch: 50, amountWad: 1 * WAD, limitPriceWad: 2500 * WAD, nonce: 1, r: bytes32(0), s: bytes32(0)});
        vm.prank(s1);
        (, uint256 mv1) = sim.settleBatch(pBatch1, noObs, its1);
        require(mv1 == 1 * WAD && sim.getPartialFill(buyer, bNonce) == 1 * WAD, "batch 1 partial fill failed");

        address[] memory pBatch2 = new address[](2);
        pBatch2[0] = buyer;
        pBatch2[1] = s2;
        ISettlementEngine.SignedTradeIntent[] memory its2 = new ISettlementEngine.SignedTradeIntent[](2);
        its2[0] = its1[0];
        its2[1] = ISettlementEngine.SignedTradeIntent({trader: 1, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 0, v: 0, maxEpoch: 50, amountWad: 2 * WAD, limitPriceWad: 2500 * WAD, nonce: 2, r: bytes32(0), s: bytes32(0)});
        vm.prank(s2);
        (, uint256 mv2) = sim.settleBatch(pBatch2, noObs, its2);
        require(mv2 == 1 * WAD && sim.getPartialFill(buyer, bNonce) == 0, "batch 2 remainder fill failed");

        // 5. Bad-debt socialization (`D-16`)
        address leaf = address(0xDEAD99);
        sim.seedAccountBalance(leaf, 1, -int256(1 * WAD));
        sim.seedAccountBalance(address(this), 1, int256(3 * WAD));
        uint256 absorbed = sim.absorbBadDebt(leaf, 1);
        require(absorbed == 1 * WAD && sim.getAccountBalance(leaf, 1) == 0, "absorbBadDebt failed");
    }

    function testV10_FactoryArbWasmRefundSubQuantumRepayAndGuards() public {
        vm.warp(1_000_000);
        StylusAtomicFactory factory = new StylusAtomicFactory();
        bytes memory initCode = abi.encodePacked(
            type(SolidityClearingBenchmark).creationCode,
            abi.encode(address(0), false)
        );
        vm.deal(address(this), 1 ether);
        uint256 balBefore = address(this).balance;
        address deployed = factory.deployAndInitialize{value: 0.25 ether}(
            initCode,
            keccak256("v10-refund"),
            address(this),
            true
        );
        require(address(this).balance == balBefore, "excess ETH must be refunded");
        SolidityClearingBenchmark eng = SolidityClearingBenchmark(deployed);
        require(eng.benchmarkSeedingEnabled(), "benchmarkSeedingEnabled must be true");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        eng.configureAsset(0, address(usdc), 6, 1 * WAD, 0, 1000, 500);
        vm.expectRevert(ISettlementEngine.InvalidAssetConfig.selector);
        eng.configureAsset(0, address(usdc), 6, 11 * WAD / 10, 0, 1000, 500);

        eng.configureAsset(1, address(0), 18, 2000 * WAD, 1000, 1500, 750);
        vm.expectRevert(ISettlementEngine.InvalidAssetConfig.selector);
        eng.seedAccountBalance(address(0), 1, int256(1 * WAD));

        eng.setRiskWindows(7200, 1500, false);
        require(eng.maxPriceStaleness() == 7200 && eng.maxPriceDeviationBps() == 1500 && !eng.permissionlessSolver(), "risk windows mismatch");
        address solver2 = address(0x5011);
        eng.setApprovedSolver(solver2, true);
        require(eng.approvedSolvers(solver2), "solver2 should be approved");
        eng.setApprovedSolver(solver2, false);
        require(!eng.approvedSolvers(solver2), "solver2 should be revoked");

        address cred = address(0xC0ED);
        uint256 totalOb = eng.registerObligation(cred, 0, 10 * WAD);
        require(totalOb == 10 * WAD, "registerObligation mismatch");
        uint256 remOb = eng.revokeObligation(cred, 0, 4 * WAD);
        require(remOb == 6 * WAD && eng.getConfirmedObligation(address(this), cred, 0) == 6 * WAD, "revokeObligation mismatch");

        // Dust full-debt liquidation clearance (< 1e9 wei 18-dec debt while underwater from another debt)
        address uw = address(0xD057);
        address liq = address(0x1100);
        eng.configureAsset(2, address(0), 18, 1 * WAD, 0, 1000, 500);
        eng.configureAsset(3, address(0), 18, 1 * WAD, 0, 1000, 500);
        eng.seedAccountBalance(uw, 1, -int256(500_000_000)); // -5e8 wei WETH ($1e-6)
        eng.seedAccountBalance(uw, 2, int256(5_000_000_000_000)); // +5e12 wei ($5e-6 collateral)
        eng.seedAccountBalance(uw, 3, -int256(10_000_000_000_000)); // -$10e-6 other debt -> underwater
        eng.seedAccountBalance(liq, 1, int256(1 * WAD));
        eng.seedAccountBalance(liq, 2, int256(100 * WAD));
        vm.prank(liq);
        (uint256 rep, uint256 sz) = eng.liquidate(uw, 1, 2, 1 * WAD);
        require(rep == 500_000_000 && sz > 0 && eng.getAccountBalance(uw, 1) == 0, "dust full-debt liquidation must clear debt");
    }

    receive() external payable {}
}

/// @title ClearingBenchmarkGas
/// @notice Fair, Cycle-Verified Multi-Chord Gas Harness (`forge test --offline --match-contract ClearingBenchmarkGas -vv`).
contract ClearingBenchmarkGas {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant WAD = 1e18;

    event BenchmarkGasMeasured(
        string workload,
        uint256 accounts,
        uint256 obligations,
        uint256 cyclesEliminated,
        uint256 intents,
        uint256 evmGasUsed
    );

    function setUp() public {
        vm.chainId(421614);
        vm.warp(1_000);
    }

    function _runWorkload(
        string memory label,
        uint16 nAcc,
        uint16 nObs,
        uint32 expectedCycles,
        uint16 nInt
    ) internal {
        SolidityClearingBenchmark sim = new SolidityClearingBenchmark(address(this), true);
        sim.configureAsset(0, address(0), 6, 1 * WAD, 0, 500, 250);
        sim.configureAsset(1, address(0), 18, 2500 * WAD, 500, 1000, 500);

        address[] memory parts = new address[](nAcc);
        for (uint16 u = 0; u < nAcc; u++) {
            address a = vm.addr(uint256(0x9000 + u));
            parts[u] = a;
            sim.seedAccountBalance(a, 0, int256(250_000 * WAD));
            sim.seedAccountBalance(a, 1, int256(80 * WAD));
            // Pre-warm bitmap word 0 so warm storage SSTORE cost is isolated fairly from cold account creation (`P0-3`)
            vm.prank(a);
            sim.invalidateNonces(0, 1);
        }

        // Authentic multi-cycle chord network: Hamiltonian backbone + distinct-weight chord back-edges (`P0-3`)
        ISettlementEngine.ObligationInput[] memory obs = new ISettlementEngine.ObligationInput[](nObs);
        for (uint16 i = 0; i < nObs; i++) {
            uint16 u;
            uint16 v;
            uint256 amt;
            if (i < nAcc) {
                u = i;
                v = (i + 1) % nAcc;
                amt = 2_000 * WAD;
            } else {
                uint16 k = i - nAcc;
                u = (k + 2) % nAcc;
                v = k % nAcc;
                amt = uint256(10 + k) * WAD;
            }
            vm.prank(parts[u]);
            sim.registerObligation(parts[v], 0, amt);
            obs[i] = ISettlementEngine.ObligationInput({
                debtor: u,
                creditor: v,
                assetId: 0,
                authMode: 0,
                v: 0,
                maxEpoch: 0,
                amountWad: amt,
                nonce: 0,
                r: bytes32(0),
                s: bytes32(0)
            });
        }

        // Realistic 16-level crossed limit orderbook without self-trade (`tr < half` BUY, `tr >= half` SELL)
        bytes32 dom = sim.domainSeparator();
        uint16 half = nAcc / 2;
        ISettlementEngine.SignedTradeIntent[] memory its = new ISettlementEngine.SignedTradeIntent[](nInt);
        for (uint16 i = 0; i < nInt; i++) {
            bool isBuy = (i % 2 == 0);
            uint16 tr = isBuy ? ((i / 2) % half) : (half + ((i / 2) % (nAcc - half)));
            uint8 side = isBuy ? 0 : 1;
            uint256 tickOffset = uint256((i / 2) % 8) * 2 * WAD;
            uint256 lim = isBuy ? (2502 * WAD + tickOffset) : (2498 * WAD - tickOffset);
            uint256 nonce = uint256(i) + 2; // bit 0 pre-warmed above
            (uint8 vSig, bytes32 rSig, bytes32 sSig) = vm.sign(
                uint256(0x9000 + tr),
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        dom,
                        keccak256(
                            abi.encode(
                                sim.TRADE_INTENT_TYPEHASH(),
                                parts[tr],
                                uint8(1),
                                uint8(0),
                                side,
                                1 * WAD,
                                lim,
                                uint64(100),
                                nonce
                            )
                        )
                    )
                )
            );
            its[i] = ISettlementEngine.SignedTradeIntent({
                trader: tr,
                baseAsset: 1,
                quoteAsset: 0,
                side: side,
                authMode: 1,
                v: vSig,
                maxEpoch: 100,
                amountWad: 1 * WAD,
                limitPriceWad: lim,
                nonce: nonce,
                r: rSig,
                s: sSig
            });
        }

        vm.cool(address(sim));
        uint256 g0 = gasleft();
        (uint32 cyc, uint256 matchedVol) = sim.settleBatch(parts, obs, its);
        require(evmCheckBelowLimit(g0 - gasleft()), "exceeds Arbitrum 32M single-block gas limit");
        uint256 evmUsed = g0 - gasleft();
        require(cyc == expectedCycles, "verified multi-cycle count mismatch");
        require(matchedVol > 0, "benchmark auction matched volume must be positive");
        emit BenchmarkGasMeasured(label, nAcc, nObs, cyc, nInt, evmUsed);
    }

    function evmCheckBelowLimit(uint256 g) internal pure returns (bool) {
        return g < 32_000_000;
    }

    function testBench01_Small_4Acc_5Ob_4Intent() public {
        _runWorkload("Small", 4, 5, 2, 4);
    }

    function testBench02_Medium_12Acc_20Ob_24Intent() public {
        _runWorkload("Medium", 12, 20, 9, 24);
    }

    function testBench03_Large_32Acc_64Ob_64Intent() public {
        _runWorkload("Large", 32, 64, 33, 64);
    }

    function testBench04_Stress_44Acc_88Ob_88Intent() public {
        _runWorkload("Stress", 44, 88, 45, 88);
    }

    function testV110_FactoryRejectsStrayEthAndFiveGettersParity() public {
        StylusAtomicFactory fac = new StylusAtomicFactory();
        (bool ok, ) = address(fac).call{value: 1 wei}("");
        require(!ok, "factory receive() must reject non-ArbWasm ETH");

        SolidityClearingBenchmark sim = new SolidityClearingBenchmark(address(this), true);
        require(sim.benchmarkSeedingEnabled(), "benchmarkSeedingEnabled getter");
        require(sim.permissionlessSolver(), "permissionlessSolver getter");
        require(sim.maxPriceStaleness() == 3600, "maxPriceStaleness getter");
        require(sim.maxPriceDeviationBps() == 2000, "maxPriceDeviationBps getter");
        require(!sim.approvedSolvers(address(0x1234)), "approvedSolvers getter");
    }

    function testV120_DustCollateralDeadlockBrokenAndErrorPrecedence() public {
        SolidityClearingBenchmark sim = new SolidityClearingBenchmark(address(this), true);
        sim.configureAsset(0, address(0), 6, WAD, 0, 500, 250);
        sim.configureAsset(1, address(0), 18, 2000 * WAD, 1000, 1000, 500);
        // Error precedence parity: invalid assetId/decimals precedes InvalidHaircut
        vm.expectRevert(ISettlementEngine.InvalidAssetConfig.selector);
        sim.configureAsset(5, address(0), 18, WAD, 10000, 500, 250);
        // Dust collateral (< MIN_INTENT_AMOUNT_WAD = 1e9) must NOT deadlock absorbBadDebt
        address victim = address(0xBEEF);
        sim.seedAccountBalance(victim, 0, -int256(10 * WAD));
        sim.seedAccountBalance(victim, 1, 500);
        sim.seedAccountBalance(address(this), 0, int256(100 * WAD));
        uint256 absorbed = sim.absorbBadDebt(victim, 0);
        require(absorbed == 10 * WAD, "absorbed bad debt mismatch");
        require(sim.getAccountBalance(victim, 0) == 0 && sim.getAccountBalance(victim, 1) == 0, "victim must be cleared");
        require(sim.getFeeVault(1) == 500, "dust collateral must sweep to fee vault");
    }
}
