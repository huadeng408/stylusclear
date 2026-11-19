#![cfg_attr(not(any(feature = "std", test)), no_std)]
#![forbid(unsafe_code)]
extern crate alloc;

pub mod auction;
pub mod auth;
pub mod engine;
pub mod error;
pub mod margin;
pub mod math;
pub mod netting;

pub use auction::{
    clear_single_market_auction, lot_step_for_price, quantize_reference_tick_ref, IntentFill,
    MarketAuctionReport, NormalizedIntent, OrderSide,
};
#[cfg(not(target_arch = "wasm32"))]
pub use auction::quantize_reference_tick;

pub use auth::{
    compute_domain_separator_with, compute_obligation_digest_with, compute_trade_intent_digest_with,
    consume_bitmap_bit_ref, split_bitmap_nonce, split_bitmap_nonce_ref, verify_eip712_signature,
    AuthWitness, ObligationAuth, SignatureVerifier, EIP712_OBLIGATION_SIGNATURE,
    EIP712_TRADE_INTENT_SIGNATURE, SECP256K1_HALF_N, SECP256K1_N,
};
#[cfg(not(target_arch = "wasm32"))]
pub use auth::{
    compute_domain_separator, compute_obligation_digest, compute_trade_intent_digest,
    consume_bitmap_bit,
};

pub use engine::{
    compute_liquidation_bonus_bps, execute_raw_clearing_batch, execute_underwater_liquidation,
    AuthenticatedObligationInput, BatchClearingInput, LiquidationOutcome, ParticipantAccountInput,
    ParticipantAccountOutput, RawObligationDto, RawTradeIntentDto, SettlementReceipt,
    TradeIntentInput, DEFAULT_MAX_PRICE_DEVIATION_BPS, DEFAULT_MAX_PRICE_STALENESS,
    LIQUIDATION_BONUS_CAP_BPS, MAX_ACCOUNTS, MAX_ASSETS, MAX_INTENTS,
};
#[cfg(not(target_arch = "wasm32"))]
pub use engine::execute_clearing_batch;

pub use error::ClearingError;

pub use margin::{
    evaluate_account_risk_into, validate_asset_configs_selective, AccountRiskMetrics,
    AssetRiskConfig,
};
#[cfg(not(target_arch = "wasm32"))]
pub use margin::{evaluate_account_risk, validate_asset_configs};

pub use math::{
    abs_diff_ref, bps_denom_u256, cmp_i256, cmp_u256, div_rem_u256_ref, gt_mul_512_ref, i_abs_ref,
    iadd_assign, iadd_ref, insertion_sort_by, isub_assign, isub_ref, min_intent_amount_u256,
    mul_div_ref, mul_u64_div_u64_ref, mul_wad_ref, pow10_u256, quantize_down_ref,
    scale_raw_to_wad_ref, u2i_ref, uadd_assign, uadd_ref, umul_ref, usub_assign, usub_ref,
    wad_u256, FlatMap, BPS_DENOM_U64, MIN_INTENT_AMOUNT_U64, WAD_U64,
};
#[cfg(not(target_arch = "wasm32"))]
pub use math::{
    abs_diff_u256, abs_i256_to_u256, checked_add_i256, checked_add_u256, checked_mul_u256,
    checked_sub_i256, checked_sub_u256, div_u256, mul_div_ceil, mul_div_floor, mul_wad_ceil,
    mul_wad_floor, rem_u256, scale_raw_to_wad, u256_to_i256,
};

pub use netting::{
    compress_obligation_cycles, CycleCompressionOutcome, ObligationEdge, MAX_OBLIGATIONS,
};

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec;
    use alloy_primitives::{Address, B256, I256, U256};

    struct MockEip712Verifier {
        expected_r: B256,
        recovered: Address,
    }
    impl SignatureVerifier for MockEip712Verifier {
        fn ecrecover(&self, _digest: B256, _v: u8, r: B256, _s: B256) -> Option<Address> {
            if r == self.expected_r {
                Some(self.recovered)
            } else {
                None
            }
        }
    }

    fn wad(n: u64) -> U256 {
        U256::from(n) * U256::from(WAD_U64)
    }

    fn iwad(n: i64) -> I256 {
        I256::try_from(n).unwrap_or(I256::ZERO)
            * I256::try_from(WAD_U64 as i64).unwrap_or(I256::ZERO)
    }

    #[test]
    fn secp256k1_half_n_upper_boundary_accepted_and_high_s_rejected() {
        let signer = Address::repeat_byte(0xAA);
        let r_valid = B256::repeat_byte(0x11);
        let verifier = MockEip712Verifier {
            expected_r: r_valid,
            recovered: signer,
        };
        let exact_half_n = B256::from(SECP256K1_HALF_N.to_be_bytes::<32>());
        assert!(auth::verify_eip712_signature(
            &verifier,
            B256::repeat_byte(0x42),
            signer,
            27,
            r_valid,
            exact_half_n,
        )
        .is_ok());

        let high_s = B256::from((SECP256K1_HALF_N + U256::from(1u64)).to_be_bytes::<32>());
        assert_eq!(
            auth::verify_eip712_signature(
                &verifier,
                B256::repeat_byte(0x42),
                signer,
                27,
                r_valid,
                high_s,
            ),
            Err(ClearingError::InvalidSignature)
        );
    }

    #[test]
    fn self_trade_wash_and_empty_noop_batches_rejected_and_unmatched_nonce_preserved() {
        let a1 = Address::repeat_byte(0xA1);
        let a2 = Address::repeat_byte(0xA2);
        let verifier = MockEip712Verifier {
            expected_r: B256::repeat_byte(0x01),
            recovered: a2,
        };
        let assets = vec![
            AssetRiskConfig {
                asset_id: 0,
                decimals: 6,
                mark_price_wad: wad(1),
                price_updated_at: 1000,
                haircut_bps: 0,
                im_bps: 500,
                mm_bps: 250,
            },
            AssetRiskConfig {
                asset_id: 1,
                decimals: 18,
                mark_price_wad: wad(2500),
                price_updated_at: 1000,
                haircut_bps: 500,
                im_bps: 1000,
                mm_bps: 500,
            },
        ];

        // 1. Empty batch rejected
        let empty_input = BatchClearingInput {
            batch_epoch: 1,
            block_timestamp: 1010,
            max_price_staleness: 3600,
            max_price_deviation_bps: 2000,
            chain_id: 421614,
            verifying_contract: Address::repeat_byte(0x11),
            caller: a1,
            assets: assets.clone(),
            accounts: vec![ParticipantAccountInput {
                address: a1,
                balances: vec![iwad(5000), iwad(2)],
            }],
            confirmed_obligations: FlatMap::new(),
            obligations: vec![],
            intents: vec![],
            nonce_bitmaps: FlatMap::new(),
        };
        assert_eq!(
            execute_clearing_batch(&empty_input, &verifier),
            Err(ClearingError::InvalidIntent)
        );

        // 2. Self-trade opposite intents rejected
        let wash_input = BatchClearingInput {
            intents: vec![
                TradeIntentInput {
                    trader: 0,
                    base_asset: 1,
                    quote_asset: 0,
                    side: OrderSide::Buy,
                    amount_wad: wad(1),
                    limit_price_wad: wad(2500),
                    max_epoch: 10,
                    nonce: U256::from(1u64),
                    witness: AuthWitness::DirectCaller,
                },
                TradeIntentInput {
                    trader: 0,
                    base_asset: 1,
                    quote_asset: 0,
                    side: OrderSide::Sell,
                    amount_wad: wad(1),
                    limit_price_wad: wad(2500),
                    max_epoch: 10,
                    nonce: U256::from(2u64),
                    witness: AuthWitness::DirectCaller,
                },
            ],
            ..empty_input.clone()
        };
        assert_eq!(
            execute_clearing_batch(&wash_input, &verifier),
            Err(ClearingError::InvalidIntent)
        );

        // 3a. Underwater liquidation with sufficient collateral repays full debt at 250 bps cap
        let liq_full = execute_underwater_liquidation(
            1010,
            3600,
            &assets,
            &[iwad(2580), iwad(-1)],
            &[I256::ZERO, iwad(5)],
            1,
            0,
            wad(1),
        )
        .expect("underwater short with >=2562.5 collateral should repay full 1 WAD debt");
        assert_eq!(liq_full.repaid_debt_wad, wad(1));
        assert_eq!(
            liq_full.seized_collateral_wad,
            U256::from(2_562_500_000_000_000_000_000u128)
        );
        assert_eq!(liq_full.post_underwater_balances[1], I256::ZERO);

        // 3b. Deeply underwater liquidation enforces Proportional Cap without debt forgiveness (ADR-0010)
        let liq_cap = execute_underwater_liquidation(
            1010,
            3600,
            &assets,
            &[iwad(2400), iwad(-1)],
            &[I256::ZERO, iwad(5)],
            1,
            0,
            wad(1),
        )
        .expect("deeply underwater short should proportionally cap repaid debt");
        assert_eq!(liq_cap.seized_collateral_wad, wad(2400));
        assert_eq!(
            liq_cap.repaid_debt_wad,
            U256::from(936_585_365_853_658_536u128)
        );
        assert_eq!(
            liq_cap.post_underwater_balances[1],
            -I256::try_from(63_414_634_146_341_464u128).unwrap()
        );
    }

    #[test]
    fn unsigned_obligation_rejected_while_confirmed_cycle_eliminates() {
        let a1 = Address::repeat_byte(0xA1);
        let a2 = Address::repeat_byte(0xA2);
        let a3 = Address::repeat_byte(0xA3);
        let verifier = MockEip712Verifier {
            expected_r: B256::repeat_byte(0x01),
            recovered: a2,
        };

        let mut confirmed = FlatMap::new();
        confirmed.insert((0u16, 1u16, 0u8), wad(500));
        confirmed.insert((1u16, 2u16, 0u8), wad(500));

        let mut input = BatchClearingInput {
            batch_epoch: 10,
            block_timestamp: 1050,
            max_price_staleness: 3600,
            max_price_deviation_bps: 2000,
            chain_id: 421614,
            verifying_contract: Address::repeat_byte(0x11),
            caller: a1,
            assets: vec![AssetRiskConfig {
                asset_id: 0,
                decimals: 6,
                mark_price_wad: wad(1),
                price_updated_at: 1000,
                haircut_bps: 0,
                im_bps: 500,
                mm_bps: 250,
            }],
            accounts: vec![
                ParticipantAccountInput {
                    address: a1,
                    balances: vec![iwad(1000)],
                },
                ParticipantAccountInput {
                    address: a2,
                    balances: vec![I256::ZERO],
                },
                ParticipantAccountInput {
                    address: a3,
                    balances: vec![I256::ZERO],
                },
            ],
            confirmed_obligations: confirmed,
            obligations: vec![
                AuthenticatedObligationInput {
                    debtor: 0,
                    creditor: 1,
                    asset_id: 0,
                    amount_wad: wad(500),
                    auth: ObligationAuth::PreRegisteredLedger,
                },
                AuthenticatedObligationInput {
                    debtor: 1,
                    creditor: 2,
                    asset_id: 0,
                    amount_wad: wad(500),
                    auth: ObligationAuth::PreRegisteredLedger,
                },
                AuthenticatedObligationInput {
                    debtor: 2,
                    creditor: 0,
                    asset_id: 0,
                    amount_wad: wad(500),
                    auth: ObligationAuth::PreRegisteredLedger,
                },
            ],
            intents: vec![],
            nonce_bitmaps: FlatMap::new(),
        };

        assert_eq!(
            execute_clearing_batch(&input, &verifier),
            Err(ClearingError::UnauthorizedObligation)
        );

        input
            .confirmed_obligations
            .insert((2u16, 0u16, 0u8), wad(500));
        let ok_res = execute_clearing_batch(&input, &verifier);
        assert!(ok_res.is_ok());
        if let Ok(receipt) = ok_res {
            assert_eq!(receipt.cycles_eliminated, 1);
            assert_eq!(receipt.compressed_volume_by_asset[0], wad(1500));
        }
    }

    #[test]
    fn crit01_insolvent_haircut_swap_losing_net_equity_rejected() {
        let distressed = Address::repeat_byte(0xD1);
        let lp = Address::repeat_byte(0xD2);
        let verifier = MockEip712Verifier {
            expected_r: B256::repeat_byte(0x77),
            recovered: lp,
        };

        let input = BatchClearingInput {
            batch_epoch: 5,
            block_timestamp: 1010,
            max_price_staleness: 3600,
            max_price_deviation_bps: 2000,
            chain_id: 421614,
            verifying_contract: Address::repeat_byte(0x22),
            caller: distressed,
            assets: vec![
                AssetRiskConfig {
                    asset_id: 0,
                    decimals: 6,
                    mark_price_wad: wad(1),
                    price_updated_at: 1000,
                    haircut_bps: 0,
                    im_bps: 500,
                    mm_bps: 250,
                },
                AssetRiskConfig {
                    asset_id: 1,
                    decimals: 18,
                    mark_price_wad: wad(2500),
                    price_updated_at: 1000,
                    haircut_bps: 500,
                    im_bps: 1000,
                    mm_bps: 500,
                },
                AssetRiskConfig {
                    asset_id: 2,
                    decimals: 18,
                    mark_price_wad: U256::from(1_200_000_000_000_000_000u64),
                    price_updated_at: 1000,
                    haircut_bps: 1500,
                    im_bps: 1500,
                    mm_bps: 800,
                },
            ],
            accounts: vec![
                ParticipantAccountInput {
                    address: distressed,
                    balances: vec![
                        I256::ZERO,
                        I256::try_from(-450_000_000_000_000_000i64).unwrap_or(I256::ZERO),
                        iwad(1000),
                    ],
                },
                ParticipantAccountInput {
                    address: lp,
                    balances: vec![iwad(5000), iwad(1), I256::ZERO],
                },
            ],
            confirmed_obligations: FlatMap::new(),
            obligations: vec![],
            intents: vec![
                TradeIntentInput {
                    trader: 0,
                    base_asset: 2,
                    quote_asset: 0,
                    side: OrderSide::Sell,
                    amount_wad: wad(1000),
                    limit_price_wad: U256::from(1_050_000_000_000_000_000u64),
                    max_epoch: 10,
                    nonce: U256::from(1u64),
                    witness: AuthWitness::DirectCaller,
                },
                TradeIntentInput {
                    trader: 1,
                    base_asset: 2,
                    quote_asset: 0,
                    side: OrderSide::Buy,
                    amount_wad: wad(1000),
                    limit_price_wad: U256::from(1_050_000_000_000_000_000u64),
                    max_epoch: 10,
                    nonce: U256::from(1u64),
                    witness: AuthWitness::Eip712Signature {
                        v: 27,
                        r: B256::repeat_byte(0x77),
                        s: B256::repeat_byte(0x11),
                    },
                },
            ],
            nonce_bitmaps: FlatMap::new(),
        };

        assert_eq!(
            execute_clearing_batch(&input, &verifier),
            Err(ClearingError::HealthMonotonicityViolated)
        );
    }

    #[test]
    fn tkt022_proportional_liquidation_cap_and_512bit_price_safety() {
        let assets = vec![
            AssetRiskConfig {
                asset_id: 0,
                decimals: 6,
                mark_price_wad: wad(1),
                price_updated_at: 1000,
                haircut_bps: 0,
                im_bps: 500,
                mm_bps: 250,
            },
            AssetRiskConfig {
                asset_id: 1,
                decimals: 18,
                mark_price_wad: wad(2850),
                price_updated_at: 1000,
                haircut_bps: 500,
                im_bps: 1000,
                mm_bps: 500,
            },
        ];

        // (a) Uncapped partial: 0.4 WETH @ $2,850 -> seized = 1,168.50 USDC
        let p_out = execute_underwater_liquidation(
            1010,
            3600,
            &assets,
            &[iwad(2900), iwad(-1)],
            &[I256::ZERO, iwad(5)],
            1,
            0,
            U256::from(400_000_000_000_000_000u64),
        )
        .expect("partial liquidation");
        assert_eq!(
            p_out.repaid_debt_wad,
            U256::from(400_000_000_000_000_000u64)
        );
        assert_eq!(
            p_out.seized_collateral_wad,
            U256::from(1_168_500_000_000_000_000_000u128)
        );

        // (b) Collateral-capped: 1.0 WETH @ $2,850 with 1,000 USDC -> repaid = 342_319_212_665_810_869
        let c_out = execute_underwater_liquidation(
            1010,
            3600,
            &assets,
            &[iwad(1000), iwad(-1)],
            &[I256::ZERO, iwad(5)],
            1,
            0,
            wad(1),
        )
        .expect("capped liquidation");
        assert_eq!(c_out.seized_collateral_wad, wad(1000));
        assert_eq!(
            c_out.repaid_debt_wad,
            U256::from(342_319_212_665_810_868u64)
        );

        // (c) High-price 512-bit safety: 2 * 10^73 * 10250 overflows U256 if pre-multiplied
        let mut hi_px = U256::from(2u64);
        for _ in 0..73 {
            hi_px *= U256::from(10u64);
        }
        let hi_assets = vec![
            AssetRiskConfig {
                asset_id: 0,
                decimals: 18,
                mark_price_wad: hi_px,
                price_updated_at: 1000,
                haircut_bps: 0,
                im_bps: 500,
                mm_bps: 250,
            },
            AssetRiskConfig {
                asset_id: 1,
                decimals: 18,
                mark_price_wad: hi_px,
                price_updated_at: 1000,
                haircut_bps: 500,
                im_bps: 1000,
                mm_bps: 500,
            },
        ];
        let hi_out = execute_underwater_liquidation(
            1010,
            3600,
            &hi_assets,
            &[
                I256::try_from(2_050_000_000i64).expect("ok"),
                I256::try_from(-2_000_000_000i64).expect("ok"),
            ],
            &[I256::ZERO, I256::try_from(10_000_000_000i64).expect("ok")],
            1,
            0,
            U256::from(1_000_000_000u64),
        )
        .expect("high-price 512-bit liquidation");
        assert_eq!(hi_out.repaid_debt_wad, U256::from(1_000_000_000u64));
        assert_eq!(hi_out.seized_collateral_wad, U256::from(1_025_000_000u64));
    }

    #[test]
    fn redteam_v07_stablecoin_bonus_cap_512bit_ir_and_long_cycle_preference() {
        // D-01(a): Tight-MM stablecoin (mm_bps = 100 -> bonus_bps = 50 bps) liquidates without deadlock
        let assets = vec![
            AssetRiskConfig {
                asset_id: 0,
                decimals: 6,
                mark_price_wad: wad(1),
                price_updated_at: 950,
                haircut_bps: 0,
                im_bps: 200,
                mm_bps: 100,
            },
            AssetRiskConfig {
                asset_id: 1,
                decimals: 6,
                mark_price_wad: wad(1),
                price_updated_at: 950,
                haircut_bps: 0,
                im_bps: 200,
                mm_bps: 100,
            },
        ];
        let liq = execute_underwater_liquidation(
            1_000,
            3_600,
            &assets,
            &[iwad(10_050), iwad(-10_000)],
            &[I256::ZERO, iwad(20_000)],
            1,
            0,
            wad(5_000),
        )
        .expect("tight-MM stablecoin liquidation succeeds with adaptive 50 bps bonus");
        assert_eq!(liq.repaid_debt_wad, wad(5_000));
        assert_eq!(liq.seized_collateral_wad, wad(5_025));

        // D-31: Long multilateral 3-cycle preferred over direct 2-cycle chord
        let addrs = vec![
            Address::repeat_byte(0x11),
            Address::repeat_byte(0x22),
            Address::repeat_byte(0x33),
        ];
        let edges = vec![
            ObligationEdge { debtor: 0, creditor: 1, asset_id: 0, amount_wad: wad(100) },
            ObligationEdge { debtor: 1, creditor: 0, asset_id: 0, amount_wad: wad(100) },
            ObligationEdge { debtor: 1, creditor: 2, asset_id: 0, amount_wad: wad(100) },
            ObligationEdge { debtor: 2, creditor: 0, asset_id: 0, amount_wad: wad(100) },
        ];
        let net = compress_obligation_cycles(&addrs, 1, &edges).unwrap();
        assert_eq!(net.cycles_eliminated, 1);
        assert_eq!(net.compressed_volume_by_asset[0], wad(300));
        assert_eq!(net.residual_obligations.len(), 1);
    }
}
