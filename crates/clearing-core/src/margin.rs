use alloy_primitives::{I256, U256};

use crate::error::ClearingError;
use crate::math::{
    cmp_i256, i_abs_ref, isub_ref, mul_u64_div_u64_ref, mul_wad_ref, u2i_ref, uadd_assign,
    BPS_DENOM_U64,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AssetRiskConfig {
    pub asset_id: u8,
    pub decimals: u8,
    pub mark_price_wad: U256,
    pub price_updated_at: u64,
    pub haircut_bps: u16,
    pub im_bps: u16,
    pub mm_bps: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AccountRiskMetrics {
    pub gross_collateral_wad: U256,
    pub effective_collateral_wad: U256,
    pub total_liability_wad: U256,
    pub required_im_wad: U256,
    pub required_mm_wad: U256,
    pub net_equity_wad: I256,
    pub health_wad: I256,
    pub im_surplus_wad: I256,
}

impl Default for AccountRiskMetrics {
    fn default() -> Self {
        Self {
            gross_collateral_wad: U256::ZERO,
            effective_collateral_wad: U256::ZERO,
            total_liability_wad: U256::ZERO,
            required_im_wad: U256::ZERO,
            required_mm_wad: U256::ZERO,
            net_equity_wad: I256::ZERO,
            health_wad: I256::ZERO,
            im_surplus_wad: I256::ZERO,
        }
    }
}

/// Validates structural risk invariants on all assets, and oracle freshness ONLY on `active_mask` (`D-30`).
#[inline(never)]
pub fn validate_asset_configs_selective(
    assets: &[AssetRiskConfig],
    active_mask: u16,
    block_timestamp: u64,
    max_price_staleness: u64,
) -> Result<(), ClearingError> {
    if assets.len() > 16 {
        return Err(ClearingError::BatchCapacityExceeded);
    }
    for (idx, cfg) in assets.iter().enumerate() {
        if usize::from(cfg.asset_id) != idx || cfg.mark_price_wad.is_zero() || cfg.decimals > 18 {
            return Err(ClearingError::InvalidAssetConfig);
        }
        if u64::from(cfg.haircut_bps) >= BPS_DENOM_U64 {
            return Err(ClearingError::InvalidHaircut);
        }
        if cfg.mm_bps < 2 || cfg.mm_bps > cfg.im_bps || u64::from(cfg.im_bps) > BPS_DENOM_U64 {
            return Err(ClearingError::InvalidAssetConfig);
        }
        if (active_mask & (1u16 << idx)) != 0
            && (block_timestamp < cfg.price_updated_at
                || (block_timestamp - cfg.price_updated_at) > max_price_staleness)
        {
            return Err(ClearingError::StaleMarkPrice);
        }
    }
    Ok(())
}

#[cfg(not(target_arch = "wasm32"))]
pub fn validate_asset_configs(
    assets: &[AssetRiskConfig],
    block_timestamp: u64,
    max_price_staleness: u64,
) -> Result<(), ClearingError> {
    validate_asset_configs_selective(assets, u16::MAX, block_timestamp, max_price_staleness)
}

#[inline(never)]
pub fn evaluate_account_risk_into(
    balances: &[I256],
    assets: &[AssetRiskConfig],
    out: &mut AccountRiskMetrics,
) -> Result<(), ClearingError> {
    if balances.len() != assets.len() {
        return Err(ClearingError::InvalidAssetConfig);
    }
    *out = AccountRiskMetrics::default();
    let mut mag = U256::ZERO;
    let mut val = U256::ZERO;
    let mut scaled = U256::ZERO;

    for (bal, cfg) in balances.iter().zip(assets.iter()) {
        let ord = cmp_i256(bal, &I256::ZERO);
        if ord.is_gt() {
            i_abs_ref(bal, &mut mag)?;
            mul_wad_ref(&mag, &cfg.mark_price_wad, false, &mut val)?;
            mul_u64_div_u64_ref(
                &val,
                BPS_DENOM_U64 - u64::from(cfg.haircut_bps),
                BPS_DENOM_U64,
                false,
                &mut scaled,
            )?;
            uadd_assign(&mut out.gross_collateral_wad, &val)?;
            uadd_assign(&mut out.effective_collateral_wad, &scaled)?;
        } else if ord.is_lt() {
            i_abs_ref(bal, &mut mag)?;
            mul_wad_ref(&mag, &cfg.mark_price_wad, true, &mut val)?;
            uadd_assign(&mut out.total_liability_wad, &val)?;

            mul_u64_div_u64_ref(
                &val,
                BPS_DENOM_U64 + u64::from(cfg.im_bps),
                BPS_DENOM_U64,
                true,
                &mut scaled,
            )?;
            uadd_assign(&mut out.required_im_wad, &scaled)?;

            mul_u64_div_u64_ref(
                &val,
                BPS_DENOM_U64 + u64::from(cfg.mm_bps),
                BPS_DENOM_U64,
                true,
                &mut scaled,
            )?;
            uadd_assign(&mut out.required_mm_wad, &scaled)?;
        }
    }

    let mut gross_i = I256::ZERO;
    let mut eff_i = I256::ZERO;
    let mut liab_i = I256::ZERO;
    let mut im_i = I256::ZERO;
    let mut mm_i = I256::ZERO;
    u2i_ref(&out.gross_collateral_wad, &mut gross_i)?;
    u2i_ref(&out.effective_collateral_wad, &mut eff_i)?;
    u2i_ref(&out.total_liability_wad, &mut liab_i)?;
    u2i_ref(&out.required_im_wad, &mut im_i)?;
    u2i_ref(&out.required_mm_wad, &mut mm_i)?;

    isub_ref(&gross_i, &liab_i, &mut out.net_equity_wad)?;
    isub_ref(&eff_i, &mm_i, &mut out.health_wad)?;
    isub_ref(&eff_i, &im_i, &mut out.im_surplus_wad)?;
    Ok(())
}

#[cfg(not(target_arch = "wasm32"))]
pub fn evaluate_account_risk(
    balances: &[I256],
    assets: &[AssetRiskConfig],
) -> Result<AccountRiskMetrics, ClearingError> {
    let mut out = AccountRiskMetrics::default();
    evaluate_account_risk_into(balances, assets, &mut out)?;
    Ok(out)
}
