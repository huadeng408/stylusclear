use alloc::vec::Vec;
use alloy_primitives::{Address, U256};

use crate::error::ClearingError;
use crate::math::{
    abs_diff_ref, cmp_u256, div_rem_u256_ref, gt_mul_512_ref, insertion_sort_by, mul_div_ref,
    mul_u64_div_u64_ref, mul_wad_ref, quantize_down_ref, uadd_assign, umul_ref, usub_assign,
    usub_ref, BPS_DENOM_U64, MIN_INTENT_AMOUNT_U64, WAD_U64,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderSide {
    Buy = 0,
    Sell = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NormalizedIntent {
    pub intent_index: usize,
    pub trader: u16,
    pub trader_address: Address,
    pub base_asset: u8,
    pub quote_asset: u8,
    pub side: OrderSide,
    pub amount_wad: U256,
    pub limit_price_wad: U256,
    pub nonce: U256,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IntentFill {
    pub intent_index: usize,
    pub filled_base_wad: U256,
    pub quote_transfer_wad: U256,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarketAuctionReport {
    pub base_asset: u8,
    pub quote_asset: u8,
    pub clearing_price_wad: U256,
    pub matched_volume_wad: U256,
    pub rounding_dust_quote_wad: U256,
}

#[inline]
pub fn lot_step_for_price(_price_wad: U256) -> U256 {
    U256::from(MIN_INTENT_AMOUNT_U64)
}

#[inline(never)]
pub fn quantize_reference_tick_ref(ref_price: &U256, out: &mut U256) {
    let tiers: [(u64, u64); 3] = [
        (10_000_000_000_000, MIN_INTENT_AMOUNT_U64),
        (10_000_000_000, 1_000_000),
        (10_000_000, 1_000),
    ];
    for (threshold, quantum) in tiers {
        if cmp_u256(ref_price, &U256::from(threshold)).is_ge() {
            let q_u = U256::from(quantum);
            let mut quot = U256::ZERO;
            let mut rem = U256::ZERO;
            if div_rem_u256_ref(ref_price, &q_u, &mut quot, &mut rem).is_ok()
                && umul_ref(&quot, &q_u, out).is_ok()
            {
                return;
            }
        }
    }
    *out = *ref_price;
}

#[cfg(not(target_arch = "wasm32"))]
pub fn quantize_reference_tick(ref_price: U256) -> U256 {
    let mut out = U256::ZERO;
    quantize_reference_tick_ref(&ref_price, &mut out);
    out
}

/// Exact 512-bit per-lot Individual Rationality predicate (`D-09`):
/// - Buy: `ceil(step * p / 1e18) * 1e18 <= step * limit_price_wad`
/// - Sell: `floor(step * p / 1e18) > 0 && floor(step * p / 1e18) * 1e18 >= step * limit_price_wad`
#[inline(never)]
fn is_intent_ir_eligible_at_price(
    it: &NormalizedIntent,
    p: &U256,
    step: &U256,
    wad: &U256,
    lot_buy_quote: &U256,
    lot_sell_quote: &U256,
) -> bool {
    match it.side {
        OrderSide::Buy => {
            cmp_u256(&it.limit_price_wad, p).is_ge()
                && !gt_mul_512_ref(lot_buy_quote, wad, step, &it.limit_price_wad)
        }
        OrderSide::Sell => {
            !lot_sell_quote.is_zero()
                && cmp_u256(&it.limit_price_wad, p).is_le()
                && !gt_mul_512_ref(step, &it.limit_price_wad, lot_sell_quote, wad)
        }
    }
}

#[inline(never)]
fn allocate_side_fills(
    eligible_pos: &[usize],
    intents: &[NormalizedIntent],
    target_volume: &U256,
    step: &U256,
    is_buy: bool,
) -> Result<Vec<(usize, U256)>, ClearingError> {
    if target_volume.is_zero() || eligible_pos.is_empty() {
        let mut z = Vec::with_capacity(eligible_pos.len());
        for &idx in eligible_pos {
            z.push((idx, U256::ZERO));
        }
        return Ok(z);
    }

    let mut caps = Vec::with_capacity(eligible_pos.len());
    let mut total_offered = U256::ZERO;
    for &idx in eligible_pos {
        let mut q_cap = U256::ZERO;
        quantize_down_ref(&intents[idx].amount_wad, step, &mut q_cap)?;
        caps.push(q_cap);
        uadd_assign(&mut total_offered, &q_cap)?;
    }

    if cmp_u256(&total_offered, target_volume).is_le() {
        let mut out = Vec::with_capacity(eligible_pos.len());
        for (&idx, cap) in eligible_pos.iter().zip(caps) {
            out.push((idx, cap));
        }
        return Ok(out);
    }

    let mut target_units = U256::ZERO;
    let mut unused_r = U256::ZERO;
    div_rem_u256_ref(target_volume, step, &mut target_units, &mut unused_r)?;
    let mut fills = Vec::with_capacity(eligible_pos.len());
    let mut allocated_units = U256::ZERO;

    for cap in &caps {
        let mut part_units = U256::ZERO;
        mul_div_ref(cap, &target_units, &total_offered, false, &mut part_units)?;
        let mut f_wad = U256::ZERO;
        umul_ref(&part_units, step, &mut f_wad)?;
        fills.push(f_wad);
        uadd_assign(&mut allocated_units, &part_units)?;
    }

    let mut rem_units = U256::ZERO;
    usub_ref(&target_units, &allocated_units, &mut rem_units)?;
    if !rem_units.is_zero() {
        let mut order = [0u8; 128];
        let n_el = eligible_pos.len();
        for (idx_o, slot_o) in order.iter_mut().take(n_el).enumerate() {
            *slot_o = idx_o as u8;
        }
        insertion_sort_by(&mut order[..n_el], |&a, &b| {
            let ia = &intents[eligible_pos[usize::from(a)]];
            let ib = &intents[eligible_pos[usize::from(b)]];
            let price_cmp = if is_buy {
                cmp_u256(&ib.limit_price_wad, &ia.limit_price_wad)
            } else {
                cmp_u256(&ia.limit_price_wad, &ib.limit_price_wad)
            };
            price_cmp
                .then_with(|| ia.trader_address.cmp(&ib.trader_address))
                .then_with(|| cmp_u256(&ia.nonce, &ib.nonce))
        });

        for &slot_u8 in &order[..n_el] {
            if rem_units.is_zero() {
                break;
            }
            let slot = usize::from(slot_u8);
            let mut rem_cap = U256::ZERO;
            usub_ref(&caps[slot], &fills[slot], &mut rem_cap)?;
            let mut avail_units = U256::ZERO;
            div_rem_u256_ref(&rem_cap, step, &mut avail_units, &mut unused_r)?;
            let take_units = if cmp_u256(&avail_units, &rem_units).is_lt() {
                avail_units
            } else {
                rem_units
            };
            let mut add_wad = U256::ZERO;
            umul_ref(&take_units, step, &mut add_wad)?;
            uadd_assign(&mut fills[slot], &add_wad)?;
            usub_assign(&mut rem_units, &take_units)?;
        }
    }

    let mut out = Vec::with_capacity(eligible_pos.len());
    for (&idx, fill) in eligible_pos.iter().zip(fills) {
        out.push((idx, fill));
    }
    Ok(out)
}

#[inline(never)]
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
pub fn clear_single_market_auction(
    base_asset: u8,
    quote_asset: u8,
    base_mark_wad: &U256,
    quote_mark_wad: &U256,
    max_price_deviation_bps: u16,
    market_indices: &[usize],
    all_intents: &[NormalizedIntent],
) -> Result<(MarketAuctionReport, Vec<(usize, OrderSide, U256, U256)>), ClearingError> {
    let wad = U256::from(WAD_U64);
    let mut ref_price = U256::ZERO;
    mul_div_ref(base_mark_wad, &wad, quote_mark_wad, false, &mut ref_price)?;
    if ref_price.is_zero() {
        return Err(ClearingError::InvalidAssetConfig);
    }
    let mut ref_tick = U256::ZERO;
    quantize_reference_tick_ref(&ref_price, &mut ref_tick);
    let dev_u64 = u64::from(max_price_deviation_bps);
    let mut band_low = U256::from(1u64);
    if dev_u64 < BPS_DENOM_U64 {
        let mut low = U256::ZERO;
        mul_u64_div_u64_ref(
            &ref_price,
            BPS_DENOM_U64 - dev_u64,
            BPS_DENOM_U64,
            true,
            &mut low,
        )?;
        if !low.is_zero() {
            band_low = low;
        }
    }
    let mut band_high = U256::ZERO;
    mul_u64_div_u64_ref(
        &ref_price,
        BPS_DENOM_U64 + dev_u64,
        BPS_DENOM_U64,
        false,
        &mut band_high,
    )?;

    let mut candidates = Vec::with_capacity(market_indices.len() * 2 + 3);
    let step = U256::from(MIN_INTENT_AMOUNT_U64);
    for &i in market_indices {
        let lp = all_intents[i].limit_price_wad;
        candidates.push(lp);
        let mut tick_lp = U256::ZERO;
        if quantize_down_ref(&lp, &step, &mut tick_lp).is_ok() && !tick_lp.is_zero() {
            candidates.push(tick_lp);
        }
    }
    candidates.push(ref_tick);
    if !band_low.is_zero() {
        candidates.push(band_low);
    }
    if !band_high.is_zero() {
        candidates.push(band_high);
    }
    insertion_sort_by(&mut candidates, cmp_u256);
    candidates.dedup_by(|a, b| cmp_u256(a, b).is_eq());

    let bps_denom = U256::from(BPS_DENOM_U64);
    let dev_u256 = U256::from(dev_u64);
    let mut best_price = ref_tick;
    let mut best_vol = U256::ZERO;
    let mut best_imbalance = U256::MAX;
    let mut best_ref_dist = U256::MAX;
    let mut out_of_band_crossed = false;

    let mut q_amt = U256::ZERO;
    let mut imbalance = U256::ZERO;
    let mut ref_dist = U256::ZERO;
    let mut lot_buy_q = U256::ZERO;
    let mut lot_sell_q = U256::ZERO;

    for p in &candidates {
        if p.is_zero() {
            continue;
        }
        mul_wad_ref(&step, p, true, &mut lot_buy_q)?;
        mul_wad_ref(&step, p, false, &mut lot_sell_q)?;

        let mut demand = U256::ZERO;
        let mut supply = U256::ZERO;
        for &idx in market_indices {
            let it = &all_intents[idx];
            if !is_intent_ir_eligible_at_price(it, p, &step, &wad, &lot_buy_q, &lot_sell_q) {
                continue;
            }
            quantize_down_ref(&it.amount_wad, &step, &mut q_amt)?;
            match it.side {
                OrderSide::Buy => uadd_assign(&mut demand, &q_amt)?,
                OrderSide::Sell => uadd_assign(&mut supply, &q_amt)?,
            }
        }
        let matched = if cmp_u256(&demand, &supply).is_lt() {
            demand
        } else {
            supply
        };
        if matched.is_zero() {
            continue;
        }

        abs_diff_ref(p, &ref_price, &mut ref_dist);
        if gt_mul_512_ref(&ref_dist, &bps_denom, &ref_price, &dev_u256) {
            out_of_band_crossed = true;
            continue;
        }

        abs_diff_ref(&demand, &supply, &mut imbalance);

        let m_cmp = cmp_u256(&matched, &best_vol);
        let i_cmp = cmp_u256(&imbalance, &best_imbalance);
        let r_cmp = cmp_u256(&ref_dist, &best_ref_dist);
        let better = m_cmp.is_gt()
            || (m_cmp.is_eq() && i_cmp.is_lt())
            || (m_cmp.is_eq() && i_cmp.is_eq() && r_cmp.is_lt())
            || (m_cmp.is_eq()
                && i_cmp.is_eq()
                && r_cmp.is_eq()
                && cmp_u256(p, &best_price).is_lt());

        if better {
            best_vol = matched;
            best_imbalance = imbalance;
            best_ref_dist = ref_dist;
            best_price = *p;
        }
    }

    if best_vol.is_zero() {
        if out_of_band_crossed {
            return Err(ClearingError::LimitPriceViolated);
        }
        return Ok((
            MarketAuctionReport {
                base_asset,
                quote_asset,
                clearing_price_wad: best_price,
                matched_volume_wad: U256::ZERO,
                rounding_dust_quote_wad: U256::ZERO,
            },
            Vec::new(),
        ));
    }

    mul_wad_ref(&step, &best_price, true, &mut lot_buy_q)?;
    mul_wad_ref(&step, &best_price, false, &mut lot_sell_q)?;

    let mut buy_elig = Vec::with_capacity(market_indices.len());
    let mut sell_elig = Vec::with_capacity(market_indices.len());
    for &i in market_indices {
        let it = &all_intents[i];
        if is_intent_ir_eligible_at_price(it, &best_price, &step, &wad, &lot_buy_q, &lot_sell_q) {
            match it.side {
                OrderSide::Buy => buy_elig.push(i),
                OrderSide::Sell => sell_elig.push(i),
            }
        }
    }

    let buy_fills = allocate_side_fills(&buy_elig, all_intents, &best_vol, &step, true)?;
    let sell_fills = allocate_side_fills(&sell_elig, all_intents, &best_vol, &step, false)?;

    let mut total_quote_paid = U256::ZERO;
    let mut total_quote_received = U256::ZERO;
    let mut executions = Vec::with_capacity(buy_fills.len() + sell_fills.len());
    let mut quote_amt = U256::ZERO;

    for (idx, fill_base) in buy_fills {
        if fill_base.is_zero() {
            continue;
        }
        mul_wad_ref(&fill_base, &best_price, true, &mut quote_amt)?;
        if cmp_u256(&best_price, &all_intents[idx].limit_price_wad).is_gt()
            || gt_mul_512_ref(&quote_amt, &wad, &fill_base, &all_intents[idx].limit_price_wad)
        {
            return Err(ClearingError::LimitPriceViolated);
        }
        uadd_assign(&mut total_quote_paid, &quote_amt)?;
        executions.push((idx, OrderSide::Buy, fill_base, quote_amt));
    }

    for (idx, fill_base) in sell_fills {
        if fill_base.is_zero() {
            continue;
        }
        mul_wad_ref(&fill_base, &best_price, false, &mut quote_amt)?;
        if quote_amt.is_zero()
            || cmp_u256(&best_price, &all_intents[idx].limit_price_wad).is_lt()
            || gt_mul_512_ref(&fill_base, &all_intents[idx].limit_price_wad, &quote_amt, &wad)
        {
            return Err(ClearingError::LimitPriceViolated);
        }
        uadd_assign(&mut total_quote_received, &quote_amt)?;
        executions.push((idx, OrderSide::Sell, fill_base, quote_amt));
    }

    let mut rounding_dust = U256::ZERO;
    usub_ref(&total_quote_paid, &total_quote_received, &mut rounding_dust)?;
    Ok((
        MarketAuctionReport {
            base_asset,
            quote_asset,
            clearing_price_wad: best_price,
            matched_volume_wad: best_vol,
            rounding_dust_quote_wad: rounding_dust,
        },
        executions,
    ))
}
