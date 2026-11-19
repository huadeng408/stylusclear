"""StylusClear v0.7.0 bit-exact Python reference clearing & liquidation verifier.

Maintains 100% arithmetic, error-priority, cycle-compression, 512-bit UCPBA IR,
and floor-capped underwater liquidation parity with:
  - crates/clearing-core (Rust no_std domain kernel)
  - crates/clearing-stylus (Arbitrum Stylus WASM 1.0 MVP contract)
  - contracts/src/SolidityClearingBenchmark.sol (Solidity via_ir benchmark)
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

from tools.ref_sim.crypto_eip712 import (
    compute_domain_separator,
    compute_intent_digest,
    compute_obligation_digest,
    ecrecover,
)

def recover_eip712_signer(digest: bytes, v: int, r_hex: str | int, s_hex: str | int) -> str | None:
    if isinstance(r_hex, int):
        rb = r_hex.to_bytes(32, "big")
    else:
        rb = int(str(r_hex), 16).to_bytes(32, "big")
    if isinstance(s_hex, int):
        sb = s_hex.to_bytes(32, "big")
    else:
        sb = int(str(s_hex), 16).to_bytes(32, "big")
    return ecrecover(digest, v, rb, sb)


WAD: int = 10**18
BPS_DENOM: int = 10_000
MIN_INTENT_AMOUNT_WAD: int = 10**9
MAX_ASSETS: int = 16
MAX_ACCOUNTS: int = 64
MAX_OBLIGATIONS: int = 128
MAX_INTENTS: int = 128
LIQUIDATION_BONUS_CAP_BPS: int = 250
U64_MAX: int = (1 << 64) - 1
U256_MAX: int = (1 << 256) - 1
I256_MIN: int = -(1 << 255)
I256_MAX: int = (1 << 255) - 1


class ClearingEngineError(Exception):
    """Fail-closed domain exception carrying one of the 19 canonical error names."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


def _check_u256(val: int) -> int:
    if val < 0 or val > U256_MAX:
        raise ClearingEngineError("MathOverflow", f"U256 out of bounds: {val}")
    return val


def _check_i256(val: int) -> int:
    if val < I256_MIN or val > I256_MAX:
        raise ClearingEngineError("MathOverflow", f"I256 out of bounds: {val}")
    return val


def mul_div_floor(a: int, b: int, denom: int) -> int:
    if denom <= 0:
        raise ClearingEngineError("DivisionByZero")
    _check_u256(a)
    _check_u256(b)
    return _check_u256((a * b) // denom)


def mul_div_ceil(a: int, b: int, denom: int) -> int:
    if denom <= 0:
        raise ClearingEngineError("DivisionByZero")
    _check_u256(a)
    _check_u256(b)
    prod = a * b
    if prod == 0:
        return 0
    return _check_u256((prod + denom - 1) // denom)


def mul_wad_floor(a: int, b: int) -> int:
    return mul_div_floor(a, b, WAD)


def mul_wad_ceil(a: int, b: int) -> int:
    return mul_div_ceil(a, b, WAD)


def quantize_down(amount: int, step: int) -> int:
    if step <= 0:
        raise ClearingEngineError("DivisionByZero")
    return (amount // step) * step


def quantize_reference_tick(ref_price: int) -> int:
    tiers = (
        (10_000_000_000_000, MIN_INTENT_AMOUNT_WAD),
        (10_000_000_000, 1_000_000),
        (10_000_000, 1_000),
    )
    for threshold, quantum in tiers:
        if ref_price >= threshold:
            return (ref_price // quantum) * quantum
    return ref_price


def compute_liquidation_bonus_bps(mm_bps: int) -> int:
    return min(mm_bps // 2, LIQUIDATION_BONUS_CAP_BPS)


@dataclass(frozen=True)
class AssetRiskConfig:
    asset_id: int
    decimals: int
    mark_price_wad: int
    price_updated_at: int
    haircut_bps: int
    im_bps: int
    mm_bps: int


@dataclass(frozen=True)
class AccountRiskMetrics:
    gross_collateral_wad: int = 0
    effective_collateral_wad: int = 0
    total_liability_wad: int = 0
    required_im_wad: int = 0
    required_mm_wad: int = 0
    net_equity_wad: int = 0
    health_wad: int = 0
    im_surplus_wad: int = 0


@dataclass(frozen=True)
class ObligationEdge:
    debtor: int
    creditor: int
    asset_id: int
    amount_wad: int


@dataclass(frozen=True)
class CycleCompressionOutcome:
    cycles_eliminated: int
    compressed_volume_by_asset: List[int]
    residual_obligations: List[ObligationEdge]


@dataclass(frozen=True)
class MarketAuctionReport:
    base_asset: int
    quote_asset: int
    clearing_price_wad: int
    matched_volume_wad: int
    rounding_dust_quote_wad: int


@dataclass(frozen=True)
class IntentFill:
    intent_index: int
    filled_base_wad: int
    quote_transfer_wad: int


@dataclass(frozen=True)
class LiquidationOutcome:
    repaid_debt_wad: int
    seized_collateral_wad: int
    post_underwater_balances: List[int]
    post_liquidator_balances: List[int]


def _norm_addr(addr: str) -> str:
    s = addr.strip().lower()
    if s.startswith("0x"):
        s = s[2:]
    if len(s) != 40:
        raise ClearingEngineError("InvalidAssetConfig", f"bad address {addr}")
    int(s, 16)
    return "0x" + s


def _addr_bytes(addr: str) -> bytes:
    return bytes.fromhex(_norm_addr(addr)[2:])


def validate_asset_configs_selective(
    assets: Sequence[AssetRiskConfig],
    active_mask: int,
    block_timestamp: int,
    max_price_staleness: int,
) -> None:
    if block_timestamp < 0 or block_timestamp > U64_MAX or max_price_staleness < 0 or max_price_staleness > U64_MAX:
        raise ClearingEngineError("InvalidAssetConfig", "u64 timestamp bounds")
    for idx, cfg in enumerate(assets):
        if (
            cfg.asset_id != idx
            or cfg.mark_price_wad <= 0
            or cfg.mark_price_wad > U256_MAX
            or cfg.decimals < 0
            or cfg.decimals > 18
            or cfg.price_updated_at < 0
            or cfg.price_updated_at > U64_MAX
        ):
            raise ClearingEngineError("InvalidAssetConfig")
        if cfg.haircut_bps < 0 or cfg.haircut_bps >= BPS_DENOM:
            raise ClearingEngineError("InvalidHaircut")
        if cfg.mm_bps <= 0 or cfg.mm_bps > cfg.im_bps or cfg.im_bps > BPS_DENOM:
            raise ClearingEngineError("InvalidAssetConfig")
        if (active_mask & (1 << idx)) != 0:
            if block_timestamp < cfg.price_updated_at or (block_timestamp - cfg.price_updated_at) > max_price_staleness:
                raise ClearingEngineError("StaleMarkPrice")


def validate_asset_configs(
    assets: Sequence[AssetRiskConfig],
    block_timestamp: int,
    max_price_staleness: int,
) -> None:
    validate_asset_configs_selective(assets, (1 << len(assets)) - 1, block_timestamp, max_price_staleness)


def evaluate_account_risk(
    balances: Sequence[int],
    assets: Sequence[AssetRiskConfig],
) -> AccountRiskMetrics:
    if len(balances) != len(assets):
        raise ClearingEngineError("InvalidAssetConfig")
    gross = 0
    eff = 0
    liab = 0
    req_im = 0
    req_mm = 0
    for bal, cfg in zip(balances, assets):
        _check_i256(bal)
        if bal > 0:
            val = mul_wad_floor(bal, cfg.mark_price_wad)
            scaled = mul_div_floor(val, BPS_DENOM - cfg.haircut_bps, BPS_DENOM)
            gross = _check_u256(gross + val)
            eff = _check_u256(eff + scaled)
        elif bal < 0:
            mag = -bal
            val = mul_wad_ceil(mag, cfg.mark_price_wad)
            liab = _check_u256(liab + val)
            req_im = _check_u256(req_im + mul_div_ceil(val, BPS_DENOM + cfg.im_bps, BPS_DENOM))
            req_mm = _check_u256(req_mm + mul_div_ceil(val, BPS_DENOM + cfg.mm_bps, BPS_DENOM))
    if gross > I256_MAX or eff > I256_MAX or liab > I256_MAX or req_im > I256_MAX or req_mm > I256_MAX:
        raise ClearingEngineError("MathOverflow")
    return AccountRiskMetrics(
        gross_collateral_wad=gross,
        effective_collateral_wad=eff,
        total_liability_wad=liab,
        required_im_wad=req_im,
        required_mm_wad=req_mm,
        net_equity_wad=_check_i256(gross - liab),
        health_wad=_check_i256(eff - req_mm),
        im_surplus_wad=_check_i256(eff - req_im),
    )


def _find_canonical_cycle_bfs(start: int, num_accounts: int, mat: List[int]) -> List[int]:
    """Exact O(V^2) 2-Origin BFS cycle finder matching crates/clearing-core/src/netting.rs (D-31)."""
    r1 = [-1] * num_accounts
    r2 = [-1] * num_accounts
    q_node: List[int] = []
    q_orig: List[int] = []
    q_par: List[int] = []

    for f in range(start + 1, num_accounts):
        if mat[start * num_accounts + f] > 0:
            r1[f] = f
            q_node.append(f)
            q_orig.append(f)
            q_par.append(-1)

    q_head = 0
    while q_head < len(q_node):
        cur_qi = q_head
        u = q_node[cur_qi]
        orig = q_orig[cur_qi]
        q_head += 1

        if orig != u and mat[u * num_accounts + start] > 0:
            rev: List[int] = []
            qi = cur_qi
            while qi != -1:
                rev.append(q_node[qi])
                qi = q_par[qi]
            rev.reverse()
            return [start] + rev

        for nxt in range(start + 1, num_accounts):
            if mat[u * num_accounts + nxt] > 0:
                if r1[nxt] == -1:
                    r1[nxt] = orig
                    q_node.append(nxt)
                    q_orig.append(orig)
                    q_par.append(cur_qi)
                elif r1[nxt] != orig and r2[nxt] == -1:
                    r2[nxt] = orig
                    q_node.append(nxt)
                    q_orig.append(orig)
                    q_par.append(cur_qi)

    for f in range(start + 1, num_accounts):
        if mat[start * num_accounts + f] > 0 and mat[f * num_accounts + start] > 0:
            return [start, f]
    return []


def compress_obligation_cycles(
    account_addresses: Sequence[str],
    num_assets: int,
    obligations: Sequence[ObligationEdge],
) -> CycleCompressionOutcome:
    num_accounts = len(account_addresses)
    if len(obligations) > MAX_OBLIGATIONS or num_accounts > MAX_ACCOUNTS:
        raise ClearingEngineError("BatchCapacityExceeded")
    if not obligations:
        return CycleCompressionOutcome(0, [0] * num_assets, [])

    asset_mask = 0
    for ob in obligations:
        if (
            ob.debtor < 0
            or ob.creditor < 0
            or ob.debtor >= num_accounts
            or ob.creditor >= num_accounts
            or ob.debtor == ob.creditor
            or ob.asset_id < 0
            or ob.asset_id >= num_assets
            or ob.amount_wad <= 0
            or ob.amount_wad > U256_MAX
        ):
            raise ClearingEngineError("InvalidObligation")
        asset_mask |= 1 << ob.asset_id

    addr_keys = [_addr_bytes(a) for a in account_addresses]
    rank_to_orig = sorted(range(num_accounts), key=lambda idx: addr_keys[idx])
    orig_to_rank = [0] * num_accounts
    for rank, orig in enumerate(rank_to_orig):
        orig_to_rank[orig] = rank

    compressed_by_asset = [0] * num_assets
    cycles_eliminated = 0
    residual: List[ObligationEdge] = []

    for a in range(num_assets):
        if (asset_mask & (1 << a)) == 0:
            continue
        mat = [0] * (num_accounts * num_accounts)
        for ob in obligations:
            if ob.asset_id != a:
                continue
            u = orig_to_rank[ob.debtor]
            v = orig_to_rank[ob.creditor]
            mat[u * num_accounts + v] = _check_u256(mat[u * num_accounts + v] + ob.amount_wad)

        for start in range(num_accounts):
            while True:
                path = _find_canonical_cycle_bfs(start, num_accounts, mat)
                if not path:
                    break
                plen = len(path)
                bottleneck = min(mat[path[i] * num_accounts + path[(i + 1) % plen]] for i in range(plen))
                for i in range(plen):
                    idx_edge = path[i] * num_accounts + path[(i + 1) % plen]
                    mat[idx_edge] -= bottleneck
                compressed_by_asset[a] = _check_u256(compressed_by_asset[a] + bottleneck * plen)
                cycles_eliminated += 1

        for u_rank in range(num_accounts):
            u_orig = rank_to_orig[u_rank]
            for v_rank in range(num_accounts):
                w = mat[u_rank * num_accounts + v_rank]
                if w > 0:
                    residual.append(
                        ObligationEdge(
                            debtor=u_orig,
                            creditor=rank_to_orig[v_rank],
                            asset_id=a,
                            amount_wad=w,
                        )
                    )

    return CycleCompressionOutcome(cycles_eliminated, compressed_by_asset, residual)


def _is_ir_eligible(side: int, limit_price_wad: int, p: int, step: int, lot_buy_q: int, lot_sell_q: int) -> bool:
    if side == 0:
        return limit_price_wad >= p and (lot_buy_q * WAD <= step * limit_price_wad)
    return lot_sell_q > 0 and limit_price_wad <= p and (step * limit_price_wad <= lot_sell_q * WAD)


def _allocate_side_fills(
    eligible_pos: Sequence[int],
    intents: Sequence[dict],
    target_volume: int,
    step: int,
    is_buy: bool,
) -> List[Tuple[int, int]]:
    if target_volume == 0 or not eligible_pos:
        return [(idx, 0) for idx in eligible_pos]
    caps = [quantize_down(intents[idx]["amount_wad"], step) for idx in eligible_pos]
    total_offered = _check_u256(sum(caps))
    if total_offered <= target_volume:
        return list(zip(eligible_pos, caps))

    target_units = target_volume // step
    fills: List[int] = []
    allocated_units = 0
    for cap in caps:
        part_units = (cap * target_units) // total_offered
        fills.append(part_units * step)
        allocated_units += part_units

    rem_units = target_units - allocated_units
    if rem_units > 0:
        def sort_key(slot: int) -> Tuple[int, bytes, int]:
            it = intents[eligible_pos[slot]]
            p_key = -it["limit_price_wad"] if is_buy else it["limit_price_wad"]
            return (p_key, _addr_bytes(it["trader_address"]), it["nonce"])

        for slot in sorted(range(len(eligible_pos)), key=sort_key):
            if rem_units == 0:
                break
            avail_units = (caps[slot] - fills[slot]) // step
            take = min(avail_units, rem_units)
            fills[slot] += take * step
            rem_units -= take

    return list(zip(eligible_pos, fills))


def clear_single_market_auction(
    base_asset: int,
    quote_asset: int,
    base_mark_wad: int,
    quote_mark_wad: int,
    max_price_deviation_bps: int,
    market_indices: Sequence[int],
    all_intents: Sequence[dict],
) -> Tuple[MarketAuctionReport, List[Tuple[int, int, int, int]]]:
    ref_price = mul_div_floor(base_mark_wad, WAD, quote_mark_wad)
    if ref_price == 0:
        raise ClearingEngineError("InvalidAssetConfig")
    ref_tick = quantize_reference_tick(ref_price)
    band_low = 1
    if max_price_deviation_bps < BPS_DENOM:
        low = mul_div_ceil(ref_price, BPS_DENOM - max_price_deviation_bps, BPS_DENOM)
        if low > 0:
            band_low = low
    band_high = mul_div_floor(ref_price, BPS_DENOM + max_price_deviation_bps, BPS_DENOM)

    step = MIN_INTENT_AMOUNT_WAD
    cand_set = {ref_tick}
    if band_low > 0:
        cand_set.add(band_low)
    if band_high > 0:
        cand_set.add(band_high)
    for i in market_indices:
        lp = all_intents[i]["limit_price_wad"]
        cand_set.add(lp)
        tlp = quantize_down(lp, step)
        if tlp > 0:
            cand_set.add(tlp)
    candidates = sorted(cand_set)

    best_price = ref_tick
    best_vol = 0
    best_imbalance = U256_MAX
    best_ref_dist = U256_MAX
    out_of_band_crossed = False

    for p in candidates:
        if p <= 0:
            continue
        lot_buy_q = mul_wad_ceil(step, p)
        lot_sell_q = mul_wad_floor(step, p)
        demand = 0
        supply = 0
        for idx in market_indices:
            it = all_intents[idx]
            if not _is_ir_eligible(it["side"], it["limit_price_wad"], p, step, lot_buy_q, lot_sell_q):
                continue
            q_amt = quantize_down(it["amount_wad"], step)
            if it["side"] == 0:
                demand = _check_u256(demand + q_amt)
            else:
                supply = _check_u256(supply + q_amt)
        matched = min(demand, supply)
        if matched == 0:
            continue
        ref_dist = abs(p - ref_price)
        if ref_dist * BPS_DENOM > ref_price * max_price_deviation_bps:
            out_of_band_crossed = True
            continue
        imbalance = abs(demand - supply)
        better = (
            matched > best_vol
            or (matched == best_vol and imbalance < best_imbalance)
            or (matched == best_vol and imbalance == best_imbalance and ref_dist < best_ref_dist)
            or (matched == best_vol and imbalance == best_imbalance and ref_dist == best_ref_dist and p < best_price)
        )
        if better:
            best_vol = matched
            best_imbalance = imbalance
            best_ref_dist = ref_dist
            best_price = p

    if best_vol == 0:
        if out_of_band_crossed:
            raise ClearingEngineError("LimitPriceViolated")
        return MarketAuctionReport(base_asset, quote_asset, best_price, 0, 0), []

    lot_buy_q = mul_wad_ceil(step, best_price)
    lot_sell_q = mul_wad_floor(step, best_price)
    buy_elig = [
        i for i in market_indices
        if all_intents[i]["side"] == 0
        and _is_ir_eligible(0, all_intents[i]["limit_price_wad"], best_price, step, lot_buy_q, lot_sell_q)
    ]
    sell_elig = [
        i for i in market_indices
        if all_intents[i]["side"] == 1
        and _is_ir_eligible(1, all_intents[i]["limit_price_wad"], best_price, step, lot_buy_q, lot_sell_q)
    ]
    buy_fills = _allocate_side_fills(buy_elig, all_intents, best_vol, step, True)
    sell_fills = _allocate_side_fills(sell_elig, all_intents, best_vol, step, False)

    total_paid = 0
    total_recv = 0
    executions: List[Tuple[int, int, int, int]] = []
    for idx, fill_base in buy_fills:
        if fill_base == 0:
            continue
        q_amt = mul_wad_ceil(fill_base, best_price)
        lp = all_intents[idx]["limit_price_wad"]
        if best_price > lp or q_amt * WAD > fill_base * lp:
            raise ClearingEngineError("LimitPriceViolated")
        total_paid = _check_u256(total_paid + q_amt)
        executions.append((idx, 0, fill_base, q_amt))

    for idx, fill_base in sell_fills:
        if fill_base == 0:
            continue
        q_amt = mul_wad_floor(fill_base, best_price)
        lp = all_intents[idx]["limit_price_wad"]
        if q_amt == 0 or best_price < lp or fill_base * lp > q_amt * WAD:
            raise ClearingEngineError("LimitPriceViolated")
        total_recv = _check_u256(total_recv + q_amt)
        executions.append((idx, 1, fill_base, q_amt))

    if total_paid < total_recv:
        raise ClearingEngineError("MathOverflow")
    dust = total_paid - total_recv
    return MarketAuctionReport(base_asset, quote_asset, best_price, best_vol, dust), executions


def execute_underwater_liquidation(
    block_timestamp: int,
    max_price_staleness: int,
    assets: Sequence[AssetRiskConfig],
    underwater_balances: Sequence[int],
    liquidator_balances: Sequence[int],
    debt_asset: int,
    collateral_asset: int,
    repay_amount_wad: int,
    underwater_address: Optional[str] = None,
    liquidator_address: Optional[str] = None,
) -> LiquidationOutcome:
    if underwater_address is not None and liquidator_address is not None:
        if _norm_addr(underwater_address) == _norm_addr(liquidator_address):
            raise ClearingEngineError("InvalidIntent", "self-liquidation forbidden")
    n_assets = len(assets)
    if (
        n_assets == 0
        or n_assets > MAX_ASSETS
        or len(underwater_balances) != n_assets
        or len(liquidator_balances) != n_assets
    ):
        raise ClearingEngineError("InvalidAssetConfig")
    if (
        debt_asset < 0
        or collateral_asset < 0
        or debt_asset >= n_assets
        or collateral_asset >= n_assets
        or debt_asset == collateral_asset
        or repay_amount_wad < MIN_INTENT_AMOUNT_WAD
        or repay_amount_wad > U256_MAX
    ):
        raise ClearingEngineError("InvalidIntent")

    active_mask = (1 << debt_asset) | (1 << collateral_asset)
    for a in range(n_assets):
        if underwater_balances[a] != 0 or liquidator_balances[a] != 0:
            active_mask |= 1 << a
    validate_asset_configs_selective(assets, active_mask, block_timestamp, max_price_staleness)

    pre_u_risk = evaluate_account_risk(underwater_balances, assets)
    if pre_u_risk.health_wad >= 0 or underwater_balances[debt_asset] >= 0 or underwater_balances[collateral_asset] <= 0:
        raise ClearingEngineError("InvalidIntent")

    abs_debt = -underwater_balances[debt_asset]
    avail_coll = underwater_balances[collateral_asset]
    capped_repay = min(repay_amount_wad, abs_debt)
    bonus_bps = compute_liquidation_bonus_bps(assets[debt_asset].mm_bps)
    bonus_factor = BPS_DENOM + bonus_bps

    quote_repay_wad = mul_div_floor(capped_repay, assets[debt_asset].mark_price_wad, assets[collateral_asset].mark_price_wad)
    raw_seize = mul_div_floor(quote_repay_wad, bonus_factor, BPS_DENOM)

    if raw_seize > avail_coll:
        max_quote = mul_div_floor(avail_coll, BPS_DENOM, bonus_factor)
        back_repay = mul_div_floor(max_quote, assets[collateral_asset].mark_price_wad, assets[debt_asset].mark_price_wad)
        actual_repay = min(capped_repay, back_repay)
        actual_seize = avail_coll
    else:
        actual_repay = capped_repay
        actual_seize = raw_seize

    if actual_seize == 0 or actual_repay < MIN_INTENT_AMOUNT_WAD:
        raise ClearingEngineError("InvalidIntent")

    if liquidator_balances[debt_asset] < actual_repay:
        raise ClearingEngineError("InsufficientWithdrawableBalance")

    post_u = list(underwater_balances)
    post_l = list(liquidator_balances)
    post_u[debt_asset] = _check_i256(post_u[debt_asset] + actual_repay)
    post_u[collateral_asset] = _check_i256(post_u[collateral_asset] - actual_seize)
    post_l[debt_asset] = _check_i256(post_l[debt_asset] - actual_repay)
    post_l[collateral_asset] = _check_i256(post_l[collateral_asset] + actual_seize)

    post_u_risk = evaluate_account_risk(post_u, assets)
    post_l_risk = evaluate_account_risk(post_l, assets)

    coll_exhausted = post_u[collateral_asset] == 0
    if coll_exhausted:
        health_ok = (post_u_risk.health_wad >= pre_u_risk.health_wad) and (
            post_u_risk.total_liability_wad < pre_u_risk.total_liability_wad
        )
    else:
        health_ok = post_u_risk.health_wad > pre_u_risk.health_wad
    if not health_ok:
        raise ClearingEngineError("HealthMonotonicityViolated")
    if post_l_risk.im_surplus_wad < 0:
        raise ClearingEngineError("InsufficientInitialMargin")

    return LiquidationOutcome(
        repaid_debt_wad=actual_repay,
        seized_collateral_wad=actual_seize,
        post_underwater_balances=post_u,
        post_liquidator_balances=post_l,
    )


def _consume_nonce(bitmaps: Dict[Tuple[int, int], int], account_idx: int, nonce: int) -> None:
    _check_u256(nonce)
    word_pos = nonce >> 8
    bit_pos = nonce & 0xFF
    key = (account_idx, word_pos)
    word = bitmaps.get(key, 0)
    mask = 1 << bit_pos
    if (word & mask) != 0:
        raise ClearingEngineError("NonceAlreadyUsed")
    bitmaps[key] = word | mask


def execute_batch_payload(payload: dict) -> dict:
    """Executes a canonical JSON batch vector (matching clearing-cli replay schema)."""
    batch_epoch = int(payload["batch_epoch"])
    block_timestamp = int(payload["block_timestamp"])
    max_price_staleness = int(payload.get("max_price_staleness", 3600))
    max_price_deviation_bps = int(payload.get("max_price_deviation_bps", 2000))
    chain_id = int(payload.get("chain_id", 421614))
    verifying_contract = _norm_addr(payload.get("verifying_contract", "0x" + "11" * 20))
    caller = _norm_addr(payload.get("caller", "0x" + "aa" * 20))

    if (
        batch_epoch < 0 or batch_epoch > U64_MAX
        or chain_id < 0 or chain_id > U64_MAX
        or max_price_deviation_bps < 0 or max_price_deviation_bps > BPS_DENOM
    ):
        raise ClearingEngineError("BatchCapacityExceeded")

    assets = [
        AssetRiskConfig(
            asset_id=int(a["asset_id"]),
            decimals=int(a.get("decimals", 18)),
            mark_price_wad=int(a["mark_price_wad"]),
            price_updated_at=int(a["price_updated_at"]),
            haircut_bps=int(a["haircut_bps"]),
            im_bps=int(a["im_bps"]),
            mm_bps=int(a["mm_bps"]),
        )
        for a in payload["assets"]
    ]
    raw_accounts = payload["accounts"]
    raw_obs = payload.get("obligations", [])
    raw_intents = payload.get("intents", [])

    num_assets = len(assets)
    num_accounts = len(raw_accounts)
    if (
        num_assets == 0 or num_assets > MAX_ASSETS
        or num_accounts == 0 or num_accounts > MAX_ACCOUNTS
        or len(raw_obs) > MAX_OBLIGATIONS
        or len(raw_intents) > MAX_INTENTS
    ):
        raise ClearingEngineError("BatchCapacityExceeded")

    validate_asset_configs_selective(assets, 0, block_timestamp, max_price_staleness)

    addrs: List[str] = []
    bals: List[List[int]] = []
    active_mask = 0
    for i, acc in enumerate(raw_accounts):
        addr = _norm_addr(acc["address"])
        if addr == "0x" + "00" * 40:
            raise ClearingEngineError("InvalidAssetConfig")
        if addr in addrs:
            raise ClearingEngineError("DuplicateParticipant")
        addrs.append(addr)
        row = [int(x) for x in acc["balances"]]
        if len(row) != num_assets:
            raise ClearingEngineError("InvalidAssetConfig")
        for a_idx, v in enumerate(row):
            _check_i256(v)
            if v != 0:
                active_mask |= 1 << a_idx
        bals.append(row)

    for ob in raw_obs:
        aid = int(ob["asset_id"])
        if 0 <= aid < num_assets:
            active_mask |= 1 << aid
    for it in raw_intents:
        bid = int(it["base_asset"])
        qid = int(it["quote_asset"])
        if 0 <= bid < num_assets:
            active_mask |= 1 << bid
        if 0 <= qid < num_assets:
            active_mask |= 1 << qid
    if active_mask == 0:
        active_mask = 1
    validate_asset_configs_selective(assets, active_mask, block_timestamp, max_price_staleness)

    work_bitmaps: Dict[Tuple[int, int], int] = {}
    nb_raw = payload.get("nonce_bitmaps", {})
    if isinstance(nb_raw, dict):
        for k, v_word in nb_raw.items():
            parts = str(k).split(":")
            if len(parts) == 2:
                work_bitmaps[(int(parts[0]), int(parts[1]))] = int(v_word)
    else:
        for entry in nb_raw:
            work_bitmaps[(int(entry["account"]), int(entry["word_pos"]))] = int(entry["word"])

    work_confirmed: Dict[Tuple[int, int, int], int] = {}
    co_raw = payload.get("confirmed_obligations", {})
    if isinstance(co_raw, dict):
        for k, v_amt in co_raw.items():
            u_s, v_s, a_s = str(k).split(":")
            work_confirmed[(int(u_s), int(v_s), int(a_s))] = int(v_amt)
    else:
        for entry in co_raw:
            work_confirmed[(int(entry["debtor"]), int(entry["creditor"]), int(entry["asset_id"]))] = int(entry["amount_wad"])

    domain_sep = compute_domain_separator(chain_id, verifying_contract)
    verified_edges: List[ObligationEdge] = []
    touched_mask = 0
    risk_mask = 0

    for ob in raw_obs:
        u = int(ob["debtor"])
        v = int(ob["creditor"])
        a = int(ob["asset_id"])
        amt = int(ob["amount_wad"])
        if u < 0 or v < 0 or u >= num_accounts or v >= num_accounts or u == v or a < 0 or a >= num_assets or amt <= 0 or amt > U256_MAX:
            raise ClearingEngineError("InvalidObligation")
        auth_obj = ob.get("auth") or {}
        if "auth_mode" in ob:
            mode = ob["auth_mode"]
        else:
            mode = auth_obj.get("mode", "LEDGER")
        if isinstance(mode, str):
            mode = {"pre_registered": 0, "ledger": 0, "direct_debtor": 1, "direct": 1, "eip712": 2}[mode.lower()]
        if mode == 0:
            key = (u, v, a)
            avail = work_confirmed.get(key, 0)
            if amt > avail:
                raise ClearingEngineError("UnauthorizedObligation")
            work_confirmed[key] = avail - amt
        elif mode == 1:
            max_ep = int(ob.get("max_epoch", U64_MAX))
            if batch_epoch > max_ep:
                raise ClearingEngineError("ExpiredIntent")
            _consume_nonce(work_bitmaps, u, int(ob["nonce"]))
            if caller != addrs[u]:
                raise ClearingEngineError("UnauthorizedObligation")
        elif mode == 2:
            max_ep = int(ob["max_epoch"])
            if batch_epoch > max_ep:
                raise ClearingEngineError("ExpiredIntent")
            nonce = int(ob["nonce"])
            _consume_nonce(work_bitmaps, u, nonce)
            digest = compute_obligation_digest(chain_id, verifying_contract, addrs[u], addrs[v], a, amt, max_ep, nonce)
            signer = recover_eip712_signer(digest, int(ob.get("v", auth_obj.get("v", 0))), ob.get("r", auth_obj.get("r", "0x0")), ob.get("s", auth_obj.get("s", "0x0")))
            if signer is None or _norm_addr(signer) != addrs[u]:
                raise ClearingEngineError("InvalidSignature")
        else:
            raise ClearingEngineError("InvalidObligation")
        verified_edges.append(ObligationEdge(u, v, a, amt))
        touched_mask |= (1 << u) | (1 << v)

    normalized_intents: List[dict] = []
    staged_bitmaps = dict(work_bitmaps)

    for idx, raw in enumerate(raw_intents):
        side_raw = raw["side"]
        if isinstance(side_raw, str):
            side = 0 if side_raw.lower() == "buy" else 1
        else:
            side = int(side_raw)
        if side not in (0, 1):
            raise ClearingEngineError("InvalidIntent")
        tr = int(raw["trader"])
        b_id = int(raw["base_asset"])
        q_id = int(raw["quote_asset"])
        amt = int(raw["amount_wad"])
        signed_amt = int(raw.get("signed_amount_wad", 0)) or amt
        lp = int(raw["limit_price_wad"])
        max_ep = int(raw["max_epoch"])
        nonce = int(raw["nonce"])
        if (
            tr < 0 or tr >= num_accounts
            or q_id < 0 or q_id >= b_id or b_id >= num_assets
            or amt < MIN_INTENT_AMOUNT_WAD
            or amt > signed_amt
            or signed_amt > U256_MAX
            or lp <= 0 or lp > U256_MAX
            or max_ep < 0 or max_ep > U64_MAX
        ):
            raise ClearingEngineError("InvalidIntent")
        for prev in normalized_intents:
            if prev["trader"] == tr and prev["base_asset"] == b_id and prev["quote_asset"] == q_id and prev["side"] != side:
                raise ClearingEngineError("InvalidIntent", "opposite-side self-match forbidden")
        if batch_epoch > max_ep:
            raise ClearingEngineError("ExpiredIntent")
        _consume_nonce(staged_bitmaps, tr, nonce)

        it_auth = raw.get("auth") or {}
        if "auth_mode" in raw:
            auth_mode = raw["auth_mode"]
        else:
            auth_mode = it_auth.get("mode", "DIRECT")
        if isinstance(auth_mode, str):
            auth_mode = 0 if auth_mode.lower() in ("direct_caller", "direct") else 1
        if auth_mode == 0:
            if caller != addrs[tr]:
                raise ClearingEngineError("UnauthorizedCaller")
        elif auth_mode == 1:
            digest = compute_intent_digest(chain_id, verifying_contract, addrs[tr], b_id, q_id, side, signed_amt, lp, max_ep, nonce)
            signer = recover_eip712_signer(digest, int(raw.get("v", it_auth.get("v", 0))), raw.get("r", it_auth.get("r", "0x0")), raw.get("s", it_auth.get("s", "0x0")))
            if signer is None or _norm_addr(signer) != addrs[tr]:
                raise ClearingEngineError("InvalidSignature")
        else:
            raise ClearingEngineError("InvalidIntent")

        normalized_intents.append(
            {
                "intent_index": idx,
                "trader": tr,
                "trader_address": addrs[tr],
                "base_asset": b_id,
                "quote_asset": q_id,
                "side": side,
                "amount_wad": amt,
                "signed_amount_wad": signed_amt,
                "limit_price_wad": lp,
                "nonce": nonce,
                "auth_mode": auth_mode,
            }
        )

    pre_sums = [0] * num_assets
    pre_risks: List[AccountRiskMetrics] = []
    for u in range(num_accounts):
        for a in range(num_assets):
            pre_sums[a] = _check_i256(pre_sums[a] + bals[u][a])
        pre_risks.append(evaluate_account_risk(bals[u], assets))

    compression = compress_obligation_cycles(addrs, num_assets, verified_edges)
    for res_ob in compression.residual_obligations:
        bals[res_ob.debtor][res_ob.asset_id] = _check_i256(bals[res_ob.debtor][res_ob.asset_id] - res_ob.amount_wad)
        bals[res_ob.creditor][res_ob.asset_id] = _check_i256(bals[res_ob.creditor][res_ob.asset_id] + res_ob.amount_wad)
        risk_mask |= 1 << res_ob.debtor

    fee_deltas = [0] * num_assets
    auctions: List[MarketAuctionReport] = []
    total_matched = 0
    intent_fills = [IntentFill(i, 0, 0) for i in range(len(normalized_intents))]

    for b_idx in range(1, num_assets):
        for q_idx in range(0, b_idx):
            indices = [i for i, it in enumerate(normalized_intents) if it["base_asset"] == b_idx and it["quote_asset"] == q_idx]
            if not indices:
                continue
            report, executions = clear_single_market_auction(
                b_idx,
                q_idx,
                assets[b_idx].mark_price_wad,
                assets[q_idx].mark_price_wad,
                max_price_deviation_bps,
                indices,
                normalized_intents,
            )
            for intent_pos, side, fill_base, quote_xfer in executions:
                norm_it = normalized_intents[intent_pos]
                tr = norm_it["trader"]
                if norm_it["auth_mode"] == 0 or fill_base == norm_it["amount_wad"]:
                    _consume_nonce(work_bitmaps, tr, norm_it["nonce"])
                if side == 0:
                    bals[tr][b_idx] = _check_i256(bals[tr][b_idx] + fill_base)
                    bals[tr][q_idx] = _check_i256(bals[tr][q_idx] - quote_xfer)
                else:
                    bals[tr][b_idx] = _check_i256(bals[tr][b_idx] - fill_base)
                    bals[tr][q_idx] = _check_i256(bals[tr][q_idx] + quote_xfer)
                intent_fills[intent_pos] = IntentFill(intent_pos, fill_base, quote_xfer)
                touched_mask |= 1 << tr
                risk_mask |= 1 << tr
            total_matched = _check_u256(total_matched + report.matched_volume_wad)
            fee_deltas[q_idx] = _check_u256(fee_deltas[q_idx] + report.rounding_dust_quote_wad)
            auctions.append(report)

    for a in range(num_assets):
        post_sum = _check_i256(fee_deltas[a] + sum(bals[u][a] for u in range(num_accounts)))
        if post_sum != pre_sums[a]:
            raise ClearingEngineError("AssetConservationViolated")

    if not verified_edges and total_matched == 0:
        raise ClearingEngineError("InvalidIntent")

    post_accounts = []
    for u, pre_risk in enumerate(pre_risks):
        post_risk = evaluate_account_risk(bals[u], assets)
        if (touched_mask & (1 << u)) != 0:
            requires_full_im = ((risk_mask & (1 << u)) != 0) and (
                pre_risk.im_surplus_wad >= 0
                or post_risk.required_im_wad > pre_risk.required_im_wad
                or post_risk.total_liability_wad > pre_risk.total_liability_wad
            )
            if requires_full_im and post_risk.im_surplus_wad < 0:
                raise ClearingEngineError("InsufficientInitialMargin")
            if (pre_risk.im_surplus_wad < 0 or post_risk.im_surplus_wad < 0) and post_risk.net_equity_wad < pre_risk.net_equity_wad:
                raise ClearingEngineError("HealthMonotonicityViolated")
            if post_risk.im_surplus_wad < 0 and (
                post_risk.im_surplus_wad < pre_risk.im_surplus_wad or post_risk.health_wad < pre_risk.health_wad
            ):
                raise ClearingEngineError("HealthMonotonicityViolated")
        post_accounts.append(
            {
                "address": addrs[u],
                "balances": [str(x) for x in bals[u]],
                "health_wad": str(post_risk.health_wad),
                "im_surplus_wad": str(post_risk.im_surplus_wad),
                "net_equity_wad": str(post_risk.net_equity_wad),
            }
        )

    return {
        "batch_epoch": batch_epoch,
        "cycles_eliminated": compression.cycles_eliminated,
        "total_matched_volume_wad": str(total_matched),
        "compressed_volume_by_asset": [str(x) for x in compression.compressed_volume_by_asset],
        "fee_vault_deltas": [str(x) for x in fee_deltas],
        "auctions": [
            {
                "base_asset": r.base_asset,
                "quote_asset": r.quote_asset,
                "clearing_price_wad": str(r.clearing_price_wad),
                "matched_volume_wad": str(r.matched_volume_wad),
                "rounding_dust_quote_wad": str(r.rounding_dust_quote_wad),
            }
            for r in auctions
        ],
        "post_accounts": post_accounts,
    }

ClearingError = ClearingEngineError
execute_clearing_batch = execute_batch_payload
