use alloc::vec::Vec;
use alloy_primitives::{Address, B256, I256, U256};

use crate::auction::{
    clear_single_market_auction, IntentFill, MarketAuctionReport, NormalizedIntent, OrderSide,
};
use crate::auth::{
    compute_domain_separator_with, compute_obligation_digest_with, compute_trade_intent_digest_with,
    consume_bitmap_bit_ref, split_bitmap_nonce_ref, verify_eip712_signature, AuthWitness,
    ObligationAuth, SignatureVerifier,
};
use crate::error::ClearingError;
use crate::margin::{
    evaluate_account_risk_into, validate_asset_configs_selective, AccountRiskMetrics,
    AssetRiskConfig,
};
use crate::math::{
    cmp_i256, cmp_u256, i_abs_ref, iadd_assign, isub_assign, mul_div_ref, mul_u64_div_u64_ref,
    u2i_ref, uadd_assign, usub_assign, FlatMap, BPS_DENOM_U64, MIN_INTENT_AMOUNT_U64,
};
use crate::netting::{compress_obligation_cycles, ObligationEdge, MAX_OBLIGATIONS};

pub const MAX_ASSETS: usize = 16;
pub const MAX_ACCOUNTS: usize = 64;
pub const MAX_INTENTS: usize = 128;
pub const DEFAULT_MAX_PRICE_DEVIATION_BPS: u16 = 2_000;
pub const DEFAULT_MAX_PRICE_STALENESS: u64 = 3_600;
pub const LIQUIDATION_BONUS_CAP_BPS: u16 = 250;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParticipantAccountInput {
    pub address: Address,
    pub balances: Vec<I256>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthenticatedObligationInput {
    pub debtor: u16,
    pub creditor: u16,
    pub asset_id: u8,
    pub amount_wad: U256,
    pub auth: ObligationAuth,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawObligationDto {
    pub debtor: u16,
    pub creditor: u16,
    pub asset_id: u8,
    pub auth_mode: u8,
    pub v: u8,
    pub max_epoch: u64,
    pub amount_wad: U256,
    pub nonce: U256,
    pub r: B256,
    pub s: B256,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TradeIntentInput {
    pub trader: u16,
    pub base_asset: u8,
    pub quote_asset: u8,
    pub side: OrderSide,
    pub amount_wad: U256,
    pub limit_price_wad: U256,
    pub max_epoch: u64,
    pub nonce: U256,
    pub witness: AuthWitness,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawTradeIntentDto {
    pub trader: u16,
    pub base_asset: u8,
    pub quote_asset: u8,
    pub side: u8,
    pub auth_mode: u8,
    pub v: u8,
    pub max_epoch: u64,
    pub amount_wad: U256,
    pub signed_amount_wad: U256,
    pub limit_price_wad: U256,
    pub nonce: U256,
    pub r: B256,
    pub s: B256,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchClearingInput {
    pub batch_epoch: u64,
    pub block_timestamp: u64,
    pub max_price_staleness: u64,
    pub max_price_deviation_bps: u16,
    pub chain_id: u64,
    pub verifying_contract: Address,
    pub caller: Address,
    pub assets: Vec<AssetRiskConfig>,
    pub accounts: Vec<ParticipantAccountInput>,
    pub confirmed_obligations: FlatMap<(u16, u16, u8), U256>,
    pub obligations: Vec<AuthenticatedObligationInput>,
    pub intents: Vec<TradeIntentInput>,
    pub nonce_bitmaps: FlatMap<(u16, U256), U256>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParticipantAccountOutput {
    pub address: Address,
    pub balances: Vec<I256>,
    pub risk: AccountRiskMetrics,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettlementReceipt {
    pub batch_epoch: u64,
    pub cycles_eliminated: u32,
    pub compressed_volume_by_asset: Vec<U256>,
    pub residual_obligations: Vec<ObligationEdge>,
    pub auctions: Vec<MarketAuctionReport>,
    pub intent_fills: Vec<IntentFill>,
    pub fee_vault_deltas: Vec<U256>,
    pub flat_post_balances: Vec<I256>,
    pub post_accounts: Vec<ParticipantAccountOutput>,
    pub updated_confirmed_obligations: FlatMap<(u16, u16, u8), U256>,
    pub updated_nonce_bitmaps: FlatMap<(u16, U256), U256>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiquidationOutcome {
    pub repaid_debt_wad: U256,
    pub seized_collateral_wad: U256,
    pub post_underwater_balances: Vec<I256>,
    pub post_liquidator_balances: Vec<I256>,
}

#[inline]
pub const fn compute_liquidation_bonus_bps(mm_bps: u16) -> u16 {
    let half = mm_bps / 2;
    if half < LIQUIDATION_BONUS_CAP_BPS {
        half
    } else {
        LIQUIDATION_BONUS_CAP_BPS
    }
}

#[inline(never)]
fn consume_account_nonce(
    bitmaps: &mut FlatMap<(u16, U256), U256>,
    account_idx: u16,
    nonce: &U256,
) -> Result<(), ClearingError> {
    let (word_pos, bit_pos) = split_bitmap_nonce_ref(nonce);
    let key = (account_idx, word_pos);
    let mut word = bitmaps.get(&key).copied().unwrap_or(U256::ZERO);
    consume_bitmap_bit_ref(&mut word, bit_pos)?;
    bitmaps.insert(key, word);
    Ok(())
}

/// Adaptive-bonus (`min(mm_bps/2, 250)`), floor-capped (`D-01`), spot-backed (`D-17`) underwater liquidation.
#[inline(never)]
#[allow(clippy::too_many_arguments)]
pub fn execute_underwater_liquidation(
    block_timestamp: u64,
    max_price_staleness: u64,
    assets: &[AssetRiskConfig],
    underwater_balances: &[I256],
    liquidator_balances: &[I256],
    debt_asset: u8,
    collateral_asset: u8,
    repay_amount_wad: U256,
) -> Result<LiquidationOutcome, ClearingError> {
    let n_assets = assets.len();
    if n_assets == 0
        || n_assets > MAX_ASSETS
        || underwater_balances.len() != n_assets
        || liquidator_balances.len() != n_assets
    {
        return Err(ClearingError::InvalidAssetConfig);
    }

    let d_idx = usize::from(debt_asset);
    let c_idx = usize::from(collateral_asset);
    let min_lot = U256::from(MIN_INTENT_AMOUNT_U64);
    if d_idx >= n_assets
        || c_idx >= n_assets
        || d_idx == c_idx
        || cmp_u256(&repay_amount_wad, &min_lot).is_lt()
    {
        return Err(ClearingError::InvalidIntent);
    }

    let mut active_mask = (1u16 << d_idx) | (1u16 << c_idx);
    for a in 0..n_assets {
        if !underwater_balances[a].is_zero() || !liquidator_balances[a].is_zero() {
            active_mask |= 1u16 << a;
        }
    }
    validate_asset_configs_selective(assets, active_mask, block_timestamp, max_price_staleness)?;

    let mut pre_u_risk = AccountRiskMetrics::default();
    evaluate_account_risk_into(underwater_balances, assets, &mut pre_u_risk)?;
    if !pre_u_risk.health_wad.is_negative()
        || !underwater_balances[d_idx].is_negative()
        || !underwater_balances[c_idx].is_positive()
    {
        return Err(ClearingError::InvalidIntent);
    }

    let mut abs_debt = U256::ZERO;
    let mut avail_coll = U256::ZERO;
    i_abs_ref(&underwater_balances[d_idx], &mut abs_debt)?;
    i_abs_ref(&underwater_balances[c_idx], &mut avail_coll)?;
    let capped_repay = if cmp_u256(&repay_amount_wad, &abs_debt).is_lt() {
        repay_amount_wad
    } else {
        abs_debt
    };

    let bonus_bps = compute_liquidation_bonus_bps(assets[d_idx].mm_bps);
    let bonus_factor = BPS_DENOM_U64 + u64::from(bonus_bps);

    let mut quote_repay_wad = U256::ZERO;
    let mut raw_seize = U256::ZERO;
    mul_div_ref(
        &capped_repay,
        &assets[d_idx].mark_price_wad,
        &assets[c_idx].mark_price_wad,
        false,
        &mut quote_repay_wad,
    )?;
    mul_u64_div_u64_ref(
        &quote_repay_wad,
        bonus_factor,
        BPS_DENOM_U64,
        false,
        &mut raw_seize,
    )?;

    let (actual_repay, actual_seize) = if cmp_u256(&raw_seize, &avail_coll).is_gt() {
        let mut max_quote = U256::ZERO;
        let mut back_repay = U256::ZERO;
        mul_u64_div_u64_ref(
            &avail_coll,
            BPS_DENOM_U64,
            bonus_factor,
            false,
            &mut max_quote,
        )?;
        mul_div_ref(
            &max_quote,
            &assets[c_idx].mark_price_wad,
            &assets[d_idx].mark_price_wad,
            false,
            &mut back_repay,
        )?;
        let rep = if cmp_u256(&capped_repay, &back_repay).is_lt() {
            capped_repay
        } else {
            back_repay
        };
        (rep, avail_coll)
    } else {
        (capped_repay, raw_seize)
    };

    if actual_seize.is_zero() || cmp_u256(&actual_repay, &min_lot).is_lt() {
        return Err(ClearingError::InvalidIntent);
    }

    let mut repay_i = I256::ZERO;
    let mut seize_i = I256::ZERO;
    u2i_ref(&actual_repay, &mut repay_i)?;
    u2i_ref(&actual_seize, &mut seize_i)?;

    if cmp_i256(&liquidator_balances[d_idx], &repay_i).is_lt() {
        return Err(ClearingError::InsufficientWithdrawableBalance);
    }

    let mut post_u = underwater_balances.to_vec();
    let mut post_l = liquidator_balances.to_vec();

    iadd_assign(&mut post_u[d_idx], &repay_i)?;
    isub_assign(&mut post_u[c_idx], &seize_i)?;
    isub_assign(&mut post_l[d_idx], &repay_i)?;
    iadd_assign(&mut post_l[c_idx], &seize_i)?;

    let mut post_u_risk = AccountRiskMetrics::default();
    let mut post_l_risk = AccountRiskMetrics::default();
    evaluate_account_risk_into(&post_u, assets, &mut post_u_risk)?;
    evaluate_account_risk_into(&post_l, assets, &mut post_l_risk)?;

    let coll_exhausted = post_u[c_idx].is_zero();
    let health_ok = if coll_exhausted {
        cmp_i256(&post_u_risk.health_wad, &pre_u_risk.health_wad).is_ge()
            && cmp_u256(&post_u_risk.total_liability_wad, &pre_u_risk.total_liability_wad).is_lt()
    } else {
        cmp_i256(&post_u_risk.health_wad, &pre_u_risk.health_wad).is_gt()
    };
    if !health_ok {
        return Err(ClearingError::HealthMonotonicityViolated);
    }
    if post_l_risk.im_surplus_wad.is_negative() {
        return Err(ClearingError::InsufficientInitialMargin);
    }

    Ok(LiquidationOutcome {
        repaid_debt_wad: actual_repay,
        seized_collateral_wad: actual_seize,
        post_underwater_balances: post_u,
        post_liquidator_balances: post_l,
    })
}

#[inline(never)]
#[allow(clippy::too_many_arguments)]
pub fn execute_raw_clearing_batch<V: SignatureVerifier>(
    batch_epoch: u64,
    block_timestamp: u64,
    max_price_staleness: u64,
    max_price_deviation_bps: u16,
    chain_id: u64,
    verifying_contract: Address,
    caller: Address,
    assets: Vec<AssetRiskConfig>,
    account_addresses: &[Address],
    mut flat_bals: Vec<I256>,
    confirmed_obligations: FlatMap<(u16, u16, u8), U256>,
    raw_obligations: &[RawObligationDto],
    raw_intents: &[RawTradeIntentDto],
    nonce_bitmaps: FlatMap<(u16, U256), U256>,
    verifier: &V,
) -> Result<SettlementReceipt, ClearingError> {
    let num_assets = assets.len();
    let num_accounts = account_addresses.len();

    if num_assets == 0
        || num_assets > MAX_ASSETS
        || num_accounts == 0
        || num_accounts > MAX_ACCOUNTS
        || raw_obligations.len() > MAX_OBLIGATIONS
        || raw_intents.len() > MAX_INTENTS
        || u64::from(max_price_deviation_bps) > BPS_DENOM_U64
    {
        return Err(ClearingError::BatchCapacityExceeded);
    }
    if flat_bals.len() != num_accounts * num_assets {
        return Err(ClearingError::InvalidAssetConfig);
    }

    validate_asset_configs_selective(&assets, 0, block_timestamp, max_price_staleness)?;

    let mut active_mask = 0u16;
    for (i, &addr) in account_addresses.iter().enumerate() {
        if addr.is_zero() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        if account_addresses[..i].contains(&addr) {
            return Err(ClearingError::DuplicateParticipant);
        }
        for a in 0..num_assets {
            if !flat_bals[i * num_assets + a].is_zero() {
                active_mask |= 1u16 << a;
            }
        }
    }

    for ob in raw_obligations {
        if usize::from(ob.asset_id) < num_assets {
            active_mask |= 1u16 << ob.asset_id;
        }
    }
    for it in raw_intents {
        if usize::from(it.base_asset) < num_assets {
            active_mask |= 1u16 << it.base_asset;
        }
        if usize::from(it.quote_asset) < num_assets {
            active_mask |= 1u16 << it.quote_asset;
        }
    }
    if active_mask == 0 {
        active_mask = 1;
    }
    validate_asset_configs_selective(&assets, active_mask, block_timestamp, max_price_staleness)?;

    let mut work_bitmaps = nonce_bitmaps;
    let mut work_confirmed = confirmed_obligations;
    let domain_sep = compute_domain_separator_with(verifier, chain_id, verifying_contract);

    let mut verified_edges = Vec::with_capacity(raw_obligations.len());
    let mut touched_mask: u64 = 0;
    let mut risk_mask: u64 = 0;

    for ob in raw_obligations {
        let u = usize::from(ob.debtor);
        let v = usize::from(ob.creditor);
        let a = usize::from(ob.asset_id);
        if u >= num_accounts
            || v >= num_accounts
            || u == v
            || a >= num_assets
            || ob.amount_wad.is_zero()
        {
            return Err(ClearingError::InvalidObligation);
        }

        match ob.auth_mode {
            0 => {
                let key = (ob.debtor, ob.creditor, ob.asset_id);
                let mut avail = work_confirmed.get(&key).copied().unwrap_or(U256::ZERO);
                if cmp_u256(&ob.amount_wad, &avail).is_gt() {
                    return Err(ClearingError::UnauthorizedObligation);
                }
                usub_assign(&mut avail, &ob.amount_wad)?;
                work_confirmed.insert(key, avail);
            }
            1 => {
                if batch_epoch > ob.max_epoch {
                    return Err(ClearingError::ExpiredIntent);
                }
                consume_account_nonce(&mut work_bitmaps, ob.debtor, &ob.nonce)?;
                if caller != account_addresses[u] {
                    return Err(ClearingError::UnauthorizedObligation);
                }
            }
            2 => {
                if batch_epoch > ob.max_epoch {
                    return Err(ClearingError::ExpiredIntent);
                }
                consume_account_nonce(&mut work_bitmaps, ob.debtor, &ob.nonce)?;
                let digest = compute_obligation_digest_with(
                    verifier,
                    &domain_sep,
                    account_addresses[u],
                    account_addresses[v],
                    ob.asset_id,
                    &ob.amount_wad,
                    ob.max_epoch,
                    &ob.nonce,
                );
                verify_eip712_signature(verifier, digest, account_addresses[u], ob.v, ob.r, ob.s)?;
            }
            _ => return Err(ClearingError::InvalidObligation),
        }

        verified_edges.push(ObligationEdge {
            debtor: ob.debtor,
            creditor: ob.creditor,
            asset_id: ob.asset_id,
            amount_wad: ob.amount_wad,
        });
        touched_mask |= (1u64 << u) | (1u64 << v);
    }

    let min_lot = U256::from(MIN_INTENT_AMOUNT_U64);
    let mut normalized_intents: Vec<NormalizedIntent> = Vec::with_capacity(raw_intents.len());
    let mut staged_bitmaps = work_bitmaps.clone();

    for (idx, raw) in raw_intents.iter().enumerate() {
        let side = match raw.side {
            0 => OrderSide::Buy,
            1 => OrderSide::Sell,
            _ => return Err(ClearingError::InvalidIntent),
        };
        let signed_amt = if raw.signed_amount_wad.is_zero() {
            raw.amount_wad
        } else {
            raw.signed_amount_wad
        };

        let tr = usize::from(raw.trader);
        let b_id = usize::from(raw.base_asset);
        let q_id = usize::from(raw.quote_asset);
        if tr >= num_accounts
            || q_id >= b_id
            || b_id >= num_assets
            || cmp_u256(&raw.amount_wad, &min_lot).is_lt()
            || cmp_u256(&raw.amount_wad, &signed_amt).is_gt()
            || raw.limit_price_wad.is_zero()
        {
            return Err(ClearingError::InvalidIntent);
        }

        for prev_it in &normalized_intents {
            if prev_it.trader == raw.trader
                && prev_it.base_asset == raw.base_asset
                && prev_it.quote_asset == raw.quote_asset
                && prev_it.side != side
            {
                return Err(ClearingError::InvalidIntent);
            }
        }

        if batch_epoch > raw.max_epoch {
            return Err(ClearingError::ExpiredIntent);
        }

        consume_account_nonce(&mut staged_bitmaps, raw.trader, &raw.nonce)?;

        match raw.auth_mode {
            0 => {
                if caller != account_addresses[tr] {
                    return Err(ClearingError::UnauthorizedCaller);
                }
            }
            1 => {
                let digest = compute_trade_intent_digest_with(
                    verifier,
                    &domain_sep,
                    account_addresses[tr],
                    raw.base_asset,
                    raw.quote_asset,
                    side,
                    &signed_amt,
                    &raw.limit_price_wad,
                    raw.max_epoch,
                    &raw.nonce,
                );
                verify_eip712_signature(verifier, digest, account_addresses[tr], raw.v, raw.r, raw.s)?;
            }
            _ => return Err(ClearingError::InvalidIntent),
        }

        normalized_intents.push(NormalizedIntent {
            intent_index: idx,
            trader: raw.trader,
            trader_address: account_addresses[tr],
            base_asset: raw.base_asset,
            quote_asset: raw.quote_asset,
            side,
            amount_wad: raw.amount_wad,
            limit_price_wad: raw.limit_price_wad,
            nonce: raw.nonce,
        });
    }

    let mut pre_sums = Vec::with_capacity(num_assets);
    for _ in 0..num_assets {
        pre_sums.push(I256::ZERO);
    }
    let mut pre_risks = Vec::with_capacity(num_accounts);
    for u in 0..num_accounts {
        let row = &flat_bals[u * num_assets..(u + 1) * num_assets];
        for (ps, b) in pre_sums.iter_mut().zip(row.iter()) {
            iadd_assign(ps, b)?;
        }
        let mut risk = AccountRiskMetrics::default();
        evaluate_account_risk_into(row, &assets, &mut risk)?;
        pre_risks.push(risk);
    }

    let compression = compress_obligation_cycles(account_addresses, num_assets, &verified_edges)?;
    let mut delta_i = I256::ZERO;
    for res_ob in &compression.residual_obligations {
        let u = usize::from(res_ob.debtor);
        let v = usize::from(res_ob.creditor);
        let a = usize::from(res_ob.asset_id);
        u2i_ref(&res_ob.amount_wad, &mut delta_i)?;
        isub_assign(&mut flat_bals[u * num_assets + a], &delta_i)?;
        iadd_assign(&mut flat_bals[v * num_assets + a], &delta_i)?;
        risk_mask |= 1u64 << u;
    }

    let mut fee_vault_deltas = Vec::with_capacity(num_assets);
    for _ in 0..num_assets {
        fee_vault_deltas.push(U256::ZERO);
    }
    let mut auctions = Vec::new();
    let mut total_matched_volume = U256::ZERO;
    let mut intent_fills = Vec::with_capacity(normalized_intents.len());
    for i in 0..normalized_intents.len() {
        intent_fills.push(IntentFill {
            intent_index: i,
            filled_base_wad: U256::ZERO,
            quote_transfer_wad: U256::ZERO,
        });
    }

    let mut indices = Vec::with_capacity(normalized_intents.len());
    let mut base_i256 = I256::ZERO;
    let mut quote_i256 = I256::ZERO;
    for b_idx in 1..num_assets {
        let base_asset = b_idx as u8;
        for q_idx in 0..b_idx {
            let quote_asset = q_idx as u8;
            indices.clear();
            for (i, it) in normalized_intents.iter().enumerate() {
                if it.base_asset == base_asset && it.quote_asset == quote_asset {
                    indices.push(i);
                }
            }
            if indices.is_empty() {
                continue;
            }
            let (report, executions) = clear_single_market_auction(
                base_asset,
                quote_asset,
                &assets[b_idx].mark_price_wad,
                &assets[q_idx].mark_price_wad,
                max_price_deviation_bps,
                &indices,
                &normalized_intents,
            )?;

            for (intent_pos, side, fill_base, quote_xfer) in executions {
                let norm_it = &normalized_intents[intent_pos];
                let raw_it = &raw_intents[intent_pos];
                let tr = usize::from(norm_it.trader);
                if raw_it.auth_mode == 0 || cmp_u256(&fill_base, &norm_it.amount_wad).is_eq() {
                    consume_account_nonce(&mut work_bitmaps, norm_it.trader, &norm_it.nonce)?;
                }

                u2i_ref(&fill_base, &mut base_i256)?;
                u2i_ref(&quote_xfer, &mut quote_i256)?;
                match side {
                    OrderSide::Buy => {
                        iadd_assign(&mut flat_bals[tr * num_assets + b_idx], &base_i256)?;
                        isub_assign(&mut flat_bals[tr * num_assets + q_idx], &quote_i256)?;
                    }
                    OrderSide::Sell => {
                        isub_assign(&mut flat_bals[tr * num_assets + b_idx], &base_i256)?;
                        iadd_assign(&mut flat_bals[tr * num_assets + q_idx], &quote_i256)?;
                    }
                }
                intent_fills[intent_pos] = IntentFill {
                    intent_index: intent_pos,
                    filled_base_wad: fill_base,
                    quote_transfer_wad: quote_xfer,
                };
                touched_mask |= 1u64 << tr;
                risk_mask |= 1u64 << tr;
            }

            uadd_assign(&mut total_matched_volume, &report.matched_volume_wad)?;
            uadd_assign(
                &mut fee_vault_deltas[q_idx],
                &report.rounding_dust_quote_wad,
            )?;
            auctions.push(report);
        }
    }

    for (a, fee_delta) in fee_vault_deltas.iter().enumerate() {
        let mut post_sum = I256::ZERO;
        u2i_ref(fee_delta, &mut post_sum)?;
        for u in 0..num_accounts {
            iadd_assign(&mut post_sum, &flat_bals[u * num_assets + a])?;
        }
        if cmp_i256(&pre_sums[a], &post_sum).is_ne() {
            return Err(ClearingError::AssetConservationViolated);
        }
    }

    if verified_edges.is_empty() && total_matched_volume.is_zero() {
        return Err(ClearingError::InvalidIntent);
    }

    #[cfg(not(target_arch = "wasm32"))]
    let mut post_accounts = Vec::with_capacity(num_accounts);
    #[cfg(target_arch = "wasm32")]
    let post_accounts = Vec::new();
    for (u, pre_risk) in pre_risks.iter().enumerate() {
        let work_row = &flat_bals[u * num_assets..(u + 1) * num_assets];
        let mut post_risk = AccountRiskMetrics::default();
        #[cfg(not(target_arch = "wasm32"))]
        evaluate_account_risk_into(work_row, &assets, &mut post_risk)?;
        if (touched_mask & (1u64 << u)) != 0 {
            #[cfg(target_arch = "wasm32")]
            evaluate_account_risk_into(work_row, &assets, &mut post_risk)?;
            let requires_full_im = ((risk_mask & (1u64 << u)) != 0)
                && (!pre_risk.im_surplus_wad.is_negative()
                    || cmp_u256(&post_risk.required_im_wad, &pre_risk.required_im_wad).is_gt()
                    || cmp_u256(
                        &post_risk.total_liability_wad,
                        &pre_risk.total_liability_wad,
                    )
                    .is_gt());

            if requires_full_im && post_risk.im_surplus_wad.is_negative() {
                return Err(ClearingError::InsufficientInitialMargin);
            }

            if (pre_risk.im_surplus_wad.is_negative() || post_risk.im_surplus_wad.is_negative())
                && cmp_i256(&post_risk.net_equity_wad, &pre_risk.net_equity_wad).is_lt()
            {
                return Err(ClearingError::HealthMonotonicityViolated);
            }

            if post_risk.im_surplus_wad.is_negative()
                && (cmp_i256(&post_risk.im_surplus_wad, &pre_risk.im_surplus_wad).is_lt()
                    || cmp_i256(&post_risk.health_wad, &pre_risk.health_wad).is_lt())
            {
                return Err(ClearingError::HealthMonotonicityViolated);
            }
        }
        #[cfg(not(target_arch = "wasm32"))]
        post_accounts.push(ParticipantAccountOutput {
            address: account_addresses[u],
            balances: work_row.to_vec(),
            risk: post_risk,
        });
    }

    Ok(SettlementReceipt {
        batch_epoch,
        cycles_eliminated: compression.cycles_eliminated,
        #[cfg(not(target_arch = "wasm32"))]
        compressed_volume_by_asset: compression.compressed_volume_by_asset,
        #[cfg(target_arch = "wasm32")]
        compressed_volume_by_asset: Vec::new(),
        #[cfg(not(target_arch = "wasm32"))]
        residual_obligations: compression.residual_obligations,
        #[cfg(target_arch = "wasm32")]
        residual_obligations: Vec::new(),
        auctions,
        intent_fills,
        fee_vault_deltas,
        flat_post_balances: flat_bals,
        post_accounts,
        updated_confirmed_obligations: work_confirmed,
        updated_nonce_bitmaps: work_bitmaps,
    })
}

#[cfg(not(target_arch = "wasm32"))]
pub fn execute_clearing_batch<V: SignatureVerifier>(
    input: &BatchClearingInput,
    verifier: &V,
) -> Result<SettlementReceipt, ClearingError> {
    let mut raw_obs = Vec::with_capacity(input.obligations.len());
    for &ob in &input.obligations {
        let (auth_mode, max_epoch, nonce, v, r, s) = match ob.auth {
            ObligationAuth::PreRegisteredLedger => (0, 0, U256::ZERO, 0, B256::ZERO, B256::ZERO),
            ObligationAuth::DirectDebtor { max_epoch, nonce } => {
                (1, max_epoch, nonce, 0, B256::ZERO, B256::ZERO)
            }
            ObligationAuth::Eip712Debtor {
                max_epoch,
                nonce,
                v,
                r,
                s,
            } => (2, max_epoch, nonce, v, r, s),
        };
        raw_obs.push(RawObligationDto {
            debtor: ob.debtor,
            creditor: ob.creditor,
            asset_id: ob.asset_id,
            auth_mode,
            v,
            max_epoch,
            amount_wad: ob.amount_wad,
            nonce,
            r,
            s,
        });
    }

    let mut raw_its = Vec::with_capacity(input.intents.len());
    for &it in &input.intents {
        let side = match it.side {
            OrderSide::Buy => 0,
            OrderSide::Sell => 1,
        };
        let (auth_mode, v, r, s) = match it.witness {
            AuthWitness::DirectCaller => (0, 0, B256::ZERO, B256::ZERO),
            AuthWitness::Eip712Signature { v, r, s } => (1, v, r, s),
        };
        raw_its.push(RawTradeIntentDto {
            trader: it.trader,
            base_asset: it.base_asset,
            quote_asset: it.quote_asset,
            side,
            auth_mode,
            v,
            max_epoch: it.max_epoch,
            amount_wad: it.amount_wad,
            signed_amount_wad: it.amount_wad,
            limit_price_wad: it.limit_price_wad,
            nonce: it.nonce,
            r,
            s,
        });
    }

    execute_raw_clearing_batch(
        input.batch_epoch,
        input.block_timestamp,
        input.max_price_staleness,
        input.max_price_deviation_bps,
        input.chain_id,
        input.verifying_contract,
        input.caller,
        input.assets.clone(),
        &{
            let mut addrs = Vec::with_capacity(input.accounts.len());
            for acc in &input.accounts {
                addrs.push(acc.address);
            }
            addrs
        },
        {
            let na = input.assets.len();
            let mut fb = Vec::with_capacity(input.accounts.len() * na);
            for acc in &input.accounts {
                if acc.balances.len() != na {
                    return Err(ClearingError::InvalidAssetConfig);
                }
                fb.extend_from_slice(&acc.balances);
            }
            fb
        },
        input.confirmed_obligations.clone(),
        &raw_obs,
        &raw_its,
        input.nonce_bitmaps.clone(),
        verifier,
    )
}
