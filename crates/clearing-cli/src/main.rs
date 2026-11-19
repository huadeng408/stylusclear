use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

use alloy_primitives::{keccak256, Address, B256, I256, U256};
use clearing_core::{
    execute_clearing_batch, AssetRiskConfig, AuthWitness, AuthenticatedObligationInput,
    BatchClearingInput, FlatMap, ObligationAuth, OrderSide, ParticipantAccountInput,
    SignatureVerifier, TradeIntentInput, DEFAULT_MAX_PRICE_DEVIATION_BPS,
    DEFAULT_MAX_PRICE_STALENESS,
};
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use serde::{Deserialize, Serialize};

struct Secp256k1EcrecoverVerifier;

impl SignatureVerifier for Secp256k1EcrecoverVerifier {
    fn ecrecover(&self, digest: B256, v: u8, r: B256, s: B256) -> Option<Address> {
        if v != 27 && v != 28 {
            return None;
        }
        let mut sig_bytes = [0u8; 64];
        sig_bytes[0..32].copy_from_slice(r.as_slice());
        sig_bytes[32..64].copy_from_slice(s.as_slice());
        let sig = Signature::from_slice(&sig_bytes).ok()?;
        let rec_id = RecoveryId::try_from(v - 27).ok()?;
        let vk = VerifyingKey::recover_from_prehash(digest.as_slice(), &sig, rec_id).ok()?;
        let pt = vk.to_encoded_point(false);
        let bytes = pt.as_bytes();
        if bytes.len() != 65 {
            return None;
        }
        let hash = keccak256(&bytes[1..65]);
        Some(Address::from_slice(&hash[12..32]))
    }
}

#[derive(Debug, Deserialize)]
struct JsonAsset {
    asset_id: u8,
    #[serde(default = "default_decimals")]
    decimals: u8,
    mark_price_wad: String,
    #[serde(default)]
    price_updated_at: u64,
    haircut_bps: u16,
    im_bps: u16,
    mm_bps: u16,
}

fn default_decimals() -> u8 {
    18
}

#[derive(Debug, Deserialize)]
struct JsonAccount {
    address: String,
    balances: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct JsonAuth {
    #[serde(default = "default_ledger_mode")]
    mode: String,
    v: Option<u8>,
    r: Option<String>,
    s: Option<String>,
}

fn default_ledger_mode() -> String {
    String::from("LEDGER")
}

#[derive(Debug, Deserialize)]
struct JsonObligation {
    debtor: u16,
    creditor: u16,
    asset_id: u8,
    amount_wad: String,
    #[serde(default)]
    max_epoch: u64,
    #[serde(default = "zero_str")]
    nonce: String,
    #[serde(default)]
    auth: JsonAuth,
}

fn zero_str() -> String {
    String::from("0")
}

#[derive(Debug, Deserialize)]
struct JsonIntent {
    trader: u16,
    base_asset: u8,
    quote_asset: u8,
    side: String,
    amount_wad: String,
    limit_price_wad: String,
    max_epoch: u64,
    nonce: String,
    auth: JsonAuth,
}

#[derive(Debug, Deserialize)]
struct JsonBatch {
    batch_epoch: u64,
    #[serde(default)]
    block_timestamp: u64,
    #[serde(default = "default_staleness")]
    max_price_staleness: u64,
    #[serde(default = "default_dev_bps")]
    max_price_deviation_bps: u16,
    chain_id: u64,
    verifying_contract: String,
    caller: String,
    assets: Vec<JsonAsset>,
    accounts: Vec<JsonAccount>,
    #[serde(default)]
    confirmed_obligations: BTreeMap<String, String>,
    #[serde(default)]
    obligations: Vec<JsonObligation>,
    #[serde(default)]
    intents: Vec<JsonIntent>,
    #[serde(default)]
    nonce_bitmaps: BTreeMap<String, String>,
}

fn default_staleness() -> u64 {
    DEFAULT_MAX_PRICE_STALENESS
}

fn default_dev_bps() -> u16 {
    DEFAULT_MAX_PRICE_DEVIATION_BPS
}

#[derive(Debug, Serialize)]
struct OutResidual {
    debtor: u16,
    creditor: u16,
    asset_id: u8,
    amount_wad: String,
}

#[derive(Debug, Serialize)]
struct OutAuction {
    base_asset: u8,
    quote_asset: u8,
    clearing_price_wad: String,
    matched_volume_wad: String,
    rounding_dust_quote_wad: String,
}

#[derive(Debug, Serialize)]
struct OutFill {
    intent_index: usize,
    filled_base_wad: String,
    quote_transfer_wad: String,
}

#[derive(Debug, Serialize)]
struct OutAccount {
    address: String,
    balances: Vec<String>,
    gross_collateral_wad: String,
    effective_collateral_wad: String,
    total_liability_wad: String,
    required_im_wad: String,
    required_mm_wad: String,
    net_equity_wad: String,
    health_wad: String,
    im_surplus_wad: String,
}

#[derive(Debug, Serialize)]
struct OutReceipt {
    batch_epoch: u64,
    cycles_eliminated: u32,
    compressed_volume_by_asset: BTreeMap<String, String>,
    residual_obligations: Vec<OutResidual>,
    auctions: Vec<OutAuction>,
    intent_fills: Vec<OutFill>,
    fee_vault_deltas: BTreeMap<String, String>,
    post_accounts: Vec<OutAccount>,
    confirmed_obligations: BTreeMap<String, String>,
    nonce_bitmaps: BTreeMap<String, String>,
}

fn parse_u256_dec(s: &str) -> Result<U256, String> {
    U256::from_str_radix(s, 10).map_err(|e| format!("invalid U256 '{s}': {e}"))
}

fn parse_i256_dec(s: &str) -> Result<I256, String> {
    s.parse::<I256>()
        .map_err(|e| format!("invalid I256 '{s}': {e}"))
}

fn parse_address_hex(s: &str) -> Result<Address, String> {
    s.parse::<Address>()
        .map_err(|e| format!("invalid Address '{s}': {e}"))
}

fn run_replay(path: &str) -> Result<(), String> {
    let raw = fs::read_to_string(path).map_err(|e| format!("read {path}: {e}"))?;
    let jb: JsonBatch = serde_json::from_str(&raw).map_err(|e| format!("json parse: {e}"))?;

    let mut assets = Vec::with_capacity(jb.assets.len());
    for a in jb.assets {
        assets.push(AssetRiskConfig {
            asset_id: a.asset_id,
            decimals: a.decimals,
            mark_price_wad: parse_u256_dec(&a.mark_price_wad)?,
            price_updated_at: a.price_updated_at,
            haircut_bps: a.haircut_bps,
            im_bps: a.im_bps,
            mm_bps: a.mm_bps,
        });
    }

    let mut accounts = Vec::with_capacity(jb.accounts.len());
    for acc in jb.accounts {
        let mut bals = Vec::with_capacity(acc.balances.len());
        for b in acc.balances {
            bals.push(parse_i256_dec(&b)?);
        }
        accounts.push(ParticipantAccountInput {
            address: parse_address_hex(&acc.address)?,
            balances: bals,
        });
    }

    let mut confirmed_obligations = FlatMap::new();
    for (k, v) in jb.confirmed_obligations {
        let parts: Vec<&str> = k.split(':').collect();
        if parts.len() != 3 {
            return Err(format!("invalid confirmed_obligations key '{k}'"));
        }
        let du = parts[0].parse::<u16>().map_err(|e| e.to_string())?;
        let cu = parts[1].parse::<u16>().map_err(|e| e.to_string())?;
        let aid = parts[2].parse::<u8>().map_err(|e| e.to_string())?;
        confirmed_obligations.insert((du, cu, aid), parse_u256_dec(&v)?);
    }

    let mut nonce_bitmaps = FlatMap::new();
    for (k, v) in jb.nonce_bitmaps {
        let parts: Vec<&str> = k.split(':').collect();
        if parts.len() != 2 {
            return Err(format!("invalid nonce_bitmaps key '{k}'"));
        }
        let tr = parts[0].parse::<u16>().map_err(|e| e.to_string())?;
        let wp = parse_u256_dec(parts[1])?;
        nonce_bitmaps.insert((tr, wp), parse_u256_dec(&v)?);
    }

    let mut obligations = Vec::with_capacity(jb.obligations.len());
    for ob in jb.obligations {
        let auth = match ob.auth.mode.to_uppercase().as_str() {
            "LEDGER" | "0" => ObligationAuth::PreRegisteredLedger,
            "DIRECT" | "1" => ObligationAuth::DirectDebtor {
                max_epoch: ob.max_epoch,
                nonce: parse_u256_dec(&ob.nonce)?,
            },
            "EIP712" | "2" => {
                let v = ob.auth.v.ok_or("missing obligation sig v")?;
                let r = ob
                    .auth
                    .r
                    .ok_or("missing obligation sig r")?
                    .parse::<B256>()
                    .map_err(|e| e.to_string())?;
                let s = ob
                    .auth
                    .s
                    .ok_or("missing obligation sig s")?
                    .parse::<B256>()
                    .map_err(|e| e.to_string())?;
                ObligationAuth::Eip712Debtor {
                    max_epoch: ob.max_epoch,
                    nonce: parse_u256_dec(&ob.nonce)?,
                    v,
                    r,
                    s,
                }
            }
            other => return Err(format!("unknown obligation auth mode: {other}")),
        };
        obligations.push(AuthenticatedObligationInput {
            debtor: ob.debtor,
            creditor: ob.creditor,
            asset_id: ob.asset_id,
            amount_wad: parse_u256_dec(&ob.amount_wad)?,
            auth,
        });
    }

    let mut intents = Vec::with_capacity(jb.intents.len());
    for it in jb.intents {
        let side = match it.side.to_uppercase().as_str() {
            "BUY" | "0" => OrderSide::Buy,
            "SELL" | "1" => OrderSide::Sell,
            other => return Err(format!("unknown side: {other}")),
        };
        let witness = match it.auth.mode.to_uppercase().as_str() {
            "DIRECT" | "0" => AuthWitness::DirectCaller,
            "EIP712" | "1" => {
                let v = it.auth.v.ok_or("missing sig v")?;
                let r = it
                    .auth
                    .r
                    .ok_or("missing sig r")?
                    .parse::<B256>()
                    .map_err(|e| e.to_string())?;
                let s = it
                    .auth
                    .s
                    .ok_or("missing sig s")?
                    .parse::<B256>()
                    .map_err(|e| e.to_string())?;
                AuthWitness::Eip712Signature { v, r, s }
            }
            other => return Err(format!("unknown auth mode: {other}")),
        };
        intents.push(TradeIntentInput {
            trader: it.trader,
            base_asset: it.base_asset,
            quote_asset: it.quote_asset,
            side,
            amount_wad: parse_u256_dec(&it.amount_wad)?,
            limit_price_wad: parse_u256_dec(&it.limit_price_wad)?,
            max_epoch: it.max_epoch,
            nonce: parse_u256_dec(&it.nonce)?,
            witness,
        });
    }

    let input = BatchClearingInput {
        batch_epoch: jb.batch_epoch,
        block_timestamp: jb.block_timestamp,
        max_price_staleness: jb.max_price_staleness,
        max_price_deviation_bps: jb.max_price_deviation_bps,
        chain_id: jb.chain_id,
        verifying_contract: parse_address_hex(&jb.verifying_contract)?,
        caller: parse_address_hex(&jb.caller)?,
        assets,
        accounts,
        confirmed_obligations,
        obligations,
        intents,
        nonce_bitmaps,
    };

    let receipt = execute_clearing_batch(&input, &Secp256k1EcrecoverVerifier)
        .map_err(|e| format!("{{\"ok\":false,\"error_code\":\"{}\"}}", e.as_str()))?;

    let out = OutReceipt {
        batch_epoch: receipt.batch_epoch,
        cycles_eliminated: receipt.cycles_eliminated,
        compressed_volume_by_asset: receipt
            .compressed_volume_by_asset
            .iter()
            .enumerate()
            .map(|(i, v)| (i.to_string(), v.to_string()))
            .collect(),
        residual_obligations: receipt
            .residual_obligations
            .iter()
            .map(|r| OutResidual {
                debtor: r.debtor,
                creditor: r.creditor,
                asset_id: r.asset_id,
                amount_wad: r.amount_wad.to_string(),
            })
            .collect(),
        auctions: receipt
            .auctions
            .iter()
            .map(|a| OutAuction {
                base_asset: a.base_asset,
                quote_asset: a.quote_asset,
                clearing_price_wad: a.clearing_price_wad.to_string(),
                matched_volume_wad: a.matched_volume_wad.to_string(),
                rounding_dust_quote_wad: a.rounding_dust_quote_wad.to_string(),
            })
            .collect(),
        intent_fills: receipt
            .intent_fills
            .iter()
            .map(|f| OutFill {
                intent_index: f.intent_index,
                filled_base_wad: f.filled_base_wad.to_string(),
                quote_transfer_wad: f.quote_transfer_wad.to_string(),
            })
            .collect(),
        fee_vault_deltas: receipt
            .fee_vault_deltas
            .iter()
            .enumerate()
            .map(|(i, v)| (i.to_string(), v.to_string()))
            .collect(),
        post_accounts: receipt
            .post_accounts
            .iter()
            .map(|acc| OutAccount {
                address: format!("{:#x}", acc.address),
                balances: acc.balances.iter().map(ToString::to_string).collect(),
                gross_collateral_wad: acc.risk.gross_collateral_wad.to_string(),
                effective_collateral_wad: acc.risk.effective_collateral_wad.to_string(),
                total_liability_wad: acc.risk.total_liability_wad.to_string(),
                required_im_wad: acc.risk.required_im_wad.to_string(),
                required_mm_wad: acc.risk.required_mm_wad.to_string(),
                net_equity_wad: acc.risk.net_equity_wad.to_string(),
                health_wad: acc.risk.health_wad.to_string(),
                im_surplus_wad: acc.risk.im_surplus_wad.to_string(),
            })
            .collect(),
        confirmed_obligations: receipt
            .updated_confirmed_obligations
            .iter()
            .map(|((u, v, a), amt)| (format!("{u}:{v}:{a}"), amt.to_string()))
            .collect(),
        nonce_bitmaps: receipt
            .updated_nonce_bitmaps
            .iter()
            .map(|((u, wp), w)| (format!("{u}:{wp}"), w.to_string()))
            .collect(),
    };

    let json = serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?;
    println!("{json}");
    Ok(())
}

fn run_benchmark_report() -> Result<(), String> {
    let report_path = Path::new("docs/benchmarks/gas-comparison-report.md");
    let content = fs::read_to_string(report_path).map_err(|e| {
        format!(
            "failed to read authoritative benchmark report {}: {e}",
            report_path.display()
        )
    })?;
    print!("{content}");
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("benchmark") => match run_benchmark_report() {
            Ok(()) => ExitCode::SUCCESS,
            Err(msg) => {
                eprintln!("{msg}");
                ExitCode::from(1)
            }
        },
        Some("replay") => {
            let Some(path) = args.get(2) else {
                eprintln!("usage: clearing-cli replay <batch.json>");
                return ExitCode::from(2);
            };
            match run_replay(path) {
                Ok(()) => ExitCode::SUCCESS,
                Err(msg) => {
                    eprintln!("{msg}");
                    ExitCode::from(1)
                }
            }
        }
        _ => {
            eprintln!("usage: clearing-cli <benchmark | replay <batch.json>>");
            ExitCode::from(2)
        }
    }
}
