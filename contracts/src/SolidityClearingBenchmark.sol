// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISettlementEngine} from "./ISettlementEngine.sol";
import {IERC20Minimal} from "./MockERC20.sol";
import {FullMath512} from "./FullMath512.sol";

/// @title SolidityClearingBenchmark
/// @notice Hardened pure-EVM reference clearing engine 100% ABI- and behavior-identical to StylusClear WASM (`v0.7.0`).
contract SolidityClearingBenchmark is ISettlementEngine {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_DENOM = 10_000;
    uint256 internal constant MIN_INTENT_AMOUNT_WAD = 1e9;
    uint16 internal constant LIQUIDATION_BONUS_CAP_BPS = 250;
    uint256 internal constant MAX_MARK_STEP_BPS = 5_000;
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SECP256K1_HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant TRADE_INTENT_TYPEHASH =
        keccak256(
            "TradeIntent(address trader,uint8 baseAsset,uint8 quoteAsset,uint8 side,uint256 amountWad,uint256 limitPriceWad,uint64 maxEpoch,uint256 nonce)"
        );
    bytes32 public constant OBLIGATION_ATTESTATION_TYPEHASH =
        keccak256(
            "ObligationAttestation(address debtor,address creditor,uint8 assetId,uint256 amountWad,uint64 maxEpoch,uint256 nonce)"
        );
    bytes32 internal constant NAME_HASH = keccak256("StylusClear");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    struct AssetConfig {
        address token;
        uint8 decimals;
        uint256 markPriceWad;
        uint64 priceUpdatedAt;
        uint16 haircutBps;
        uint16 imBps;
        uint16 mmBps;
        bool initialized;
    }

    struct RiskMetrics {
        uint256 grossCollateralWad;
        uint256 effectiveCollateralWad;
        uint256 totalLiabilityWad;
        uint256 requiredImWad;
        uint256 requiredMmWad;
        int256 netEquityWad;
        int256 healthWad;
        int256 imSurplusWad;
    }

    struct WorkIntent {
        uint16 trader;
        uint8 baseAsset;
        uint8 quoteAsset;
        uint8 side;
        uint8 authMode;
        uint256 amountWad;
        uint256 signedAmountWad;
        uint256 priorFilledWad;
        uint256 limitPriceWad;
        uint256 nonce;
    }

    address internal _admin;
    address internal _pendingAdmin;
    bool public benchmarkSeedingEnabled;
    bool public override permissionlessSolver;
    uint64 internal _currentEpoch;
    uint64 public override maxPriceStaleness;
    uint16 public override maxPriceDeviationBps;
    uint8 internal _assetCount;
    uint8 internal _unlocked = 1;

    mapping(address => bool) public override approvedSolvers;
    mapping(uint8 => AssetConfig) internal _assets;
    mapping(address => mapping(uint8 => int256)) internal _balances;
    mapping(address => mapping(address => mapping(uint8 => uint256))) internal _confirmedObligations;
    mapping(uint8 => uint256) internal _feeVault;
    mapping(uint8 => uint256) internal _vaultPhysicalRaw;
    mapping(address => mapping(uint256 => uint256)) internal _nonceBitmaps;
    mapping(address => mapping(uint256 => uint256)) internal _partialFills;

    function _rev(bytes4 sel) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, sel)
            revert(0x00, 0x04)
        }
    }

    function _onlyAdmin() internal view {
        if (_admin == address(0) || msg.sender != _admin) _rev(UnauthorizedCaller.selector);
    }

    function _eip712Digest(bytes32 domSep, bytes32 structHash) internal pure returns (bytes32 d) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x1901000000000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x02), domSep)
            mstore(add(ptr, 0x22), structHash)
            d := keccak256(ptr, 0x42)
        }
    }

    function _loadBals(address trader, uint8 nAssets) internal view returns (int256[] memory bals, uint16 mask) {
        bals = new int256[](nAssets);
        unchecked {
            for (uint8 a = 0; a < nAssets; ++a) {
                int256 b = _balances[trader][a];
                bals[a] = b;
                if (b != 0) mask |= uint16(1) << a;
            }
        }
    }

    function _checkFreshMask(uint16 mask, uint8 nAssets) internal view {
        uint256 maxStale = maxPriceStaleness;
        unchecked {
            for (uint8 a = 0; a < nAssets; ++a) {
                if ((mask & (uint16(1) << a)) != 0) {
                    uint64 upd = _assets[a].priceUpdatedAt;
                    if (block.timestamp < upd || (block.timestamp - upd) > maxStale) {
                        _rev(StaleMarkPrice.selector);
                    }
                }
            }
        }
    }

    function _checkNotLocked() internal view {
        if (_unlocked != 1) _rev(UnauthorizedCaller.selector);
    }

    modifier nonReentrant() {
        _checkNotLocked();
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    modifier checkUnlocked() {
        _checkNotLocked();
        _;
    }

    function _unitScale(uint8 dec) internal pure returns (uint256) {
        if (dec > 18) _rev(InvalidAssetConfig.selector);
        unchecked { return 10 ** (18 - dec); }
    }

    constructor(address admin_, bool benchmarkSeedingEnabled_) {
        if (admin_ != address(0)) {
            _initInternal(admin_, benchmarkSeedingEnabled_);
        }
    }

    function initialize(address initialAdmin, bool benchmarkSeedingEnabled_) external override checkUnlocked {
        if (_admin != address(0) || initialAdmin == address(0)) _rev(UnauthorizedCaller.selector);
        _initInternal(initialAdmin, benchmarkSeedingEnabled_);
    }

    function _initInternal(address admin_, bool seeding_) internal {
        _admin = admin_;
        benchmarkSeedingEnabled = seeding_;
        permissionlessSolver = true;
        _currentEpoch = 1;
        maxPriceStaleness = 3600;
        maxPriceDeviationBps = 2000;
        approvedSolvers[admin_] = true;
    }

    function admin() public view override returns (address) {
        return _admin;
    }

    function pendingAdmin() external view override returns (address) {
        return _pendingAdmin;
    }

    function transferAdmin(address newAdmin) external override checkUnlocked {
        _onlyAdmin();
        if (newAdmin == address(0)) _rev(InvalidAssetConfig.selector);
        _pendingAdmin = newAdmin;
        emit AdminTransferStarted(_admin, newAdmin);
    }

    function acceptAdmin() external override checkUnlocked {
        if (_pendingAdmin == address(0) || msg.sender != _pendingAdmin) _rev(UnauthorizedCaller.selector);
        address prev = _admin;
        _admin = msg.sender;
        _pendingAdmin = address(0);
        approvedSolvers[prev] = false;
        approvedSolvers[msg.sender] = true;
        emit AdminTransferred(prev, msg.sender);
    }

    function assetCount() external view override returns (uint8) {
        return _assetCount;
    }

    function currentEpoch() external view override returns (uint64) {
        return _currentEpoch;
    }

    function domainSeparator() public view override returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function getAccountBalance(address trader, uint8 assetId) external view override checkUnlocked returns (int256) {
        if (assetId >= _assetCount) _rev(InvalidAssetConfig.selector);
        return _balances[trader][assetId];
    }

    function getConfirmedObligation(address debtor, address creditor, uint8 assetId) external view override returns (uint256) {
        return _confirmedObligations[debtor][creditor][assetId];
    }

    function getFeeVault(uint8 assetId) external view override returns (uint256) {
        return _feeVault[assetId];
    }

    function getVaultPhysicalRaw(uint8 assetId) external view override checkUnlocked returns (uint256) {
        return _vaultPhysicalRaw[assetId];
    }

    function getNonceBitmap(address trader, uint256 wordPos) external view override returns (uint256) {
        return _nonceBitmaps[trader][wordPos];
    }

    function getPartialFill(address trader, uint256 nonce) external view override returns (uint256) {
        return _partialFills[trader][nonce];
    }

    function getAssetConfig(
        uint8 assetId
    )
        external
        view
        override
        returns (
            address token,
            uint8 decimals,
            uint256 markPriceWad,
            uint64 priceUpdatedAt,
            uint16 haircutBps,
            uint16 imBps,
            uint16 mmBps
        )
    {
        if (assetId >= _assetCount) _rev(InvalidAssetConfig.selector);
        AssetConfig memory c = _assets[assetId];
        return (c.token, c.decimals, c.markPriceWad, c.priceUpdatedAt, c.haircutBps, c.imBps, c.mmBps);
    }

    function getAccountRisk(
        address trader
    )
        external
        view
        override
        returns (
            uint256 effectiveCollateralWad,
            uint256 totalLiabilityWad,
            uint256 requiredImWad,
            uint256 requiredMmWad,
            int256 healthWad,
            int256 imSurplusWad
        )
    {
        uint8 nAssets = _assetCount;
        (int256[] memory bals, ) = _loadBals(trader, nAssets);
        RiskMetrics memory r = _evaluateRisk(bals, nAssets);
        return (
            r.effectiveCollateralWad,
            r.totalLiabilityWad,
            r.requiredImWad,
            r.requiredMmWad,
            r.healthWad,
            r.imSurplusWad
        );
    }

    function _requireValidTimestamp() internal view returns (uint64) {
        if (block.timestamp > type(uint64).max) _rev(InvalidAssetConfig.selector);
        return uint64(block.timestamp);
    }

    function _callToken(address token, bytes memory payload) internal {
        if (token == address(0) || token.code.length == 0) _rev(InvalidAssetConfig.selector);
        (bool ok, bytes memory ret) = token.call(payload);
        if (!ok || (ret.length != 0 && (ret.length != 32 || !abi.decode(ret, (bool))))) {
            _rev(InvalidAssetConfig.selector);
        }
    }

    function _safeTransferFromReceived(address token, address from, uint256 rawAmount) internal returns (uint256 received) {
        if (token == address(0) || token.code.length == 0) _rev(InvalidAssetConfig.selector);
        uint256 balBefore = IERC20Minimal(token).balanceOf(address(this));
        _callToken(token, abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, address(this), rawAmount));
        uint256 balAfter = IERC20Minimal(token).balanceOf(address(this));
        if (balAfter <= balBefore) _rev(InvalidAssetConfig.selector);
        unchecked { received = balAfter - balBefore; }
    }

    function _safeTransfer(address token, address to, uint256 rawAmount) internal {
        _callToken(token, abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, rawAmount));
    }

    function configureAsset(
        uint8 assetId,
        address token,
        uint8 decimals,
        uint256 markPriceWad,
        uint16 haircutBps,
        uint16 imBps,
        uint16 mmBps
    ) external override checkUnlocked {
        _onlyAdmin();
        if (decimals > 18 || markPriceWad == 0 || mmBps < 2 || mmBps > imBps || imBps > BPS_DENOM) {
            _rev(InvalidAssetConfig.selector);
        }
        if (haircutBps >= BPS_DENOM) _rev(InvalidHaircut.selector);
        if (assetId > _assetCount || assetId >= 16) _rev(InvalidAssetConfig.selector);
        if (token != address(0) && token.code.length == 0) _rev(InvalidAssetConfig.selector);

        AssetConfig storage existing = _assets[assetId];
        if (existing.initialized) {
            if (existing.token != token || existing.decimals != decimals) {
                _rev(InvalidAssetConfig.selector);
            }
            uint256 prev = existing.markPriceWad;
            uint256 diff = markPriceWad >= prev ? (markPriceWad - prev) : (prev - markPriceWad);
            if (FullMath512.gtMul512(diff, BPS_DENOM, prev, MAX_MARK_STEP_BPS)) {
                _rev(InvalidAssetConfig.selector);
            }
        } else if (token != address(0)) {
            for (uint8 p = 0; p < _assetCount; p++) {
                if (_assets[p].token == token) _rev(InvalidAssetConfig.selector);
            }
        }

        uint64 ts = _requireValidTimestamp();
        _assets[assetId] = AssetConfig({
            token: token,
            decimals: decimals,
            markPriceWad: markPriceWad,
            priceUpdatedAt: ts,
            haircutBps: haircutBps,
            imBps: imBps,
            mmBps: mmBps,
            initialized: true
        });
        if (assetId == _assetCount) {
            _assetCount += 1;
        }
    }

    function updateMarkPrice(uint8 assetId, uint256 markPriceWad) external override checkUnlocked {
        _onlyAdmin();
        if (assetId >= _assetCount || markPriceWad == 0) _rev(InvalidAssetConfig.selector);
        uint64 ts = _requireValidTimestamp();
        uint256 prev = _assets[assetId].markPriceWad;
        if (ts <= _assets[assetId].priceUpdatedAt && markPriceWad != prev) _rev(InvalidAssetConfig.selector);
        uint256 diff = markPriceWad >= prev ? (markPriceWad - prev) : (prev - markPriceWad);
        if (FullMath512.gtMul512(diff, BPS_DENOM, prev, MAX_MARK_STEP_BPS)) {
            _rev(InvalidAssetConfig.selector);
        }
        _assets[assetId].markPriceWad = markPriceWad;
        _assets[assetId].priceUpdatedAt = ts;
    }

    function setRiskWindows(uint64 maxStaleness, uint16 maxDeviationBps, bool permissionless) external override checkUnlocked {
        _onlyAdmin();
        if (maxStaleness == 0 || maxDeviationBps == 0 || maxDeviationBps > 5000) _rev(InvalidAssetConfig.selector);
        maxPriceStaleness = maxStaleness;
        maxPriceDeviationBps = maxDeviationBps;
        permissionlessSolver = permissionless;
        approvedSolvers[_admin] = true;
    }

    function setApprovedSolver(address solver, bool approved) external override checkUnlocked {
        _onlyAdmin();
        if (solver == address(0) || (solver == _admin && !approved)) _rev(InvalidAssetConfig.selector);
        approvedSolvers[solver] = approved;
        emit SolverApprovalUpdated(solver, approved);
    }

    function _scaleRawToWad(uint256 rawAmount, uint8 decimals) internal pure returns (uint256) {
        if (rawAmount == 0) _rev(InvalidAssetConfig.selector);
        return FullMath512.mulDivFloor(rawAmount, _unitScale(decimals), 1);
    }

    function _checkPostWithdrawalMargin(address trader, uint8 nAssets, uint8 ovAsset, int256 ovBal) internal view {
        (int256[] memory bals, ) = _loadBals(trader, nAssets);
        bals[ovAsset] = ovBal;
        RiskMetrics memory postRisk = _evaluateRisk(bals, nAssets);
        if (postRisk.totalLiabilityWad > 0) {
            uint16 m = 0;
            unchecked { for (uint8 a = 0; a < nAssets; ++a) { if (bals[a] != 0) m |= uint16(1) << a; } }
            _checkFreshMask(m, nAssets);
            if (postRisk.imSurplusWad < 0) {
                _rev(InsufficientInitialMargin.selector);
            }
        }
    }

    function deposit(uint8 assetId, uint256 rawAmount) external override nonReentrant returns (int256 newBalanceWad) {
        if (assetId >= _assetCount || rawAmount == 0) _rev(InvalidAssetConfig.selector);
        AssetConfig memory cfg = _assets[assetId];
        uint256 receivedRaw = _safeTransferFromReceived(cfg.token, msg.sender, rawAmount);
        int256 wadDelta = FullMath512.toInt256(_scaleRawToWad(receivedRaw, cfg.decimals));
        int256 next = FullMath512.checkedAddI256(_balances[msg.sender][assetId], wadDelta);
        _vaultPhysicalRaw[assetId] = FullMath512.checkedAddU256(_vaultPhysicalRaw[assetId], receivedRaw);
        _balances[msg.sender][assetId] = next;
        emit CollateralDeposited(msg.sender, assetId, receivedRaw, next);
        return next;
    }

    function withdraw(uint8 assetId, uint256 rawAmount) external override nonReentrant returns (int256 newBalanceWad) {
        uint8 nAssets = _assetCount;
        if (assetId >= nAssets || rawAmount == 0) _rev(InvalidAssetConfig.selector);
        AssetConfig memory cfg = _assets[assetId];
        if (cfg.token == address(0) || cfg.token.code.length == 0) _rev(InvalidAssetConfig.selector);
        int256 wadDelta = FullMath512.toInt256(_scaleRawToWad(rawAmount, cfg.decimals));

        int256 prev = _balances[msg.sender][assetId];
        if (prev < wadDelta) _rev(InsufficientWithdrawableBalance.selector);
        uint256 vRaw = _vaultPhysicalRaw[assetId];
        if (vRaw < rawAmount || IERC20Minimal(cfg.token).balanceOf(address(this)) < rawAmount) {
            _rev(InsufficientWithdrawableBalance.selector);
        }
        newBalanceWad = FullMath512.checkedSubI256(prev, wadDelta);

        _checkPostWithdrawalMargin(msg.sender, nAssets, assetId, newBalanceWad);

        _vaultPhysicalRaw[assetId] = vRaw - rawAmount;
        _balances[msg.sender][assetId] = newBalanceWad;
        _safeTransfer(cfg.token, msg.sender, rawAmount);

        emit CollateralWithdrawn(msg.sender, assetId, rawAmount, newBalanceWad);
    }

    function repaySubQuantumDebt(uint8 assetId) external override nonReentrant returns (int256 newBalanceWad) {
        if (assetId >= _assetCount) _rev(InvalidAssetConfig.selector);
        AssetConfig memory cfg = _assets[assetId];
        uint256 quantumWad = _unitScale(cfg.decimals);
        int256 cur = _balances[msg.sender][assetId];
        if (cur >= 0) _rev(InvalidIntent.selector);
        if (cur == type(int256).min || uint256(-cur) >= quantumWad) _rev(InvalidIntent.selector);

        uint256 received = _safeTransferFromReceived(cfg.token, msg.sender, 1);
        uint256 addWad = FullMath512.mulDivFloor(received, quantumWad, 1);
        newBalanceWad = FullMath512.checkedAddI256(cur, FullMath512.toInt256(addWad));
        _vaultPhysicalRaw[assetId] = FullMath512.checkedAddU256(_vaultPhysicalRaw[assetId], received);
        _balances[msg.sender][assetId] = newBalanceWad;
        emit SubQuantumDebtRepaid(msg.sender, assetId, received, newBalanceWad);
    }

    function absorbBadDebt(address underwater, uint8 debtAsset) external override checkUnlocked returns (uint256 absorbedWad) {
        uint8 nAssets = _assetCount;
        if (underwater == address(0) || debtAsset >= nAssets) _rev(InvalidAssetConfig.selector);
        for (uint8 a = 0; a < nAssets; a++) {
            if (_balances[underwater][a] > 0) _rev(InvalidIntent.selector);
        }
        int256 dBal = _balances[underwater][debtAsset];
        if (dBal >= 0) _rev(InvalidIntent.selector);
        if (dBal == type(int256).min) _rev(MathOverflow.selector);
        absorbedWad = uint256(-dBal);

        uint256 feeBal = _feeVault[debtAsset];
        if (feeBal >= absorbedWad) {
            _feeVault[debtAsset] = feeBal - absorbedWad;
        } else if (msg.sender == _admin) {
            uint256 rem = absorbedWad - feeBal;
            _feeVault[debtAsset] = 0;
            int256 remI = FullMath512.toInt256(rem);
            int256 curAdminBal = _balances[_admin][debtAsset];
            if (curAdminBal < remI) _rev(InsufficientWithdrawableBalance.selector);
            int256 nextAdminBal = curAdminBal - remI;
            _checkPostWithdrawalMargin(_admin, nAssets, debtAsset, nextAdminBal);
            _balances[_admin][debtAsset] = nextAdminBal;
        } else {
            _rev(InsufficientWithdrawableBalance.selector);
        }

        _balances[underwater][debtAsset] = 0;
        emit BadDebtAbsorbed(msg.sender, underwater, debtAsset, absorbedWad);
    }

    function sweepDustToFeeVault(uint8 assetId) external override checkUnlocked returns (uint256 dustWad) {
        uint8 nAssets = _assetCount;
        if (assetId >= nAssets) _rev(InvalidAssetConfig.selector);
        uint8 dec = _assets[assetId].decimals;
        if (dec >= 18) _rev(InsufficientWithdrawableBalance.selector);
        uint256 factor = _unitScale(dec);

        int256 prev = _balances[msg.sender][assetId];
        if (prev <= 0) _rev(InsufficientWithdrawableBalance.selector);
        dustWad = uint256(prev) % factor;
        if (dustWad == 0) _rev(InsufficientWithdrawableBalance.selector);

        int256 next = prev - int256(dustWad);
        _checkPostWithdrawalMargin(msg.sender, nAssets, assetId, next);

        _balances[msg.sender][assetId] = next;
        _feeVault[assetId] = FullMath512.checkedAddU256(_feeVault[assetId], dustWad);
        emit SubQuantumDustSwept(msg.sender, assetId, dustWad);
    }

    function sweepFeeVault(uint8 assetId, address recipient) external override nonReentrant returns (uint256 sweptWad) {
        _onlyAdmin();
        if (recipient == address(0) || assetId >= _assetCount) _rev(InvalidAssetConfig.selector);
        uint256 feeWad = _feeVault[assetId];
        if (feeWad == 0) _rev(InsufficientWithdrawableBalance.selector);

        AssetConfig memory cfg = _assets[assetId];
        if (cfg.token == address(0)) {
            _feeVault[assetId] = 0;
            _balances[recipient][assetId] = FullMath512.checkedAddI256(
                _balances[recipient][assetId],
                FullMath512.toInt256(feeWad)
            );
            emit FeeVaultSwept(recipient, assetId, feeWad, 0);
            return feeWad;
        }

        uint256 factor = _unitScale(cfg.decimals);
        uint256 rawOut = feeWad / factor;
        if (rawOut == 0 || _vaultPhysicalRaw[assetId] < rawOut) _rev(InsufficientWithdrawableBalance.selector);
        sweptWad = rawOut * factor;
        _feeVault[assetId] = feeWad - sweptWad;
        _vaultPhysicalRaw[assetId] -= rawOut;

        _safeTransfer(cfg.token, recipient, rawOut);
        emit FeeVaultSwept(recipient, assetId, sweptWad, rawOut);
    }

    function registerObligation(
        address creditor,
        uint8 assetId,
        uint256 amountWad
    ) external override checkUnlocked returns (uint256 totalConfirmedWad) {
        if (creditor == address(0) || creditor == msg.sender || assetId >= _assetCount || amountWad == 0) {
            _rev(InvalidObligation.selector);
        }
        totalConfirmedWad = FullMath512.checkedAddU256(_confirmedObligations[msg.sender][creditor][assetId], amountWad);
        _confirmedObligations[msg.sender][creditor][assetId] = totalConfirmedWad;
        emit ObligationRegistered(msg.sender, creditor, assetId, totalConfirmedWad);
    }

    function revokeObligation(
        address creditor,
        uint8 assetId,
        uint256 amountWad
    ) external override checkUnlocked returns (uint256 remainingConfirmedWad) {
        if (creditor == address(0) || creditor == msg.sender || assetId >= _assetCount || amountWad == 0) {
            _rev(InvalidObligation.selector);
        }
        uint256 avail = _confirmedObligations[msg.sender][creditor][assetId];
        if (amountWad > avail) _rev(InvalidObligation.selector);
        remainingConfirmedWad = avail - amountWad;
        _confirmedObligations[msg.sender][creditor][assetId] = remainingConfirmedWad;
        emit ObligationRevoked(msg.sender, creditor, assetId, remainingConfirmedWad);
    }

    function invalidateNonces(uint256 wordPos, uint256 mask) external override checkUnlocked returns (uint256 updatedWord) {
        if (mask == 0) _rev(InvalidIntent.selector);
        updatedWord = _nonceBitmaps[msg.sender][wordPos] | mask;
        _nonceBitmaps[msg.sender][wordPos] = updatedWord;
        emit NoncesInvalidated(msg.sender, wordPos, mask);
    }

    function _computeLiquidationBonusBps(uint16 mmBps) internal pure returns (uint16) {
        uint16 half = mmBps / 2;
        return half < LIQUIDATION_BONUS_CAP_BPS ? half : LIQUIDATION_BONUS_CAP_BPS;
    }

    function liquidate(
        address underwater,
        uint8 debtAsset,
        uint8 collateralAsset,
        uint256 repayAmountWad
    ) external override checkUnlocked returns (uint256 repaidDebtWad, uint256 seizedCollateralWad) {
        unchecked {
        if (underwater == address(0) || underwater == msg.sender) _rev(InvalidIntent.selector);
        uint8 nAssets = _assetCount;
        if (nAssets == 0 || nAssets > 16) _rev(InvalidAssetConfig.selector);
        if (
            debtAsset >= nAssets ||
            collateralAsset >= nAssets ||
            debtAsset == collateralAsset ||
            repayAmountWad < MIN_INTENT_AMOUNT_WAD
        ) {
            _rev(InvalidIntent.selector);
        }

        int256[] memory uBals = new int256[](nAssets);
        int256[] memory lBals = new int256[](nAssets);
        uint16 activeMask = uint16((uint16(1) << debtAsset) | (uint16(1) << collateralAsset));
        for (uint8 a = 0; a < nAssets; a++) {
            uBals[a] = _balances[underwater][a];
            lBals[a] = _balances[msg.sender][a];
            if (uBals[a] != 0 || lBals[a] != 0) {
                activeMask |= uint16(1) << a;
            }
        }
        _checkFreshMask(activeMask, nAssets);

        RiskMetrics memory preURisk = _evaluateRisk(uBals, nAssets);
        if (preURisk.healthWad >= 0) _rev(InvalidIntent.selector);
        if (uBals[debtAsset] >= 0 || uBals[collateralAsset] <= 0) _rev(InvalidIntent.selector);
        if (uBals[debtAsset] == type(int256).min) _rev(MathOverflow.selector);

        uint256 absDebt = uint256(-uBals[debtAsset]);
        uint256 availColl = uint256(uBals[collateralAsset]);
        uint256 cappedRepay = repayAmountWad < absDebt ? repayAmountWad : absDebt;

        uint16 bonusBps = _computeLiquidationBonusBps(_assets[debtAsset].mmBps);
        uint256 debtPrice = _assets[debtAsset].markPriceWad;
        uint256 collPrice = _assets[collateralAsset].markPriceWad;
        uint256 quoteRepayWad = FullMath512.mulDivFloor(cappedRepay, debtPrice, collPrice);
        uint256 rawSeize = FullMath512.mulDivFloor(quoteRepayWad, BPS_DENOM + bonusBps, BPS_DENOM);
        if (rawSeize > availColl) {
            seizedCollateralWad = availColl;
            uint256 maxQuoteRepay = FullMath512.mulDivFloor(availColl, BPS_DENOM, BPS_DENOM + bonusBps);
            uint256 backRepay = FullMath512.mulDivFloor(maxQuoteRepay, collPrice, debtPrice);
            repaidDebtWad = cappedRepay < backRepay ? cappedRepay : backRepay;
        } else {
            seizedCollateralWad = rawSeize;
            repaidDebtWad = cappedRepay;
        }
        if (seizedCollateralWad == 0 || repaidDebtWad < MIN_INTENT_AMOUNT_WAD) _rev(InvalidIntent.selector);

        int256 repayI = FullMath512.toInt256(repaidDebtWad);
        int256 seizeI = FullMath512.toInt256(seizedCollateralWad);
        if (lBals[debtAsset] < repayI) _rev(InsufficientWithdrawableBalance.selector);

        uBals[debtAsset] = FullMath512.checkedAddI256(uBals[debtAsset], repayI);
        uBals[collateralAsset] = FullMath512.checkedSubI256(uBals[collateralAsset], seizeI);
        lBals[debtAsset] = FullMath512.checkedSubI256(lBals[debtAsset], repayI);
        lBals[collateralAsset] = FullMath512.checkedAddI256(lBals[collateralAsset], seizeI);

        RiskMetrics memory postURisk = _evaluateRisk(uBals, nAssets);
        RiskMetrics memory postLRisk = _evaluateRisk(lBals, nAssets);
        bool collExhausted = (uBals[collateralAsset] == 0);
        bool healthOk = collExhausted
            ? (postURisk.healthWad >= preURisk.healthWad && postURisk.totalLiabilityWad < preURisk.totalLiabilityWad)
            : (postURisk.healthWad > preURisk.healthWad);
        if (!healthOk) _rev(HealthMonotonicityViolated.selector);
        if (postLRisk.imSurplusWad < 0) _rev(InsufficientInitialMargin.selector);

        _balances[underwater][debtAsset] = uBals[debtAsset];
        _balances[underwater][collateralAsset] = uBals[collateralAsset];
        _balances[msg.sender][debtAsset] = lBals[debtAsset];
        _balances[msg.sender][collateralAsset] = lBals[collateralAsset];

        emit AccountLiquidated(msg.sender, underwater, debtAsset, collateralAsset, repaidDebtWad, seizedCollateralWad);
        }
    }

    function seedAccountBalance(address trader, uint8 assetId, int256 balanceWad) external override checkUnlocked {
        if (_admin == address(0) || msg.sender != _admin || !benchmarkSeedingEnabled) _rev(UnauthorizedCaller.selector);
        if (assetId >= _assetCount || _assets[assetId].token != address(0)) _rev(InvalidAssetConfig.selector);
        _balances[trader][assetId] = balanceWad;
    }

    function _evaluateRisk(int256[] memory bals, uint8 nAssets) internal view returns (RiskMetrics memory m) {
        unchecked {
            for (uint8 a = 0; a < nAssets; ++a) {
                int256 bal = bals[a];
                if (bal == 0) continue;
                AssetConfig memory cfg = _assets[a];
                if (bal > 0) {
                    uint256 gross = FullMath512.mulDivFloor(uint256(bal), cfg.markPriceWad, WAD);
                    uint256 hc = FullMath512.mulDivFloor(gross, BPS_DENOM - cfg.haircutBps, BPS_DENOM);
                    m.grossCollateralWad = FullMath512.checkedAddU256(m.grossCollateralWad, gross);
                    m.effectiveCollateralWad = FullMath512.checkedAddU256(m.effectiveCollateralWad, hc);
                } else {
                    if (bal == type(int256).min) _rev(MathOverflow.selector);
                    uint256 liab = FullMath512.mulDivCeil(uint256(-bal), cfg.markPriceWad, WAD);
                    m.totalLiabilityWad = FullMath512.checkedAddU256(m.totalLiabilityWad, liab);
                    m.requiredImWad = FullMath512.checkedAddU256(
                        m.requiredImWad,
                        FullMath512.mulDivCeil(liab, BPS_DENOM + cfg.imBps, BPS_DENOM)
                    );
                    m.requiredMmWad = FullMath512.checkedAddU256(
                        m.requiredMmWad,
                        FullMath512.mulDivCeil(liab, BPS_DENOM + cfg.mmBps, BPS_DENOM)
                    );
                }
            }
        }
        m.netEquityWad = FullMath512.checkedSubI256(
            FullMath512.toInt256(m.grossCollateralWad),
            FullMath512.toInt256(m.totalLiabilityWad)
        );
        m.healthWad = FullMath512.checkedSubI256(
            FullMath512.toInt256(m.effectiveCollateralWad),
            FullMath512.toInt256(m.requiredMmWad)
        );
        m.imSurplusWad = FullMath512.checkedSubI256(
            FullMath512.toInt256(m.effectiveCollateralWad),
            FullMath512.toInt256(m.requiredImWad)
        );
    }

    function _consumeNonce(address acct, uint256 nonce) internal {
        uint256 wordPos = nonce >> 8;
        uint8 bitPos = uint8(nonce & 0xff);
        uint256 mask = uint256(1) << bitPos;
        uint256 word = _nonceBitmaps[acct][wordPos];
        if ((word & mask) != 0) _rev(NonceAlreadyUsed.selector);
        _nonceBitmaps[acct][wordPos] = word | mask;
    }

    function _isNonceSpent(address acct, uint256 nonce) internal view returns (bool) {
        uint256 wordPos = nonce >> 8;
        uint8 bitPos = uint8(nonce & 0xff);
        return (_nonceBitmaps[acct][wordPos] & (uint256(1) << bitPos)) != 0;
    }

    function _verifySig(bytes32 digest, address expected, uint8 v, bytes32 r, bytes32 s) internal pure {
        if (v != 27 && v != 28) _rev(InvalidSignature.selector);
        if (uint256(r) == 0 || uint256(r) >= SECP256K1_N || uint256(s) == 0 || uint256(s) > SECP256K1_HALF_N) {
            _rev(InvalidSignature.selector);
        }
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != expected) _rev(InvalidSignature.selector);
    }

    /// @dev Exact O(V^2) 2-Origin BFS cycle finder (`D-31`): prefers >=3-node multilateral cycles over 2-cycles.
    function _findCycleBfs(
        uint256 start,
        uint256 nAcc,
        uint256[] memory mat,
        uint256[] memory path
    ) internal pure returns (uint256 cLen) {
        unchecked {
            uint256 none = 0xFF;
            uint256[] memory r1 = new uint256[](nAcc);
            uint256[] memory r2 = new uint256[](nAcc);
            for (uint256 i = 0; i < nAcc; ++i) {
                r1[i] = none;
                r2[i] = none;
            }
            uint256[] memory q = new uint256[](nAcc * 2);
            uint256 qHead = 0;
            uint256 qTail = 0;

            for (uint256 f = start + 1; f < nAcc; ++f) {
                if (mat[start * nAcc + f] > 0) {
                    r1[f] = f;
                    q[qTail++] = f | (f << 8) | (none << 16);
                }
            }

            while (qHead < qTail) {
                uint256 curQi = qHead++;
                uint256 entry = q[curQi];
                uint256 u = entry & 0xFF;
                uint256 orig = (entry >> 8) & 0xFF;

                if (orig != u && mat[u * nAcc + start] > 0) {
                    uint256[] memory rev = new uint256[](nAcc);
                    uint256 rlen = 0;
                    uint256 qi = curQi;
                    while (qi != none) {
                        uint256 e = q[qi];
                        rev[rlen++] = e & 0xFF;
                        qi = (e >> 16) & 0xFF;
                    }
                    path[0] = start;
                    for (uint256 i = 0; i < rlen; ++i) {
                        path[1 + i] = rev[rlen - 1 - i];
                    }
                    return 1 + rlen;
                }
                for (uint256 nxt = start + 1; nxt < nAcc; ++nxt) {
                    if (mat[u * nAcc + nxt] > 0) {
                        if (r1[nxt] == none) {
                            r1[nxt] = orig;
                            q[qTail++] = nxt | (orig << 8) | (curQi << 16);
                        } else if (r1[nxt] != orig && r2[nxt] == none) {
                            r2[nxt] = orig;
                            q[qTail++] = nxt | (orig << 8) | (curQi << 16);
                        }
                    }
                }
            }

            for (uint256 f = start + 1; f < nAcc; ++f) {
                if (mat[start * nAcc + f] > 0 && mat[f * nAcc + start] > 0) {
                    path[0] = start;
                    path[1] = f;
                    return 2;
                }
            }
            return 0;
        }
    }

    function _buildAddressRanks(
        address[] calldata participants
    ) internal pure returns (uint256[] memory rankToOrig, uint256[] memory origToRank) {
        unchecked {
            uint256 nAcc = participants.length;
            rankToOrig = new uint256[](nAcc);
            origToRank = new uint256[](nAcc);
            for (uint256 i = 0; i < nAcc; ++i) rankToOrig[i] = i;
            for (uint256 i = 1; i < nAcc; ++i) {
                uint256 key = rankToOrig[i];
                uint160 keyVal = uint160(participants[key]);
                uint256 j = i;
                while (j > 0 && uint160(participants[rankToOrig[j - 1]]) > keyVal) {
                    rankToOrig[j] = rankToOrig[j - 1];
                    --j;
                }
                rankToOrig[j] = key;
            }
            for (uint256 r = 0; r < nAcc; ++r) origToRank[rankToOrig[r]] = r;
        }
    }

    function settleBatch(
        address[] calldata participants,
        ObligationInput[] calldata obligations,
        SignedTradeIntent[] calldata intents
    ) external override checkUnlocked returns (uint32 cyclesEliminated, uint256 totalMatchedVolumeWad) {
        unchecked {
        if (!permissionlessSolver && !approvedSolvers[msg.sender]) _rev(UnauthorizedCaller.selector);

        uint8 nAssets = _assetCount;
        uint256 nAcc = participants.length;
        if (
            nAssets == 0 ||
            nAssets > 16 ||
            nAcc == 0 ||
            nAcc > 64 ||
            obligations.length > 128 ||
            intents.length > 128
        ) _rev(BatchCapacityExceeded.selector);

        for (uint256 u = 0; u < nAcc; u++) {
            if (participants[u] == address(0)) _rev(InvalidAssetConfig.selector);
            for (uint256 v = u + 1; v < nAcc; v++) {
                if (participants[u] == participants[v]) _rev(DuplicateParticipant.selector);
            }
        }

        int256[][] memory preBals = new int256[][](nAcc);
        int256[][] memory workBals = new int256[][](nAcc);
        RiskMetrics[] memory preRisks = new RiskMetrics[](nAcc);
        bool[] memory touched = new bool[](nAcc);
        bool[] memory riskActive = new bool[](nAcc);
        uint16 activeMask = 0;

        for (uint256 u = 0; u < nAcc; u++) {
            preBals[u] = new int256[](nAssets);
            workBals[u] = new int256[](nAssets);
            for (uint8 a = 0; a < nAssets; a++) {
                int256 b = _balances[participants[u]][a];
                if (b != 0) activeMask |= uint16(1) << a;
                preBals[u][a] = b;
                workBals[u][a] = b;
            }
            preRisks[u] = _evaluateRisk(preBals[u], nAssets);
        }

        for (uint256 i = 0; i < obligations.length; i++) {
            if (obligations[i].assetId < nAssets) {
                activeMask |= uint16(1) << obligations[i].assetId;
            }
        }
        for (uint256 i = 0; i < intents.length; i++) {
            if (intents[i].baseAsset < nAssets) activeMask |= uint16(1) << intents[i].baseAsset;
            if (intents[i].quoteAsset < nAssets) activeMask |= uint16(1) << intents[i].quoteAsset;
        }
        if (activeMask == 0) activeMask = 1;
        _checkFreshMask(activeMask, nAssets);

        bytes32 domSep = domainSeparator();
        uint64 epoch = _currentEpoch;

        // Stage 1A: Authenticate Every Bilateral Obligation
        for (uint256 i = 0; i < obligations.length; i++) {
            ObligationInput calldata ob = obligations[i];
            if (ob.debtor >= nAcc || ob.creditor >= nAcc || ob.debtor == ob.creditor || ob.assetId >= nAssets || ob.amountWad == 0) {
                _rev(InvalidObligation.selector);
            }
            address dAddr = participants[ob.debtor];
            address cAddr = participants[ob.creditor];

            if (ob.authMode == 0) {
                uint256 avail = _confirmedObligations[dAddr][cAddr][ob.assetId];
                if (ob.amountWad > avail) _rev(UnauthorizedObligation.selector);
                _confirmedObligations[dAddr][cAddr][ob.assetId] = avail - ob.amountWad;
            } else if (ob.authMode == 1) {
                if (epoch > ob.maxEpoch) _rev(ExpiredIntent.selector);
                _consumeNonce(dAddr, ob.nonce);
                if (msg.sender != dAddr) _rev(UnauthorizedObligation.selector);
            } else if (ob.authMode == 2) {
                if (epoch > ob.maxEpoch) _rev(ExpiredIntent.selector);
                _consumeNonce(dAddr, ob.nonce);
                bytes32 structHash = keccak256(
                    abi.encode(
                        OBLIGATION_ATTESTATION_TYPEHASH,
                        dAddr,
                        cAddr,
                        ob.assetId,
                        ob.amountWad,
                        ob.maxEpoch,
                        ob.nonce
                    )
                );
                _verifySig(_eip712Digest(domSep, structHash), dAddr, ob.v, ob.r, ob.s);
            } else {
                _rev(InvalidObligation.selector);
            }
            touched[ob.debtor] = true;
            touched[ob.creditor] = true;
        }

        // Stage 1B: Participant-Order-Invariant Multilateral Cycle Compression per active asset
        if (obligations.length > 0) {
            (uint256[] memory rankToOrig, uint256[] memory origToRank) = _buildAddressRanks(participants);
            for (uint8 a = 0; a < nAssets; a++) {
                bool hasEdge = false;
                for (uint256 i = 0; i < obligations.length; i++) {
                    if (obligations[i].assetId == a) {
                        hasEdge = true;
                        break;
                    }
                }
                if (!hasEdge) continue;

                uint256[] memory mat = new uint256[](nAcc * nAcc);
                for (uint256 i = 0; i < obligations.length; i++) {
                    if (obligations[i].assetId != a) continue;
                    uint256 ru = origToRank[obligations[i].debtor];
                    uint256 rv = origToRank[obligations[i].creditor];
                    uint256 idx = ru * nAcc + rv;
                    mat[idx] = FullMath512.checkedAddU256(mat[idx], obligations[i].amountWad);
                }
                for (uint256 s = 0; s < nAcc; s++) {
                    while (true) {
                        uint256[] memory path = new uint256[](nAcc);
                        uint256 cLen = _findCycleBfs(s, nAcc, mat, path);
                        if (cLen == 0) break;

                        uint256 bottleneck = type(uint256).max;
                        for (uint256 k = 0; k < cLen; k++) {
                            uint256 w = mat[path[k] * nAcc + path[(k + 1) % cLen]];
                            if (w < bottleneck) bottleneck = w;
                        }
                        for (uint256 k = 0; k < cLen; k++) {
                            mat[path[k] * nAcc + path[(k + 1) % cLen]] -= bottleneck;
                        }
                        if (cyclesEliminated == type(uint32).max) _rev(MathOverflow.selector);
                        cyclesEliminated += 1;
                    }
                }
                for (uint256 ru = 0; ru < nAcc; ru++) {
                    uint256 uOrig = rankToOrig[ru];
                    for (uint256 rv = 0; rv < nAcc; rv++) {
                        uint256 rem = mat[ru * nAcc + rv];
                        if (rem > 0) {
                            uint256 vOrig = rankToOrig[rv];
                            int256 remI = FullMath512.toInt256(rem);
                            workBals[uOrig][a] = FullMath512.checkedSubI256(workBals[uOrig][a], remI);
                            workBals[vOrig][a] = FullMath512.checkedAddI256(workBals[vOrig][a], remI);
                            riskActive[uOrig] = true;
                        }
                    }
                }
            }
        }

        // Stage 2: Authenticate Trade Intents & Adjust Remaining Partial Fill (`D-18`)
        WorkIntent[] memory workIts = _authenticateIntents(participants, intents, nAcc, nAssets, epoch, domSep);

        // Stage 3: UCPBA across active canonical pairs (`quoteAsset < baseAsset`)
        uint256[] memory feeDeltas = new uint256[](nAssets);
        for (uint8 bAsset = 1; bAsset < nAssets; bAsset++) {
            for (uint8 qAsset = 0; qAsset < bAsset; qAsset++) {
                (uint256 clearP, uint256 vol, uint256 dust) = _clearPair(
                    bAsset,
                    qAsset,
                    participants,
                    workIts,
                    workBals,
                    touched,
                    riskActive
                );
                if (vol > 0) {
                    totalMatchedVolumeWad = FullMath512.checkedAddU256(totalMatchedVolumeWad, vol);
                    feeDeltas[qAsset] = FullMath512.checkedAddU256(feeDeltas[qAsset], dust);
                    emit MarketCleared(epoch, bAsset, qAsset, clearP, vol, dust);
                }
            }
        }

        // Stage 4: Invariant Gate (Asset Conservation + Margin, Net Equity Solvency & Health Monotonicity)
        for (uint8 a = 0; a < nAssets; a++) {
            int256 preSum = 0;
            int256 postSum = FullMath512.toInt256(feeDeltas[a]);
            for (uint256 u = 0; u < nAcc; u++) {
                preSum = FullMath512.checkedAddI256(preSum, preBals[u][a]);
                postSum = FullMath512.checkedAddI256(postSum, workBals[u][a]);
            }
            if (preSum != postSum) _rev(AssetConservationViolated.selector);
        }

        if (obligations.length == 0 && totalMatchedVolumeWad == 0) {
            _rev(InvalidIntent.selector);
        }

        for (uint8 a = 0; a < nAssets; a++) {
            if (feeDeltas[a] > 0) {
                _feeVault[a] = FullMath512.checkedAddU256(_feeVault[a], feeDeltas[a]);
            }
        }

        for (uint256 u = 0; u < nAcc; u++) {
            if (touched[u]) {
                RiskMetrics memory postRisk = _evaluateRisk(workBals[u], nAssets);
                bool reqFullIm = riskActive[u] &&
                    (preRisks[u].imSurplusWad >= 0 ||
                        postRisk.requiredImWad > preRisks[u].requiredImWad ||
                        postRisk.totalLiabilityWad > preRisks[u].totalLiabilityWad);
                if (reqFullIm && postRisk.imSurplusWad < 0) {
                    _rev(InsufficientInitialMargin.selector);
                }
                if (
                    (preRisks[u].imSurplusWad < 0 || postRisk.imSurplusWad < 0) &&
                    postRisk.netEquityWad < preRisks[u].netEquityWad
                ) {
                    _rev(HealthMonotonicityViolated.selector);
                }
                if (
                    postRisk.imSurplusWad < 0 &&
                    (postRisk.imSurplusWad < preRisks[u].imSurplusWad || postRisk.healthWad < preRisks[u].healthWad)
                ) {
                    _rev(HealthMonotonicityViolated.selector);
                }
            }
            for (uint8 a = 0; a < nAssets; a++) {
                if (workBals[u][a] != preBals[u][a]) {
                    _balances[participants[u]][a] = workBals[u][a];
                }
            }
        }

        if (epoch == type(uint64).max) _rev(MathOverflow.selector);
        _currentEpoch = epoch + 1;
        emit BatchTelemetry(epoch, 0, 0);
        emit BatchSettled(epoch, cyclesEliminated, totalMatchedVolumeWad);
        }
    }

    function _authenticateIntents(
        address[] calldata participants,
        SignedTradeIntent[] calldata intents,
        uint256 nAcc,
        uint8 nAssets,
        uint64 epoch,
        bytes32 domSep
    ) internal view returns (WorkIntent[] memory workIts) {
        unchecked {
        workIts = new WorkIntent[](intents.length);
        uint8[] memory traderPairSides = new uint8[](nAcc * 256);
        for (uint256 i = 0; i < intents.length; i++) {
            SignedTradeIntent calldata it = intents[i];
            if (it.side > 1 || it.authMode > 1) _rev(InvalidIntent.selector);
            if (it.trader >= nAcc || it.quoteAsset >= it.baseAsset || it.baseAsset >= nAssets) {
                _rev(InvalidIntent.selector);
            }
            if (it.amountWad < MIN_INTENT_AMOUNT_WAD || it.limitPriceWad == 0) {
                _rev(InvalidIntent.selector);
            }

            uint8 sideMask = uint8(1 << it.side);
            uint256 mKey = (uint256(it.trader) << 8) | (uint256(it.baseAsset) << 4) | it.quoteAsset;
            if ((traderPairSides[mKey] & (uint8(3) ^ sideMask)) != 0) _rev(InvalidIntent.selector);
            traderPairSides[mKey] |= sideMask;

            if (epoch > it.maxEpoch) _rev(ExpiredIntent.selector);

            address traderAddr = participants[it.trader];
            if (_isNonceSpent(traderAddr, it.nonce)) _rev(NonceAlreadyUsed.selector);
            for (uint256 prev = 0; prev < i; prev++) {
                if (intents[prev].trader == it.trader && intents[prev].nonce == it.nonce) {
                    _rev(NonceAlreadyUsed.selector);
                }
            }

            uint256 remAmt = it.amountWad;
            uint256 priorFill = 0;
            if (it.authMode == 1) {
                priorFill = _partialFills[traderAddr][it.nonce];
                if (priorFill > 0) {
                    if (priorFill >= it.amountWad) _rev(NonceAlreadyUsed.selector);
                    remAmt = it.amountWad - priorFill;
                    if (remAmt < MIN_INTENT_AMOUNT_WAD) _rev(InvalidIntent.selector);
                }
            }

            if (it.authMode == 0) {
                if (msg.sender != traderAddr) _rev(UnauthorizedCaller.selector);
            } else {
                bytes32 structHash = keccak256(
                    abi.encode(
                        TRADE_INTENT_TYPEHASH,
                        traderAddr,
                        it.baseAsset,
                        it.quoteAsset,
                        it.side,
                        it.amountWad,
                        it.limitPriceWad,
                        it.maxEpoch,
                        it.nonce
                    )
                );
                _verifySig(_eip712Digest(domSep, structHash), traderAddr, it.v, it.r, it.s);
            }

            workIts[i] = WorkIntent({
                trader: it.trader,
                baseAsset: it.baseAsset,
                quoteAsset: it.quoteAsset,
                side: it.side,
                authMode: it.authMode,
                amountWad: remAmt,
                signedAmountWad: it.amountWad,
                priorFilledWad: priorFill,
                limitPriceWad: it.limitPriceWad,
                nonce: it.nonce
            });
        }
        }
    }

    function _quantizeRefTick(uint256 refPrice) internal pure returns (uint256) {
        unchecked {
            if (refPrice >= 10_000_000_000_000) return (refPrice / MIN_INTENT_AMOUNT_WAD) * MIN_INTENT_AMOUNT_WAD;
            if (refPrice >= 10_000_000_000) return (refPrice / 1_000_000) * 1_000_000;
            if (refPrice >= 10_000_000) return (refPrice / 1_000) * 1_000;
            return refPrice;
        }
    }

    function _isIrEligible(
        WorkIntent memory it,
        uint256 p,
        uint256 step,
        uint256 lotBuyQuote,
        uint256 lotSellQuote
    ) internal pure returns (bool) {
        if (it.side == 0) {
            return it.limitPriceWad >= p && !FullMath512.gtMul512(lotBuyQuote, WAD, step, it.limitPriceWad);
        }
        return lotSellQuote > 0 && it.limitPriceWad <= p && !FullMath512.gtMul512(step, it.limitPriceWad, lotSellQuote, WAD);
    }

    function _buildSortedUniqueCandidates(
        uint8 bAsset,
        uint8 qAsset,
        uint256 refTick,
        uint256 bandLow,
        uint256 bandHigh,
        WorkIntent[] memory intents
    ) internal pure returns (uint256[] memory cands, uint256 candLen) {
        unchecked {
            uint256 n = intents.length;
            uint256[] memory raw = new uint256[](n * 2 + 3);
            uint256 m = 0;
            for (uint256 i = 0; i < n; ++i) {
                if (intents[i].baseAsset == bAsset && intents[i].quoteAsset == qAsset && intents[i].limitPriceWad > 0) {
                    uint256 lp = intents[i].limitPriceWad;
                    raw[m++] = lp;
                    uint256 tickLp = (lp / MIN_INTENT_AMOUNT_WAD) * MIN_INTENT_AMOUNT_WAD;
                    if (tickLp > 0) raw[m++] = tickLp;
                }
            }
            if (refTick > 0) raw[m++] = refTick;
            if (bandLow > 0) raw[m++] = bandLow;
            if (bandHigh > 0) raw[m++] = bandHigh;

            for (uint256 i = 1; i < m; ++i) {
                uint256 key = raw[i];
                uint256 j = i;
                while (j > 0 && raw[j - 1] > key) {
                    raw[j] = raw[j - 1];
                    --j;
                }
                raw[j] = key;
            }
            cands = new uint256[](m);
            for (uint256 i = 0; i < m; ++i) {
                if (candLen == 0 || raw[i] != cands[candLen - 1]) {
                    cands[candLen++] = raw[i];
                }
            }
        }
    }

    function _clearPair(
        uint8 bAsset,
        uint8 qAsset,
        address[] calldata participants,
        WorkIntent[] memory intents,
        int256[][] memory workBals,
        bool[] memory touched,
        bool[] memory riskActive
    ) internal returns (uint256 bestPrice, uint256 bestVol, uint256 dust) {
        unchecked {
            uint256 n = intents.length;
            bool hasIntent = false;
            for (uint256 i = 0; i < n; ++i) {
                if (intents[i].baseAsset == bAsset && intents[i].quoteAsset == qAsset) {
                    hasIntent = true;
                    break;
                }
            }
            if (!hasIntent) return (0, 0, 0);

            uint256 refPrice = FullMath512.mulDivFloor(_assets[bAsset].markPriceWad, WAD, _assets[qAsset].markPriceWad);
            if (refPrice == 0) _rev(InvalidAssetConfig.selector);
            uint256 refTick = _quantizeRefTick(refPrice);

            uint256 dev = maxPriceDeviationBps;
            uint256 bandLow = dev >= BPS_DENOM
                ? 1
                : FullMath512.mulDivCeil(refPrice, BPS_DENOM - dev, BPS_DENOM);
            if (bandLow == 0) bandLow = 1;
            uint256 bandHigh = FullMath512.mulDivFloor(refPrice, BPS_DENOM + dev, BPS_DENOM);

            (uint256[] memory cands, uint256 candLen) = _buildSortedUniqueCandidates(
                bAsset, qAsset, refTick, bandLow, bandHigh, intents
            );

            bestPrice = refTick;
            uint256 bestImb = type(uint256).max;
            uint256 bestRefDist = type(uint256).max;
            bool outOfBandCrossed = false;
            uint256 step = MIN_INTENT_AMOUNT_WAD;

            for (uint256 c = 0; c < candLen; ++c) {
                uint256 p = cands[c];
                if (p == 0) continue;
                uint256 lotBuyQ = FullMath512.mulDivCeil(step, p, WAD);
                uint256 lotSellQ = FullMath512.mulDivFloor(step, p, WAD);
                uint256 demand = 0;
                uint256 supply = 0;
                for (uint256 i = 0; i < n; ++i) {
                    if (intents[i].baseAsset != bAsset || intents[i].quoteAsset != qAsset) continue;
                    if (!_isIrEligible(intents[i], p, step, lotBuyQ, lotSellQ)) continue;
                    uint256 qAmt = (intents[i].amountWad / step) * step;
                    if (intents[i].side == 0) {
                        demand = FullMath512.checkedAddU256(demand, qAmt);
                    } else {
                        supply = FullMath512.checkedAddU256(supply, qAmt);
                    }
                }
                uint256 matched = demand < supply ? demand : supply;
                if (matched == 0) continue;

                uint256 priceDiff = p >= refPrice ? p - refPrice : refPrice - p;
                if (FullMath512.gtMul512(priceDiff, BPS_DENOM, refPrice, dev)) {
                    outOfBandCrossed = true;
                    continue;
                }

                uint256 imb = demand >= supply ? demand - supply : supply - demand;
                if (
                    matched > bestVol ||
                    (matched == bestVol && imb < bestImb) ||
                    (matched == bestVol && imb == bestImb && priceDiff < bestRefDist) ||
                    (matched == bestVol && imb == bestImb && priceDiff == bestRefDist && p < bestPrice)
                ) {
                    bestVol = matched;
                    bestImb = imb;
                    bestRefDist = priceDiff;
                    bestPrice = p;
                }
            }

            if (bestVol == 0) {
                if (outOfBandCrossed) _rev(LimitPriceViolated.selector);
                return (bestPrice, 0, 0);
            }

            uint256[2] memory qTotals;
            for (uint8 side = 0; side < 2; ++side) {
                qTotals[side] = _applySideFills(side, bAsset, qAsset, bestPrice, bestVol, step, participants, intents, workBals, touched, riskActive);
            }
            dust = FullMath512.checkedSubU256(qTotals[0], qTotals[1]);
        }
    }

    function _isBetterTiePriority(
        uint8 side,
        uint256 i,
        uint256 bestIdx,
        address[] calldata participants,
        WorkIntent[] memory intents
    ) internal pure returns (bool) {
        uint256 pi = intents[i].limitPriceWad;
        uint256 pb = intents[bestIdx].limitPriceWad;
        if (pi != pb) return side == 0 ? (pi > pb) : (pi < pb);
        uint160 ai = uint160(participants[intents[i].trader]);
        uint160 ab = uint160(participants[intents[bestIdx].trader]);
        if (ai != ab) return ai < ab;
        return intents[i].nonce < intents[bestIdx].nonce;
    }

    function _applySideFills(
        uint8 side,
        uint8 bAsset,
        uint8 qAsset,
        uint256 clearPrice,
        uint256 targetVol,
        uint256 step,
        address[] calldata participants,
        WorkIntent[] memory intents,
        int256[][] memory workBals,
        bool[] memory touched,
        bool[] memory riskActive
    ) internal returns (uint256 quoteTotal) {
        unchecked {
            uint256 n = intents.length;
            uint256[] memory caps = new uint256[](n);
            uint256[] memory fills = new uint256[](n);
            bool[] memory elig = new bool[](n);
            uint256 totalOffered = 0;

            uint256 lotBuyQ = FullMath512.mulDivCeil(step, clearPrice, WAD);
            uint256 lotSellQ = FullMath512.mulDivFloor(step, clearPrice, WAD);

            for (uint256 i = 0; i < n; ++i) {
                if (intents[i].baseAsset != bAsset || intents[i].quoteAsset != qAsset || intents[i].side != side) continue;
                if (!_isIrEligible(intents[i], clearPrice, step, lotBuyQ, lotSellQ)) continue;
                elig[i] = true;
                caps[i] = (intents[i].amountWad / step) * step;
                totalOffered = FullMath512.checkedAddU256(totalOffered, caps[i]);
            }

            uint256 targetUnits = targetVol / step;
            uint256 allocUnits = 0;
            for (uint256 i = 0; i < n; ++i) {
                if (!elig[i]) continue;
                if (totalOffered <= targetVol) {
                    fills[i] = caps[i];
                    allocUnits += caps[i] / step;
                } else {
                    uint256 pUnits = FullMath512.mulDivFloor(caps[i], targetUnits, totalOffered);
                    fills[i] = pUnits * step;
                    allocUnits += pUnits;
                }
            }

            uint256 remUnits = targetUnits - allocUnits;
            bool[] memory used = new bool[](n);
            while (remUnits > 0) {
                uint256 bestIdx = type(uint256).max;
                for (uint256 i = 0; i < n; ++i) {
                    if (!elig[i] || used[i] || fills[i] >= caps[i]) continue;
                    if (bestIdx == type(uint256).max || _isBetterTiePriority(side, i, bestIdx, participants, intents)) {
                        bestIdx = i;
                    }
                }
                if (bestIdx == type(uint256).max) break;
                used[bestIdx] = true;
                uint256 availUnits = (caps[bestIdx] - fills[bestIdx]) / step;
                uint256 takeUnits = availUnits < remUnits ? availUnits : remUnits;
                fills[bestIdx] += takeUnits * step;
                remUnits -= takeUnits;
            }

            for (uint256 i = 0; i < n; ++i) {
                uint256 f = fills[i];
                if (f == 0) continue;
                WorkIntent memory it = intents[i];
                address trAddr = participants[it.trader];

                uint256 cum = FullMath512.checkedAddU256(it.priorFilledWad, f);
                if (it.authMode == 0 || cum >= it.signedAmountWad || (it.signedAmountWad - cum) < MIN_INTENT_AMOUNT_WAD) {
                    _consumeNonce(trAddr, it.nonce);
                    if (it.priorFilledWad > 0) _partialFills[trAddr][it.nonce] = 0;
                } else {
                    _partialFills[trAddr][it.nonce] = cum;
                }

                int256 fI = FullMath512.toInt256(f);
                if (side == 0) {
                    uint256 qIn = FullMath512.mulDivCeil(f, clearPrice, WAD);
                    if (clearPrice > it.limitPriceWad || FullMath512.gtMul512(qIn, WAD, f, it.limitPriceWad)) {
                        _rev(LimitPriceViolated.selector);
                    }
                    workBals[it.trader][bAsset] = FullMath512.checkedAddI256(workBals[it.trader][bAsset], fI);
                    workBals[it.trader][qAsset] = FullMath512.checkedSubI256(workBals[it.trader][qAsset], FullMath512.toInt256(qIn));
                    quoteTotal = FullMath512.checkedAddU256(quoteTotal, qIn);
                } else {
                    uint256 qOut = FullMath512.mulDivFloor(f, clearPrice, WAD);
                    if (qOut == 0 || clearPrice < it.limitPriceWad || FullMath512.gtMul512(f, it.limitPriceWad, qOut, WAD)) {
                        _rev(LimitPriceViolated.selector);
                    }
                    workBals[it.trader][bAsset] = FullMath512.checkedSubI256(workBals[it.trader][bAsset], fI);
                    workBals[it.trader][qAsset] = FullMath512.checkedAddI256(workBals[it.trader][qAsset], FullMath512.toInt256(qOut));
                    quoteTotal = FullMath512.checkedAddU256(quoteTotal, qOut);
                }
                touched[it.trader] = true;
                riskActive[it.trader] = true;
            }
        }
    }
}
