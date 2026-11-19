#![cfg_attr(not(any(feature = "export-abi", test)), no_std)]
#![cfg_attr(not(any(feature = "export-abi", test)), no_main)]
#![cfg_attr(not(target_arch = "wasm32"), forbid(unsafe_code))]
#![cfg_attr(target_arch = "wasm32", deny(unsafe_code))]
extern crate alloc;

use alloc::vec::Vec;
use alloy_primitives::{Address, B256, I256, U256};
use core::cell::Cell;
use stylus_host_mock::HostEnv;

use clearing_core::{
    abs_diff_ref, cmp_i256, cmp_u256, compute_domain_separator_with, div_rem_u256_ref,
    evaluate_account_risk_into, execute_raw_clearing_batch, execute_underwater_liquidation,
    gt_mul_512_ref, i_abs_ref, iadd_assign, isub_assign, pow10_u256, scale_raw_to_wad_ref,
    split_bitmap_nonce_ref, u2i_ref, uadd_assign, umul_ref, usub_assign, AccountRiskMetrics,
    AssetRiskConfig, ClearingError, FlatMap, RawObligationDto,
    RawTradeIntentDto, SignatureVerifier, BPS_DENOM_U64, DEFAULT_MAX_PRICE_DEVIATION_BPS,
    DEFAULT_MAX_PRICE_STALENESS, MAX_ACCOUNTS, MAX_ASSETS, MAX_INTENTS, MAX_OBLIGATIONS,
};

// Reference custom error definitions (`Seam S4` Rule A5 cross-language audit anchor):
// error MathOverflow();
// error DivisionByZero();
// error InvalidAssetConfig();
// error InvalidHaircut();
// error StaleMarkPrice();
// error BatchCapacityExceeded();
// error DuplicateParticipant();
// error InvalidObligation();
// error UnauthorizedObligation();
// error InvalidIntent();
// error ExpiredIntent();
// error UnauthorizedCaller();
// error InvalidSignature();
// error NonceAlreadyUsed();
// error AssetConservationViolated();
// error LimitPriceViolated();
// error InsufficientInitialMargin();
// error HealthMonotonicityViolated();
// error InsufficientWithdrawableBalance();

pub const ERROR_SELECTORS: [[u8; 4]; 19] = [
    [0x9d, 0x56, 0x5d, 0x4e], // 0: MathOverflow()
    [0x23, 0xd3, 0x59, 0xa3], // 1: DivisionByZero()
    [0x37, 0xcc, 0x15, 0x94], // 2: InvalidAssetConfig()
    [0x34, 0xc8, 0xac, 0xf2], // 3: InvalidHaircut()
    [0x25, 0x70, 0xad, 0x8c], // 4: StaleMarkPrice()
    [0xe7, 0xf4, 0x4e, 0xf6], // 5: BatchCapacityExceeded()
    [0xfb, 0xae, 0x88, 0x05], // 6: DuplicateParticipant()
    [0x7a, 0x9e, 0x2e, 0x8d], // 7: InvalidObligation()
    [0xc8, 0xd3, 0x33, 0x8a], // 8: UnauthorizedObligation()
    [0x7d, 0xb5, 0xcb, 0xbe], // 9: InvalidIntent()
    [0x00, 0x80, 0xad, 0xd4], // 10: ExpiredIntent()
    [0x5c, 0x42, 0x7c, 0xd9], // 11: UnauthorizedCaller()
    [0x8b, 0xaa, 0x57, 0x9f], // 12: InvalidSignature()
    [0x1f, 0xb0, 0x9b, 0x80], // 13: NonceAlreadyUsed()
    [0x12, 0x85, 0x43, 0x35], // 14: AssetConservationViolated()
    [0x40, 0x0a, 0x0e, 0x41], // 15: LimitPriceViolated()
    [0xa1, 0x0a, 0x90, 0x0d], // 16: InsufficientInitialMargin()
    [0x98, 0xc9, 0x6a, 0x2d], // 17: HealthMonotonicityViolated()
    [0x0b, 0x1b, 0xd5, 0x1c], // 18: InsufficientWithdrawableBalance()
];

const SEL_ERC20_TRANSFER: [u8; 4] = [0xa9, 0x05, 0x9c, 0xbb];
const SEL_ERC20_TRANSFER_FROM: [u8; 4] = [0x23, 0xb8, 0x72, 0xdd];
const SEL_ERC20_BALANCE_OF: [u8; 4] = [0x70, 0xa0, 0x82, 0x31];

const MAX_MARK_STEP_BPS: u64 = 5_000; // 50% single-step circuit breaker (`D-32`)


const SEL_INITIALIZE: u32 = 0x400ada75; // initialize(address,bool)
const SEL_CTOR_SNAKE: u32 = 0x6440804c; // stylus_constructor(address,bool)
const SEL_CTOR_CAMEL: u32 = 0xd215709b; // stylusConstructor(address,bool)
const SEL_CTOR_NOARG: u32 = 0x5585258d; // stylus_constructor()
const SEL_TRANSFER_ADMIN: u32 = 0x75829def; // transferAdmin(address)
const SEL_ACCEPT_ADMIN: u32 = 0x0e18b681; // acceptAdmin()
const SEL_PENDING_ADMIN: u32 = 0x26782247; // pendingAdmin()
const SEL_CONFIG_ASSET: u32 = 0x989ac74c; // configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)
const SEL_UPDATE_MARK: u32 = 0x2c9dcae5; // updateMarkPrice(uint8,uint256)
const SEL_SET_RISK: u32 = 0x57a23f08; // setRiskWindows(uint64,uint16,bool)
const SEL_SET_SOLVER: u32 = 0x611f612d; // setApprovedSolver(address,bool)
const SEL_DEPOSIT: u32 = 0xf4d4c9d7; // deposit(uint8,uint256)
const SEL_WITHDRAW: u32 = 0x3f489914; // withdraw(uint8,uint256)
const SEL_REPAY_SUB_DEBT: u32 = 0x53972a58; // repaySubQuantumDebt(uint8)
const SEL_ABSORB_BAD_DEBT: u32 = 0x3d77e931; // absorbBadDebt(address,uint8)
const SEL_SWEEP_DUST: u32 = 0xdb2a4b50; // sweepDustToFeeVault(uint8)
const SEL_SWEEP_FEE: u32 = 0x40d86002; // sweepFeeVault(uint8,address)
const SEL_REG_OB: u32 = 0x017a63c5; // registerObligation(address,uint8,uint256)
const SEL_REVOKE_OB: u32 = 0xfcfff680; // revokeObligation(address,uint8,uint256)
const SEL_INV_NONCES: u32 = 0x2bce68d2; // invalidateNonces(uint256,uint256)
const SEL_LIQUIDATE: u32 = 0x4189b0a9; // liquidate(address,uint8,uint8,uint256)
const SEL_SEED_BAL: u32 = 0xf857677a; // seedAccountBalance(address,uint8,int256)
const SEL_SETTLE_BATCH: u32 = 0xcf36836c; // settleBatch(address[],(uint16,uint16,uint8,uint8,uint8,uint64,uint256,uint256,bytes32,bytes32)[],(uint16,uint8,uint8,uint8,uint8,uint8,uint64,uint256,uint256,uint256,bytes32,bytes32)[])
const SEL_ADMIN: u32 = 0xf851a440; // admin()
const SEL_BENCHMARK_SEEDING: u32 = 0xed80e033; // benchmarkSeedingEnabled()
const SEL_PERM_SOLVER: u32 = 0x215eb331; // permissionlessSolver()
const SEL_MAX_STALE: u32 = 0xc80d36b8; // maxPriceStaleness()
const SEL_MAX_DEV: u32 = 0x79baa1a2; // maxPriceDeviationBps()
const SEL_APPROVED_SOLVERS: u32 = 0x6fb67606; // approvedSolvers(address)
const SEL_ASSET_COUNT: u32 = 0xeafe7a74; // assetCount()
const SEL_CUR_EPOCH: u32 = 0x76671808; // currentEpoch()
const SEL_DOM_SEP: u32 = 0xf698da25; // domainSeparator()
const SEL_GET_BAL: u32 = 0x2ff9b029; // getAccountBalance(address,uint8)
const SEL_GET_OB: u32 = 0x96ef98c7; // getConfirmedObligation(address,address,uint8)
const SEL_GET_FEE: u32 = 0x15c0e80a; // getFeeVault(uint8)
const SEL_GET_VAULT_RAW: u32 = 0xc5a2b21b; // getVaultPhysicalRaw(uint8)
const SEL_GET_NONCE: u32 = 0xc9053b74; // getNonceBitmap(address,uint256)
const SEL_GET_PARTIAL_FILL: u32 = 0xdddf3f6a; // getPartialFill(address,uint256)
const SEL_GET_ASSET_CFG: u32 = 0xe621a64b; // getAssetConfig(uint8)
const SEL_GET_RISK: u32 = 0x27939de8; // getAccountRisk(address)

#[inline(never)]
fn encode_clearing_error(err: ClearingError) -> Vec<u8> {
    ERROR_SELECTORS[err as usize].to_vec()
}

#[inline]
fn is_valid_erc20_return(ret: &[u8]) -> bool {
    ret.is_empty() || (ret.len() == 32 && ret[31] == 1 && ret[..31].iter().all(|&b| b == 0))
}

#[inline]
fn put_slice(dst: &mut [u8], off: usize, src: &[u8]) {
    let mut i = 0;
    while i < src.len() {
        dst[off + i] = src[i];
        i += 1;
    }
}

#[inline]
fn addr_from_prefix(src: &[u8], off: usize) -> Address {
    let mut out = [0u8; 20];
    let mut i = 0;
    while i < 20 {
        out[i] = src[off + i];
        i += 1;
    }
    Address::new(out)
}

#[inline]
fn u64_from_slice(src: &[u8], off: usize) -> u64 {
    let mut b = [0u8; 8];
    let mut i = 0;
    while i < 8 {
        b[i] = src[off + i];
        i += 1;
    }
    u64::from_be_bytes(b)
}

#[inline(never)]
fn u256_be(v: &U256) -> [u8; 32] {
    v.to_be_bytes::<32>()
}

#[inline(never)]
fn i256_be(v: &I256) -> [u8; 32] {
    v.to_be_bytes::<32>()
}

#[inline(never)]
fn u256_from_be(w: &[u8; 32]) -> U256 {
    U256::from_be_bytes(*w)
}

#[inline(never)]
fn i256_from_be(w: &[u8; 32]) -> I256 {
    I256::from_be_bytes(*w)
}

#[inline(never)]
fn word_addr(a: Address) -> [u8; 32] {
    let mut w = [0u8; 32];
    put_slice(&mut w, 12, a.as_slice());
    w
}

#[inline]
fn word_u8(v: u8) -> [u8; 32] {
    word_u64(u64::from(v))
}

#[inline]
fn word_bool(v: bool) -> [u8; 32] {
    word_u64(u64::from(v))
}

#[inline]
fn word_u16(v: u16) -> [u8; 32] {
    word_u64(u64::from(v))
}

#[inline]
fn word_u32(v: u32) -> [u8; 32] {
    word_u64(u64::from(v))
}

#[inline(never)]
fn word_u64(v: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    put_slice(&mut w, 24, &v.to_be_bytes());
    w
}

struct EvmPrecompileVerifier {
    host: HostEnv,
    ecrecover_ink: Cell<u64>,
}

impl SignatureVerifier for EvmPrecompileVerifier {
    #[inline(never)]
    fn ecrecover(&self, digest: B256, v: u8, r: B256, s: B256) -> Option<Address> {
        let mut input = [0u8; 128];
        put_slice(&mut input, 0, digest.as_slice());
        input[63] = v;
        put_slice(&mut input, 64, r.as_slice());
        put_slice(&mut input, 96, s.as_slice());

        let precompile_ecrecover = Address::with_last_byte(0x01);
        let pre_ink = self.host.evm_ink_left();
        let res = self.host.static_call(precompile_ecrecover, &input);
        let post_ink = self.host.evm_ink_left();
        self.ecrecover_ink.set(
            self.ecrecover_ink
                .get()
                .saturating_add(pre_ink.saturating_sub(post_ink)),
        );

        if let Some(ret) = res {
            if ret.len() == 32 {
                let addr = addr_from_prefix(&ret, 12);
                if !addr.is_zero() {
                    return Some(addr);
                }
            }
        }
        None
    }

    #[inline]
    fn keccak256(&self, bytes: &[u8]) -> B256 {
        self.host.native_keccak256(bytes)
    }
}

#[derive(Default)]
pub struct StylusClearingEngine {
    host: HostEnv,
}

const SLOT_HEADER: u8 = 0;
const SLOT_RISK: u8 = 1;
const NS_SOLVERS: u8 = 2;
const NS_ASSETS: u8 = 3;
const NS_BALANCES: u8 = 4;
const NS_OBLIGATIONS: u8 = 5;
const NS_FEES: u8 = 6;
const NS_NONCES: u8 = 7;
const NS_VAULT_RAW: u8 = 8;
const NS_PARTIAL_FILLS: u8 = 9;
const SLOT_PENDING_ADMIN: u8 = 10;

#[derive(Clone, Copy)]
struct AssetRecord {
    token: Address,
    init: bool,
    cfg: AssetRiskConfig,
}

impl StylusClearingEngine {
    #[inline]
    fn vm(&self) -> HostEnv {
        self.host
    }

    #[inline(never)]
    fn check_non_reentrant(&self) -> Result<(), ClearingError> {
        if self.vm().msg_reentrant() {
            return Err(ClearingError::UnauthorizedCaller);
        }
        Ok(())
    }

    #[inline(never)]
    fn sload(&self, key: &[u8; 32]) -> [u8; 32] {
        self.vm().sload(key)
    }

    #[inline(never)]
    fn sstore(&mut self, key: &[u8; 32], val: &[u8; 32]) {
        self.vm().sstore(key, val);
    }

    #[inline(never)]
    fn emit_words(&self, event_sig: &[u8], words: &[[u8; 32]], topics: usize) {
        let topic0 = self.vm().native_keccak256(event_sig).0;
        let total = 32 * (1 + words.len());
        let mut buf = Vec::with_capacity(total);
        buf.extend_from_slice(&topic0);
        for w in words {
            buf.extend_from_slice(w);
        }
        self.vm().emit_log(&buf, topics);
    }

    #[inline(never)]
    fn key_tag_addr_u8(ns: u8, addr: Address, sub: u8) -> [u8; 32] {
        let mut k = [0u8; 32];
        k[0] = ns;
        put_slice(&mut k, 1, addr.as_slice());
        k[21] = sub;
        k
    }

    #[inline]
    fn key_tag_u8_u8(ns: u8, a: u8, b: u8) -> [u8; 32] {
        let mut k = [0u8; 32];
        k[0] = ns;
        k[1] = a;
        k[2] = b;
        k
    }

    #[inline(never)]
    fn read_header(&self) -> (Address, bool, bool, u8, u64) {
        let w = self.sload(&word_u8(SLOT_HEADER));
        (
            addr_from_prefix(&w, 0),
            w[20] != 0,
            w[21] != 0,
            w[22],
            u64_from_slice(&w, 24),
        )
    }

    #[inline(never)]
    fn write_header(
        &mut self,
        admin: Address,
        seeding: bool,
        permissionless: bool,
        asset_count: u8,
        epoch: u64,
    ) {
        let mut w = [0u8; 32];
        put_slice(&mut w, 0, admin.as_slice());
        w[20] = u8::from(seeding);
        w[21] = u8::from(permissionless);
        w[22] = asset_count;
        put_slice(&mut w, 24, &epoch.to_be_bytes());
        self.sstore(&word_u8(SLOT_HEADER), &w);
    }

    #[inline(never)]
    fn require_admin(&self) -> Result<(Address, bool, bool, u8, u64), ClearingError> {
        self.check_non_reentrant()?;
        let h = self.read_header();
        if h.0.is_zero() || self.vm().msg_sender() != h.0 {
            return Err(ClearingError::UnauthorizedCaller);
        }
        Ok(h)
    }

    #[inline(never)]
    fn read_risk_windows(&self) -> (u64, u16) {
        let w = self.sload(&word_u8(SLOT_RISK));
        (u64_from_slice(&w, 16), u16::from_be_bytes([w[30], w[31]]))
    }

    #[inline(never)]
    fn write_risk_windows(&mut self, max_staleness: u64, max_dev_bps: u16) {
        let mut w = [0u8; 32];
        put_slice(&mut w, 16, &max_staleness.to_be_bytes());
        put_slice(&mut w, 30, &max_dev_bps.to_be_bytes());
        self.sstore(&word_u8(SLOT_RISK), &w);
    }

    #[inline(never)]
    fn is_solver(&self, solver: Address) -> bool {
        self.sload(&Self::key_tag_addr_u8(NS_SOLVERS, solver, 0))[31] != 0
    }

    #[inline(never)]
    fn set_solver(&mut self, solver: Address, approved: bool) {
        self.sstore(&Self::key_tag_addr_u8(NS_SOLVERS, solver, 0), &word_bool(approved));
    }

    #[inline(never)]
    fn read_asset(&self, asset_id: u8) -> AssetRecord {
        let mp = u256_from_be(&self.sload(&Self::key_tag_u8_u8(NS_ASSETS, asset_id, 0)));
        let meta = self.sload(&Self::key_tag_u8_u8(NS_ASSETS, asset_id, 1));
        let r = self.sload(&Self::key_tag_u8_u8(NS_ASSETS, asset_id, 2));
        AssetRecord {
            token: addr_from_prefix(&meta, 0),
            init: meta[21] != 0,
            cfg: AssetRiskConfig {
                asset_id,
                decimals: meta[20],
                mark_price_wad: mp,
                price_updated_at: u64_from_slice(&meta, 24),
                haircut_bps: u16::from_be_bytes([r[26], r[27]]),
                im_bps: u16::from_be_bytes([r[28], r[29]]),
                mm_bps: u16::from_be_bytes([r[30], r[31]]),
            },
        }
    }

    #[inline(never)]
    fn write_asset(&mut self, rec: &AssetRecord) {
        let id = rec.cfg.asset_id;
        self.sstore(&Self::key_tag_u8_u8(NS_ASSETS, id, 0), &u256_be(&rec.cfg.mark_price_wad));
        let mut meta = [0u8; 32];
        put_slice(&mut meta, 0, rec.token.as_slice());
        meta[20] = rec.cfg.decimals;
        meta[21] = u8::from(rec.init);
        put_slice(&mut meta, 24, &rec.cfg.price_updated_at.to_be_bytes());
        self.sstore(&Self::key_tag_u8_u8(NS_ASSETS, id, 1), &meta);

        let mut r = [0u8; 32];
        put_slice(&mut r, 26, &rec.cfg.haircut_bps.to_be_bytes());
        put_slice(&mut r, 28, &rec.cfg.im_bps.to_be_bytes());
        put_slice(&mut r, 30, &rec.cfg.mm_bps.to_be_bytes());
        self.sstore(&Self::key_tag_u8_u8(NS_ASSETS, id, 2), &r);
    }

    #[inline(never)]
    fn get_bal(&self, trader: Address, asset_id: u8) -> I256 {
        i256_from_be(&self.sload(&Self::key_tag_addr_u8(NS_BALANCES, trader, asset_id)))
    }

    #[inline(never)]
    fn set_bal(&mut self, trader: Address, asset_id: u8, val: &I256) {
        self.sstore(&Self::key_tag_addr_u8(NS_BALANCES, trader, asset_id), &i256_be(val));
    }

    #[inline(never)]
    fn ob_slot(&self, debtor: Address, creditor: Address, asset_id: u8) -> [u8; 32] {
        let mut buf = [0u8; 42];
        buf[0] = NS_OBLIGATIONS;
        put_slice(&mut buf, 1, debtor.as_slice());
        put_slice(&mut buf, 21, creditor.as_slice());
        buf[41] = asset_id;
        self.vm().native_keccak256(&buf).0
    }

    #[inline(never)]
    fn get_ob(&self, debtor: Address, creditor: Address, asset_id: u8) -> U256 {
        u256_from_be(&self.sload(&self.ob_slot(debtor, creditor, asset_id)))
    }

    #[inline(never)]
    fn set_ob(&mut self, debtor: Address, creditor: Address, asset_id: u8, val: &U256) {
        self.sstore(&self.ob_slot(debtor, creditor, asset_id), &u256_be(val));
    }

    #[inline(never)]
    fn get_u256_u8(&self, ns: u8, asset_id: u8) -> U256 {
        u256_from_be(&self.sload(&Self::key_tag_u8_u8(ns, asset_id, 0)))
    }

    #[inline(never)]
    fn set_u256_u8(&mut self, ns: u8, asset_id: u8, val: &U256) {
        self.sstore(&Self::key_tag_u8_u8(ns, asset_id, 0), &u256_be(val));
    }

    #[inline]
    fn get_fee(&self, asset_id: u8) -> U256 {
        self.get_u256_u8(NS_FEES, asset_id)
    }

    #[inline]
    fn set_fee(&mut self, asset_id: u8, val: &U256) {
        self.set_u256_u8(NS_FEES, asset_id, val);
    }

    #[inline]
    fn get_vault_raw(&self, asset_id: u8) -> U256 {
        self.get_u256_u8(NS_VAULT_RAW, asset_id)
    }

    #[inline]
    fn set_vault_raw(&mut self, asset_id: u8, val: &U256) {
        self.set_u256_u8(NS_VAULT_RAW, asset_id, val);
    }

    #[inline(never)]
    fn addr_u256_slot(&self, ns: u8, trader: Address, word_or_nonce: &U256) -> [u8; 32] {
        let mut buf = [0u8; 53];
        buf[0] = ns;
        put_slice(&mut buf, 1, trader.as_slice());
        put_slice(&mut buf, 21, &u256_be(word_or_nonce));
        self.vm().native_keccak256(&buf).0
    }

    #[inline(never)]
    fn get_addr_u256(&self, ns: u8, trader: Address, k: &U256) -> U256 {
        u256_from_be(&self.sload(&self.addr_u256_slot(ns, trader, k)))
    }

    #[inline(never)]
    fn set_addr_u256(&mut self, ns: u8, trader: Address, k: &U256, val: &U256) {
        self.sstore(&self.addr_u256_slot(ns, trader, k), &u256_be(val));
    }

    #[inline]
    fn get_nonce_word(&self, trader: Address, word_pos: &U256) -> U256 {
        self.get_addr_u256(NS_NONCES, trader, word_pos)
    }

    #[inline]
    fn set_nonce_word(&mut self, trader: Address, word_pos: &U256, val: &U256) {
        self.set_addr_u256(NS_NONCES, trader, word_pos, val);
    }

    #[inline]
    fn get_partial_fill(&self, trader: Address, nonce: &U256) -> U256 {
        self.get_addr_u256(NS_PARTIAL_FILLS, trader, nonce)
    }

    #[inline]
    fn set_partial_fill(&mut self, trader: Address, nonce: &U256, val: &U256) {
        self.set_addr_u256(NS_PARTIAL_FILLS, trader, nonce, val);
    }

    #[inline(never)]
    fn query_erc20_balance(&self, token: Address, owner: Address) -> Option<U256> {
        let mut cd = [0u8; 36];
        put_slice(&mut cd, 0, &SEL_ERC20_BALANCE_OF);
        put_slice(&mut cd, 16, owner.as_slice());
        if let Some(ret) = self.vm().static_call(token, &cd) {
            if ret.len() == 32 {
                let mut w = [0u8; 32];
                put_slice(&mut w, 0, &ret);
                return Some(u256_from_be(&w));
            }
        }
        None
    }

    #[inline(never)]
    fn call_erc20_xfer(
        &self,
        token: Address,
        from: Option<Address>,
        to: Address,
        value: &U256,
    ) -> Result<(), ClearingError> {
        if token.is_zero() || self.vm().account_code_size(token) == 0 {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let res = if let Some(f) = from {
            let mut cd = [0u8; 100];
            put_slice(&mut cd, 0, &SEL_ERC20_TRANSFER_FROM);
            put_slice(&mut cd, 16, f.as_slice());
            put_slice(&mut cd, 48, to.as_slice());
            put_slice(&mut cd, 68, &u256_be(value));
            self.vm().call_zero_value(token, &cd)
        } else {
            let mut cd = [0u8; 68];
            put_slice(&mut cd, 0, &SEL_ERC20_TRANSFER);
            put_slice(&mut cd, 16, to.as_slice());
            put_slice(&mut cd, 36, &u256_be(value));
            self.vm().call_zero_value(token, &cd)
        };
        match res {
            Some(ret) if is_valid_erc20_return(&ret) => Ok(()),
            _ => Err(ClearingError::InvalidAssetConfig),
        }
    }

    #[inline(never)]
    fn load_asset_configs(&self, n_assets: usize) -> Vec<AssetRiskConfig> {
        let mut out = Vec::with_capacity(n_assets);
        for a in 0..n_assets {
            out.push(self.read_asset(a as u8).cfg);
        }
        out
    }

    #[inline(never)]
    fn load_bals_override(
        &self,
        trader: Address,
        n_assets: usize,
        ov_asset: usize,
        ov_val: &I256,
    ) -> Vec<I256> {
        let mut out = Vec::with_capacity(n_assets);
        for a in 0..n_assets {
            if a == ov_asset {
                out.push(*ov_val);
            } else {
                out.push(self.get_bal(trader, a as u8));
            }
        }
        out
    }

    #[inline(never)]
    fn check_post_withdrawal_margin(
        &self,
        sender: Address,
        n_assets: usize,
        asset_id: u8,
        next_bal: &I256,
        check_staleness: bool,
    ) -> Result<(), ClearingError> {
        let asset_cfgs = self.load_asset_configs(n_assets);
        let bals = self.load_bals_override(sender, n_assets, usize::from(asset_id), next_bal);
        let mut post_risk = AccountRiskMetrics::default();
        evaluate_account_risk_into(&bals, &asset_cfgs, &mut post_risk)?;
        if !post_risk.total_liability_wad.is_zero() {
            if check_staleness {
                let block_ts = self.vm().block_timestamp();
                let (max_staleness, _) = self.read_risk_windows();
                for (ac, bal_a) in asset_cfgs.iter().zip(bals.iter()) {
                    if !bal_a.is_zero()
                        && (block_ts < ac.price_updated_at
                            || (block_ts - ac.price_updated_at) > max_staleness)
                    {
                        return Err(ClearingError::StaleMarkPrice);
                    }
                }
            }
            if post_risk.im_surplus_wad.is_negative() {
                return Err(ClearingError::InsufficientInitialMargin);
            }
        }
        Ok(())
    }

    #[inline(never)]
    fn ctor_impl(&mut self, admin: Address, seeding: bool) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let (cur_admin, _, _, _, _) = self.read_header();
        if !cur_admin.is_zero() || admin.is_zero() {
            return Err(ClearingError::UnauthorizedCaller);
        }
        self.write_header(admin, seeding, true, 0, 1);
        self.write_risk_windows(DEFAULT_MAX_PRICE_STALENESS, DEFAULT_MAX_PRICE_DEVIATION_BPS);
        self.set_solver(admin, true);
        Ok(())
    }

    #[inline(never)]
    fn transfer_admin_impl(&mut self, new_admin: Address) -> Result<(), ClearingError> {
        let (cur_admin, _, _, _, _) = self.require_admin()?;
        if new_admin.is_zero() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        self.sstore(&word_u8(SLOT_PENDING_ADMIN), &word_addr(new_admin));
        self.emit_words(
            b"AdminTransferStarted(address,address)" as &[u8],
            &[word_addr(cur_admin), word_addr(new_admin)],
            3,
        );
        Ok(())
    }

    #[inline(never)]
    fn accept_admin_impl(&mut self) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let pending = addr_from_prefix(&self.sload(&word_u8(SLOT_PENDING_ADMIN)), 12);
        let sender = self.vm().msg_sender();
        if pending.is_zero() || sender != pending {
            return Err(ClearingError::UnauthorizedCaller);
        }
        let (old_admin, seeding, permissionless, cur_count, epoch) = self.read_header();
        self.write_header(sender, seeding, permissionless, cur_count, epoch);
        self.sstore(&word_u8(SLOT_PENDING_ADMIN), &[0u8; 32]);
        self.set_solver(old_admin, false);
        self.set_solver(sender, true);
        self.emit_words(
            b"AdminTransferred(address,address)" as &[u8],
            &[word_addr(old_admin), word_addr(sender)],
            3,
        );
        Ok(())
    }

    #[inline(never)]
    #[allow(clippy::too_many_arguments)]
    fn configure_asset_impl(
        &mut self,
        asset_id: u8,
        token: Address,
        decimals: u8,
        mark_price_wad: &U256,
        haircut_bps: u16,
        im_bps: u16,
        mm_bps: u16,
    ) -> Result<(), ClearingError> {
        let (admin, seeding, permissionless, cur_count, epoch) = self.require_admin()?;
        if usize::from(asset_id) >= MAX_ASSETS
            || asset_id > cur_count
            || mark_price_wad.is_zero()
            || decimals > 18
        {
            return Err(ClearingError::InvalidAssetConfig);
        }
        if u64::from(haircut_bps) >= BPS_DENOM_U64 {
            return Err(ClearingError::InvalidHaircut);
        }
        if mm_bps < 2 || mm_bps > im_bps || u64::from(im_bps) > BPS_DENOM_U64 {
            return Err(ClearingError::InvalidAssetConfig);
        }
        if !token.is_zero() && self.vm().account_code_size(token) == 0 {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let now = self.vm().block_timestamp();
        let existing = self.read_asset(asset_id);
        if existing.init {
            if existing.token != token || existing.cfg.decimals != decimals {
                return Err(ClearingError::InvalidAssetConfig);
            }
            if now <= existing.cfg.price_updated_at && *mark_price_wad != existing.cfg.mark_price_wad {
                return Err(ClearingError::InvalidAssetConfig);
            }
            Self::check_mark_step(&existing.cfg.mark_price_wad, mark_price_wad)?;
        } else if !token.is_zero() {
            for p in 0..cur_count {
                if self.read_asset(p).token == token {
                    return Err(ClearingError::InvalidAssetConfig);
                }
            }
        }
        let rec = AssetRecord {
            token,
            init: true,
            cfg: AssetRiskConfig {
                asset_id,
                decimals,
                mark_price_wad: *mark_price_wad,
                price_updated_at: self.vm().block_timestamp(),
                haircut_bps,
                im_bps,
                mm_bps,
            },
        };
        self.write_asset(&rec);
        if asset_id == cur_count {
            self.write_header(admin, seeding, permissionless, cur_count + 1, epoch);
        }
        Ok(())
    }

    #[inline(never)]
    fn check_mark_step(prev: &U256, next: &U256) -> Result<(), ClearingError> {
        let mut diff = U256::ZERO;
        abs_diff_ref(next, prev, &mut diff);
        if gt_mul_512_ref(
            &diff,
            &U256::from(BPS_DENOM_U64),
            prev,
            &U256::from(MAX_MARK_STEP_BPS),
        ) {
            return Err(ClearingError::InvalidAssetConfig);
        }
        Ok(())
    }

    #[inline(never)]
    fn update_mark_impl(&mut self, asset_id: u8, mark_price_wad: &U256) -> Result<(), ClearingError> {
        let (_, _, _, cur_count, _) = self.require_admin()?;
        if asset_id >= cur_count || mark_price_wad.is_zero() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let mut rec = self.read_asset(asset_id);
        let now = self.vm().block_timestamp();
        if now <= rec.cfg.price_updated_at && *mark_price_wad != rec.cfg.mark_price_wad {
            return Err(ClearingError::InvalidAssetConfig);
        }
        Self::check_mark_step(&rec.cfg.mark_price_wad, mark_price_wad)?;
        rec.cfg.mark_price_wad = *mark_price_wad;
        rec.cfg.price_updated_at = now;
        self.write_asset(&rec);
        Ok(())
    }

    #[inline(never)]
    fn set_risk_impl(
        &mut self,
        max_staleness: u64,
        max_dev_bps: u16,
        permissionless: bool,
    ) -> Result<(), ClearingError> {
        let (admin, seeding, _, cur_count, epoch) = self.require_admin()?;
        if max_staleness == 0 || max_dev_bps == 0 || max_dev_bps > 5_000 {
            return Err(ClearingError::InvalidAssetConfig);
        }
        self.write_risk_windows(max_staleness, max_dev_bps);
        self.write_header(admin, seeding, permissionless, cur_count, epoch);
        Ok(())
    }

    #[inline(never)]
    fn set_solver_impl(&mut self, solver: Address, approved: bool) -> Result<(), ClearingError> {
        let (admin, _, _, _, _) = self.require_admin()?;
        if solver.is_zero() || (solver == admin && !approved) {
            return Err(ClearingError::InvalidAssetConfig);
        }
        self.set_solver(solver, approved);
        self.emit_words(b"SolverApprovalUpdated(address,bool)" as &[u8], &[word_addr(solver), word_bool(approved)], 2);
        Ok(())
    }

    #[inline(never)]
    fn transfer_from_checked(&mut self, token: Address, from: Address, raw_amount: &U256) -> Result<U256, ClearingError> {
        let this_addr = self.vm().contract_address();
        let pre_bal = self.query_erc20_balance(token, this_addr);
        self.call_erc20_xfer(token, Some(from), this_addr, raw_amount)?;
        let (Some(pre_b), Some(post_b)) = (pre_bal, self.query_erc20_balance(token, this_addr)) else {
            return Err(ClearingError::InvalidAssetConfig);
        };
        if cmp_u256(&post_b, &pre_b).is_le() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let mut diff = post_b;
        usub_assign(&mut diff, &pre_b)?;
        Ok(diff)
    }

    #[inline(never)]
    fn deposit_impl(&mut self, asset_id: u8, raw_amount: &U256, out: &mut I256) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let (_, _, _, cur_count, _) = self.read_header();
        if asset_id >= cur_count || raw_amount.is_zero() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let rec = self.read_asset(asset_id);
        let sender = self.vm().msg_sender();
        let received_raw = self.transfer_from_checked(rec.token, sender, raw_amount)?;

        let mut wad_u = U256::ZERO;
        scale_raw_to_wad_ref(&received_raw, rec.cfg.decimals, &mut wad_u)?;
        let mut wad_delta = I256::ZERO;
        u2i_ref(&wad_u, &mut wad_delta)?;

        let mut next = self.get_bal(sender, asset_id);
        iadd_assign(&mut next, &wad_delta)?;
        let mut v_raw = self.get_vault_raw(asset_id);
        uadd_assign(&mut v_raw, &received_raw)?;

        self.set_bal(sender, asset_id, &next);
        self.set_vault_raw(asset_id, &v_raw);
        self.emit_words(
            b"CollateralDeposited(address,uint8,uint256,int256)" as &[u8],
            &[word_addr(sender), word_u8(asset_id), u256_be(&received_raw), i256_be(&next)],
            3,
        );
        *out = next;
        Ok(())
    }

    #[inline(never)]
    fn withdraw_impl(&mut self, asset_id: u8, raw_amount: &U256, out: &mut I256) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let (_, _, _, cur_count, _) = self.read_header();
        let n_assets = usize::from(cur_count);
        if usize::from(asset_id) >= n_assets || raw_amount.is_zero() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let rec = self.read_asset(asset_id);
        if rec.token.is_zero() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let mut wad_u = U256::ZERO;
        scale_raw_to_wad_ref(raw_amount, rec.cfg.decimals, &mut wad_u)?;
        let mut wad_delta = I256::ZERO;
        u2i_ref(&wad_u, &mut wad_delta)?;

        let sender = self.vm().msg_sender();
        let mut next = self.get_bal(sender, asset_id);
        if cmp_i256(&next, &wad_delta).is_lt() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }

        let mut v_raw = self.get_vault_raw(asset_id);
        if cmp_u256(&v_raw, raw_amount).is_lt() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }
        let Some(live_b) = self.query_erc20_balance(rec.token, self.vm().contract_address()) else {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        };
        if cmp_u256(&live_b, raw_amount).is_lt() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }

        isub_assign(&mut next, &wad_delta)?;
        usub_assign(&mut v_raw, raw_amount)?;
        self.check_post_withdrawal_margin(sender, n_assets, asset_id, &next, true)?;

        self.set_bal(sender, asset_id, &next);
        self.set_vault_raw(asset_id, &v_raw);
        self.call_erc20_xfer(rec.token, None, sender, raw_amount)?;
        self.emit_words(
            b"CollateralWithdrawn(address,uint8,uint256,int256)" as &[u8],
            &[word_addr(sender), word_u8(asset_id), u256_be(raw_amount), i256_be(&next)],
            3,
        );
        *out = next;
        Ok(())
    }

    #[inline(never)]
    fn repay_sub_quantum_debt_impl(&mut self, asset_id: u8, out: &mut I256) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let (_, _, _, cur_count, _) = self.read_header();
        if asset_id >= cur_count {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let rec = self.read_asset(asset_id);
        let quantum_wad = pow10_u256(18 - rec.cfg.decimals)?;
        let sender = self.vm().msg_sender();
        let cur = self.get_bal(sender, asset_id);
        if !cur.is_negative() {
            return Err(ClearingError::InvalidIntent);
        }
        let mut abs_debt = U256::ZERO;
        i_abs_ref(&cur, &mut abs_debt)?;
        if cmp_u256(&abs_debt, &quantum_wad).is_ge() {
            return Err(ClearingError::InvalidIntent);
        }

        let one_raw = U256::from(1u64);
        let received_raw = self.transfer_from_checked(rec.token, sender, &one_raw)?;

        let mut add_wad = U256::ZERO;
        umul_ref(&received_raw, &quantum_wad, &mut add_wad)?;
        let mut q_i = I256::ZERO;
        u2i_ref(&add_wad, &mut q_i)?;
        let mut next = cur;
        iadd_assign(&mut next, &q_i)?;
        let mut v_raw = self.get_vault_raw(asset_id);
        uadd_assign(&mut v_raw, &received_raw)?;

        self.set_bal(sender, asset_id, &next);
        self.set_vault_raw(asset_id, &v_raw);
        self.emit_words(
            b"SubQuantumDebtRepaid(address,uint8,uint256,int256)" as &[u8],
            &[word_addr(sender), word_u8(asset_id), u256_be(&received_raw), i256_be(&next)],
            3,
        );
        *out = next;
        Ok(())
    }

    #[inline(never)]
    fn absorb_bad_debt_impl(
        &mut self,
        underwater: Address,
        debt_asset: u8,
        absorbed_out: &mut U256,
    ) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let (admin, _, _, cur_count, _) = self.read_header();
        let n_assets = usize::from(cur_count);
        if underwater.is_zero() || usize::from(debt_asset) >= n_assets {
            return Err(ClearingError::InvalidAssetConfig);
        }
        for a in 0..n_assets {
            if self.get_bal(underwater, a as u8).is_positive() {
                return Err(ClearingError::InvalidIntent);
            }
        }
        let d_bal = self.get_bal(underwater, debt_asset);
        if !d_bal.is_negative() {
            return Err(ClearingError::InvalidIntent);
        }
        let mut abs_debt = U256::ZERO;
        i_abs_ref(&d_bal, &mut abs_debt)?;

        let caller = self.vm().msg_sender();
        let mut fee_bal = self.get_fee(debt_asset);
        if cmp_u256(&fee_bal, &abs_debt).is_ge() {
            usub_assign(&mut fee_bal, &abs_debt)?;
            self.set_fee(debt_asset, &fee_bal);
        } else if caller == admin {
            let mut rem = abs_debt;
            usub_assign(&mut rem, &fee_bal)?;
            self.set_fee(debt_asset, &U256::ZERO);
            let mut rem_i = I256::ZERO;
            u2i_ref(&rem, &mut rem_i)?;
            let mut a_bal = self.get_bal(admin, debt_asset);
            if cmp_i256(&a_bal, &rem_i).is_lt() {
                return Err(ClearingError::InsufficientWithdrawableBalance);
            }
            isub_assign(&mut a_bal, &rem_i)?;
            self.check_post_withdrawal_margin(admin, n_assets, debt_asset, &a_bal, true)?;
            self.set_bal(admin, debt_asset, &a_bal);
        } else {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }

        self.set_bal(underwater, debt_asset, &I256::ZERO);
        self.emit_words(
            b"BadDebtAbsorbed(address,address,uint8,uint256)" as &[u8],
            &[word_addr(caller), word_addr(underwater), word_u8(debt_asset), u256_be(&abs_debt)],
            4,
        );
        *absorbed_out = abs_debt;
        Ok(())
    }

    #[inline(never)]
    fn sweep_dust_impl(&mut self, asset_id: u8, dust_out: &mut U256) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let (_, _, _, cur_count, _) = self.read_header();
        let n_assets = usize::from(cur_count);
        if usize::from(asset_id) >= n_assets {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let rec = self.read_asset(asset_id);
        if rec.cfg.decimals >= 18 {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }
        let quantum_wad = pow10_u256(18 - rec.cfg.decimals)?;
        let sender = self.vm().msg_sender();
        let cur = self.get_bal(sender, asset_id);
        if !cur.is_positive() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }
        let mut pos_wad = U256::ZERO;
        i_abs_ref(&cur, &mut pos_wad)?;
        let mut q = U256::ZERO;
        div_rem_u256_ref(&pos_wad, &quantum_wad, &mut q, dust_out)?;
        if dust_out.is_zero() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }
        let mut next_u = U256::ZERO;
        umul_ref(&q, &quantum_wad, &mut next_u)?;
        let mut next = I256::ZERO;
        u2i_ref(&next_u, &mut next)?;

        // Enforce staleness + IM margin gate on dust sweep (`D-20`)
        self.check_post_withdrawal_margin(sender, n_assets, asset_id, &next, true)?;

        let mut next_fee = self.get_fee(asset_id);
        uadd_assign(&mut next_fee, dust_out)?;
        self.set_bal(sender, asset_id, &next);
        self.set_fee(asset_id, &next_fee);
        self.emit_words(
            b"SubQuantumDustSwept(address,uint8,uint256)" as &[u8],
            &[word_addr(sender), word_u8(asset_id), u256_be(dust_out)],
            3,
        );
        Ok(())
    }

    #[inline(never)]
    fn sweep_fee_impl(
        &mut self,
        asset_id: u8,
        recipient: Address,
        swept_out: &mut U256,
    ) -> Result<(), ClearingError> {
        let (_, _, _, cur_count, _) = self.require_admin()?;
        if asset_id >= cur_count || recipient.is_zero() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        let rec = self.read_asset(asset_id);
        let avail_wad = self.get_fee(asset_id);
        if avail_wad.is_zero() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }
        if rec.token.is_zero() {
            self.set_fee(asset_id, &U256::ZERO);
            let mut d_i = I256::ZERO;
            u2i_ref(&avail_wad, &mut d_i)?;
            let mut r_bal = self.get_bal(recipient, asset_id);
            iadd_assign(&mut r_bal, &d_i)?;
            self.set_bal(recipient, asset_id, &r_bal);
            self.emit_words(
                b"FeeVaultSwept(address,uint8,uint256,uint256)" as &[u8],
                &[word_addr(recipient), word_u8(asset_id), u256_be(&avail_wad), [0u8; 32]],
                3,
            );
            *swept_out = avail_wad;
            return Ok(());
        }
        let quantum = pow10_u256(18 - rec.cfg.decimals)?;
        let mut raw_amount = U256::ZERO;
        let mut rem_wad = U256::ZERO;
        div_rem_u256_ref(&avail_wad, &quantum, &mut raw_amount, &mut rem_wad)?;
        if raw_amount.is_zero() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }
        let mut v_raw = self.get_vault_raw(asset_id);
        if cmp_u256(&v_raw, &raw_amount).is_lt() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }
        let Some(live_b) = self.query_erc20_balance(rec.token, self.vm().contract_address()) else {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        };
        if cmp_u256(&live_b, &raw_amount).is_lt() {
            return Err(ClearingError::InsufficientWithdrawableBalance);
        }
        usub_assign(&mut v_raw, &raw_amount)?;
        umul_ref(&raw_amount, &quantum, swept_out)?;
        self.set_fee(asset_id, &rem_wad);
        self.set_vault_raw(asset_id, &v_raw);
        self.call_erc20_xfer(rec.token, None, recipient, &raw_amount)?;
        self.emit_words(
            b"FeeVaultSwept(address,uint8,uint256,uint256)" as &[u8],
            &[
                word_addr(recipient),
                word_u8(asset_id),
                u256_be(swept_out),
                u256_be(&raw_amount),
            ],
            3,
        );
        Ok(())
    }

    #[inline(never)]
    fn mutate_ob_impl(
        &mut self,
        creditor: Address,
        asset_id: u8,
        amount_wad: &U256,
        revoke: bool,
        out: &mut U256,
    ) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let (_, _, _, cur_count, _) = self.read_header();
        let debtor = self.vm().msg_sender();
        if creditor.is_zero()
            || creditor == debtor
            || asset_id >= cur_count
            || amount_wad.is_zero()
        {
            return Err(ClearingError::InvalidObligation);
        }
        let mut cur = self.get_ob(debtor, creditor, asset_id);
        let topic = if revoke {
            usub_assign(&mut cur, amount_wad).map_err(|_| ClearingError::InvalidObligation)?;
            b"ObligationRevoked(address,address,uint8,uint256)" as &[u8]
        } else {
            uadd_assign(&mut cur, amount_wad)?;
            b"ObligationRegistered(address,address,uint8,uint256)" as &[u8]
        };
        self.set_ob(debtor, creditor, asset_id, &cur);
        self.emit_words(
            topic,
            &[word_addr(debtor), word_addr(creditor), word_u8(asset_id), u256_be(&cur)],
            4,
        );
        *out = cur;
        Ok(())
    }

    #[inline(never)]
    fn invalidate_nonces_impl(
        &mut self,
        word_pos: &U256,
        mask: &U256,
        out: &mut U256,
    ) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        if mask.is_zero() {
            return Err(ClearingError::InvalidIntent);
        }
        let sender = self.vm().msg_sender();
        let next = self.get_nonce_word(sender, word_pos) | *mask;
        self.set_nonce_word(sender, word_pos, &next);
        self.emit_words(
            b"NoncesInvalidated(address,uint256,uint256)" as &[u8],
            &[word_addr(sender), u256_be(word_pos), u256_be(mask)],
            3,
        );
        *out = next;
        Ok(())
    }

    #[inline(never)]
    fn liquidate_impl(
        &mut self,
        underwater: Address,
        debt_asset: u8,
        collateral_asset: u8,
        repay_amount_wad: &U256,
        repaid_out: &mut U256,
        seized_out: &mut U256,
    ) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let liquidator = self.vm().msg_sender();
        if underwater.is_zero() || underwater == liquidator {
            return Err(ClearingError::InvalidIntent);
        }
        let (_, _, _, cur_count, _) = self.read_header();
        let n_assets = usize::from(cur_count);
        let assets = self.load_asset_configs(n_assets);
        let u_bals = self.load_bals_override(underwater, n_assets, usize::MAX, &I256::ZERO);
        let l_bals = self.load_bals_override(liquidator, n_assets, usize::MAX, &I256::ZERO);
        let (max_staleness, _) = self.read_risk_windows();

        let outcome = execute_underwater_liquidation(
            self.vm().block_timestamp(),
            max_staleness,
            &assets,
            &u_bals,
            &l_bals,
            debt_asset,
            collateral_asset,
            *repay_amount_wad,
        )?;

        let d_idx = usize::from(debt_asset);
        let c_idx = usize::from(collateral_asset);
        self.set_bal(underwater, debt_asset, &outcome.post_underwater_balances[d_idx]);
        self.set_bal(underwater, collateral_asset, &outcome.post_underwater_balances[c_idx]);
        self.set_bal(liquidator, debt_asset, &outcome.post_liquidator_balances[d_idx]);
        self.set_bal(liquidator, collateral_asset, &outcome.post_liquidator_balances[c_idx]);

        self.emit_words(
            b"AccountLiquidated(address,address,uint8,uint8,uint256,uint256)" as &[u8],
            &[
                word_addr(liquidator),
                word_addr(underwater),
                word_u8(debt_asset),
                word_u8(collateral_asset),
                u256_be(&outcome.repaid_debt_wad),
                u256_be(&outcome.seized_collateral_wad),
            ],
            4,
        );
        *repaid_out = outcome.repaid_debt_wad;
        *seized_out = outcome.seized_collateral_wad;
        Ok(())
    }

    #[inline(never)]
    fn seed_bal_impl(&mut self, trader: Address, asset_id: u8, bal: &I256) -> Result<(), ClearingError> {
        let (_, seeding, _, cur_count, _) = self.require_admin()?;
        if !seeding {
            return Err(ClearingError::UnauthorizedCaller);
        }
        if trader.is_zero() || asset_id >= cur_count || !self.read_asset(asset_id).token.is_zero() {
            return Err(ClearingError::InvalidAssetConfig);
        }
        self.set_bal(trader, asset_id, bal);
        Ok(())
    }

    #[inline(never)]
    fn get_risk_impl(&self, trader: Address, out: &mut AccountRiskMetrics) -> Result<(), ClearingError> {
        self.check_non_reentrant()?;
        let (_, _, _, cur_count, _) = self.read_header();
        let n_assets = usize::from(cur_count);
        let assets = self.load_asset_configs(n_assets);
        let bals = self.load_bals_override(trader, n_assets, usize::MAX, &I256::ZERO);
        evaluate_account_risk_into(&bals, &assets, out)
    }

    #[inline(never)]
    fn domain_separator(&self) -> B256 {
        let verifier = EvmPrecompileVerifier {
            host: self.vm(),
            ecrecover_ink: Cell::new(0),
        };
        compute_domain_separator_with(&verifier, self.vm().chain_id(), self.vm().contract_address())
    }

    #[inline(never)]
    fn settle_batch_dto(
        &mut self,
        participants: Vec<Address>,
        raw_obligations: &[RawObligationDto],
        raw_intents: &[RawTradeIntentDto],
        vol_out: &mut U256,
    ) -> Result<u32, ClearingError> {
        self.check_non_reentrant()?;
        let caller = self.vm().msg_sender();
        let (admin, seeding, permissionless, cur_count, batch_epoch) = self.read_header();
        if !permissionless && !self.is_solver(caller) {
            return Err(ClearingError::UnauthorizedCaller);
        }

        let n_assets = usize::from(cur_count);
        if n_assets == 0
            || n_assets > MAX_ASSETS
            || participants.is_empty()
            || participants.len() > MAX_ACCOUNTS
            || raw_obligations.len() > MAX_OBLIGATIONS
            || raw_intents.len() > MAX_INTENTS
        {
            return Err(ClearingError::BatchCapacityExceeded);
        }

        let block_timestamp = self.vm().block_timestamp();
        let (max_price_staleness, max_price_deviation_bps) = self.read_risk_windows();
        let assets = self.load_asset_configs(n_assets);

        let mut flat_bals = Vec::with_capacity(participants.len() * n_assets);
        for &p_addr in &participants {
            for a in 0..n_assets {
                flat_bals.push(self.get_bal(p_addr, a as u8));
            }
        }

        let mut confirmed_map: FlatMap<(u16, u16, u8), U256> = FlatMap::new();
        let mut nonce_bitmaps: FlatMap<(u16, U256), U256> = FlatMap::new();

        for ob in raw_obligations {
            let u = usize::from(ob.debtor);
            let v = usize::from(ob.creditor);
            if u < participants.len()
                && v < participants.len()
                && usize::from(ob.asset_id) < n_assets
                && !participants[u].is_zero()
                && !participants[v].is_zero()
            {
                if ob.auth_mode == 0 {
                    let _ = confirmed_map.ensure_with((ob.debtor, ob.creditor, ob.asset_id), || {
                        self.get_ob(participants[u], participants[v], ob.asset_id)
                    });
                } else if ob.auth_mode == 1 || ob.auth_mode == 2 {
                    let (wp, _) = split_bitmap_nonce_ref(&ob.nonce);
                    let _ = nonce_bitmaps.ensure_with((ob.debtor, wp), || {
                        self.get_nonce_word(participants[u], &wp)
                    });
                }
            }
        }

        let mut adj_intents = Vec::with_capacity(raw_intents.len());
        let mut prior_fills = Vec::with_capacity(raw_intents.len());
        for it in raw_intents {
            let tr = usize::from(it.trader);
            let mut dto = *it;
            dto.signed_amount_wad = it.amount_wad;
            let mut already = U256::ZERO;
            if tr < participants.len() && !participants[tr].is_zero() {
                let (wp, bit) = split_bitmap_nonce_ref(&it.nonce);
                let w_cur = *nonce_bitmaps.ensure_with((it.trader, wp), || {
                    self.get_nonce_word(participants[tr], &wp)
                });
                if it.auth_mode == 1 && ((w_cur >> usize::from(bit)) & U256::from(1u64)).is_zero() {
                    already = self.get_partial_fill(participants[tr], &it.nonce);
                    if !already.is_zero() {
                        if cmp_u256(&already, &it.amount_wad).is_ge() {
                            return Err(ClearingError::NonceAlreadyUsed);
                        }
                        let mut rem = it.amount_wad;
                        usub_assign(&mut rem, &already)?;
                        dto.amount_wad = rem;
                    }
                }
            }
            prior_fills.push(already);
            adj_intents.push(dto);
        }

        let ink_before = self.vm().evm_ink_left();
        let (receipt, ecrecover_ink) = {
            let verifier = EvmPrecompileVerifier {
                host: self.vm(),
                ecrecover_ink: Cell::new(0),
            };
            let rcpt = execute_raw_clearing_batch(
                batch_epoch,
                block_timestamp,
                max_price_staleness,
                max_price_deviation_bps,
                self.vm().chain_id(),
                self.vm().contract_address(),
                caller,
                assets,
                &participants,
                flat_bals,
                confirmed_map,
                raw_obligations,
                &adj_intents,
                nonce_bitmaps,
                &verifier,
            )?;
            (rcpt, verifier.ecrecover_ink.get())
        };
        let ink_after = self.vm().evm_ink_left();
        let wasm_ink_used = ink_before.saturating_sub(ink_after).saturating_sub(ecrecover_ink);
        let stylus_compute_gas = self.vm().ink_to_gas(wasm_ink_used);

        for (u, &p_addr) in participants.iter().enumerate() {
            for a in 0..n_assets {
                let a_u8 = a as u8;
                let next_bal = &receipt.flat_post_balances[u * n_assets + a];
                if cmp_i256(next_bal, &self.get_bal(p_addr, a_u8)).is_ne() {
                    self.set_bal(p_addr, a_u8, next_bal);
                }
            }
        }

        for ((u, v, a_id), next_amt) in &receipt.updated_confirmed_obligations {
            self.set_ob(
                participants[usize::from(*u)],
                participants[usize::from(*v)],
                *a_id,
                next_amt,
            );
        }

        for (a, d) in receipt.fee_vault_deltas.iter().enumerate() {
            if !d.is_zero() {
                let a_u8 = a as u8;
                let mut next = self.get_fee(a_u8);
                uadd_assign(&mut next, d)?;
                self.set_fee(a_u8, &next);
            }
        }

        for ((tr, word_pos), new_word) in &receipt.updated_nonce_bitmaps {
            let p_addr = participants[usize::from(*tr)];
            if cmp_u256(new_word, &self.get_nonce_word(p_addr, word_pos)).is_ne() {
                self.set_nonce_word(p_addr, word_pos, new_word);
            }
        }

        for fill in &receipt.intent_fills {
            if fill.filled_base_wad.is_zero() {
                continue;
            }
            let idx = fill.intent_index;
            let dto = &adj_intents[idx];
            if dto.auth_mode == 1 {
                let tr_addr = participants[usize::from(dto.trader)];
                let prev = prior_fills[idx];
                let mut cum = prev;
                uadd_assign(&mut cum, &fill.filled_base_wad)?;
                let mut rem_signed = dto.signed_amount_wad;
                let done = if cmp_u256(&cum, &dto.signed_amount_wad).is_ge() {
                    true
                } else {
                    usub_assign(&mut rem_signed, &cum)?;
                    cmp_u256(&rem_signed, &U256::from(clearing_core::MIN_INTENT_AMOUNT_U64)).is_lt()
                };
                if done {
                    if !prev.is_zero() {
                        self.set_partial_fill(tr_addr, &dto.nonce, &U256::ZERO);
                    }
                } else {
                    self.set_partial_fill(tr_addr, &dto.nonce, &cum);
                }
            }
        }

        let mut total_matched = U256::ZERO;
        for auc in &receipt.auctions {
            uadd_assign(&mut total_matched, &auc.matched_volume_wad)?;
            if !auc.matched_volume_wad.is_zero() {
                self.emit_words(
                    b"MarketCleared(uint64,uint8,uint8,uint256,uint256,uint256)" as &[u8],
                    &[
                        word_u64(batch_epoch),
                        word_u8(auc.base_asset),
                        word_u8(auc.quote_asset),
                        u256_be(&auc.clearing_price_wad),
                        u256_be(&auc.matched_volume_wad),
                        u256_be(&auc.rounding_dust_quote_wad),
                    ],
                    4,
                );
            }
        }

        let next_epoch = batch_epoch.checked_add(1).ok_or(ClearingError::MathOverflow)?;
        self.write_header(admin, seeding, permissionless, cur_count, next_epoch);
        self.emit_words(
            b"BatchTelemetry(uint64,uint64,uint64)" as &[u8],
            &[
                word_u64(batch_epoch),
                word_u64(wasm_ink_used),
                word_u64(stylus_compute_gas),
            ],
            2,
        );
        self.emit_words(
            b"BatchSettled(uint64,uint32,uint256)" as &[u8],
            &[
                word_u64(batch_epoch),
                word_u32(receipt.cycles_eliminated),
                u256_be(&total_matched),
            ],
            2,
        );
        *vol_out = total_matched;
        Ok(receipt.cycles_eliminated)
    }
}

#[derive(Clone, Copy)]
enum RouteErr {
    UnknownSelector,
    BadAbi,
    Clearing(ClearingError),
}

impl From<ClearingError> for RouteErr {
    #[inline]
    fn from(e: ClearingError) -> Self {
        Self::Clearing(e)
    }
}

struct AbiCursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> AbiCursor<'a> {
    #[inline]
    fn new_exact(buf: &'a [u8], expected: usize) -> Result<Self, RouteErr> {
        if buf.len() != expected {
            return Err(RouteErr::BadAbi);
        }
        Ok(Self { buf, pos: 0 })
    }

    #[inline(never)]
    fn word_at(&self, byte_off: usize, prefix_zeros: usize) -> Result<&'a [u8; 32], RouteErr> {
        let end = byte_off.checked_add(32).ok_or(RouteErr::BadAbi)?;
        let w: &'a [u8; 32] = self
            .buf
            .get(byte_off..end)
            .and_then(|s| s.try_into().ok())
            .ok_or(RouteErr::BadAbi)?;
        for &b in &w[..prefix_zeros] {
            if b != 0 {
                return Err(RouteErr::BadAbi);
            }
        }
        Ok(w)
    }

    #[inline(never)]
    fn next_word(&mut self, prefix_zeros: usize) -> Result<&'a [u8; 32], RouteErr> {
        let w = self.word_at(self.pos, prefix_zeros)?;
        self.pos += 32;
        Ok(w)
    }

    #[inline]
    fn u8(&mut self) -> Result<u8, RouteErr> {
        Ok(self.next_word(31)?[31])
    }

    #[inline]
    fn bool(&mut self) -> Result<bool, RouteErr> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(RouteErr::BadAbi),
        }
    }

    #[inline]
    fn u16(&mut self) -> Result<u16, RouteErr> {
        let w = self.next_word(30)?;
        Ok(u16::from_be_bytes([w[30], w[31]]))
    }

    #[inline]
    fn u64(&mut self) -> Result<u64, RouteErr> {
        let w = self.next_word(24)?;
        Ok(u64_from_slice(w, 24))
    }

    #[inline]
    fn addr(&mut self) -> Result<Address, RouteErr> {
        let w = self.next_word(12)?;
        Ok(addr_from_prefix(w, 12))
    }

    #[inline]
    fn b256(&mut self) -> Result<B256, RouteErr> {
        Ok(B256::new(*self.next_word(0)?))
    }

    #[inline]
    fn u256(&mut self, out: &mut U256) -> Result<(), RouteErr> {
        *out = u256_from_be(self.next_word(0)?);
        Ok(())
    }

    #[inline]
    fn i256(&mut self, out: &mut I256) -> Result<(), RouteErr> {
        *out = i256_from_be(self.next_word(0)?);
        Ok(())
    }

    #[inline(never)]
    fn array_slice(&mut self, elem_bytes: usize) -> Result<(AbiCursor<'a>, usize), RouteErr> {
        let hw = self.next_word(28)?;
        let off = u32::from_be_bytes([hw[28], hw[29], hw[30], hw[31]]) as usize;
        let lw = self.word_at(off, 28)?;
        let len = u32::from_be_bytes([lw[28], lw[29], lw[30], lw[31]]) as usize;
        let base = off.checked_add(32).ok_or(RouteErr::BadAbi)?;
        let total = len.checked_mul(elem_bytes).ok_or(RouteErr::BadAbi)?;
        let end = base.checked_add(total).ok_or(RouteErr::BadAbi)?;
        let sub = self.buf.get(base..end).ok_or(RouteErr::BadAbi)?;
        Ok((AbiCursor { buf: sub, pos: 0 }, len))
    }

    #[inline(never)]
    #[allow(clippy::type_complexity)]
    fn decode_settle_batch(
        &mut self,
    ) -> Result<(Vec<Address>, Vec<RawObligationDto>, Vec<RawTradeIntentDto>), RouteErr> {
        if self.buf.len() < 96 {
            return Err(RouteErr::BadAbi);
        }
        let (mut pc, p_len) = self.array_slice(32)?;
        if p_len == 0 || p_len > MAX_ACCOUNTS {
            return Err(RouteErr::Clearing(ClearingError::BatchCapacityExceeded));
        }
        let mut participants = Vec::with_capacity(p_len);
        for _ in 0..p_len {
            participants.push(pc.addr()?);
        }

        let (mut oc, o_len) = self.array_slice(320)?;
        if o_len > MAX_OBLIGATIONS {
            return Err(RouteErr::Clearing(ClearingError::BatchCapacityExceeded));
        }
        let mut obligations = Vec::with_capacity(o_len);
        let mut amt = U256::ZERO;
        let mut lp = U256::ZERO;
        let mut n = U256::ZERO;
        for _ in 0..o_len {
            let debtor = oc.u16()?;
            let creditor = oc.u16()?;
            let asset_id = oc.u8()?;
            let auth_mode = oc.u8()?;
            let v = oc.u8()?;
            let max_epoch = oc.u64()?;
            oc.u256(&mut amt)?;
            oc.u256(&mut n)?;
            let r = oc.b256()?;
            let s = oc.b256()?;
            obligations.push(RawObligationDto {
                debtor,
                creditor,
                asset_id,
                auth_mode,
                v,
                max_epoch,
                amount_wad: amt,
                nonce: n,
                r,
                s,
            });
        }

        let (mut tc, t_len) = self.array_slice(384)?;
        if t_len > MAX_INTENTS {
            return Err(RouteErr::Clearing(ClearingError::BatchCapacityExceeded));
        }
        let mut intents = Vec::with_capacity(t_len);
        for _ in 0..t_len {
            let trader = tc.u16()?;
            let base_asset = tc.u8()?;
            let quote_asset = tc.u8()?;
            let side = tc.u8()?;
            let auth_mode = tc.u8()?;
            let v = tc.u8()?;
            let max_epoch = tc.u64()?;
            tc.u256(&mut amt)?;
            tc.u256(&mut lp)?;
            tc.u256(&mut n)?;
            let r = tc.b256()?;
            let s = tc.b256()?;
            intents.push(RawTradeIntentDto {
                trader,
                base_asset,
                quote_asset,
                side,
                auth_mode,
                v,
                max_epoch,
                amount_wad: amt,
                signed_amount_wad: amt,
                limit_price_wad: lp,
                nonce: n,
                r,
                s,
            });
        }
        Ok((participants, obligations, intents))
    }
}

pub fn dispatch_call(engine: &mut StylusClearingEngine, calldata: &[u8]) -> Result<Vec<u8>, Vec<u8>> {
    if !engine.vm().msg_value().is_zero() || calldata.len() < 4 {
        return Err(Vec::new());
    }
    let selector = u32::from_be_bytes([calldata[0], calldata[1], calldata[2], calldata[3]]);
    let input = &calldata[4..];
    let mut out = [[0u8; 32]; 7];

    match dispatch_words(engine, selector, input, &mut out) {
        Ok(n) => {
            let mut res = Vec::with_capacity(n * 32);
            for w in &out[..n] {
                res.extend_from_slice(w);
            }
            Ok(res)
        }
        Err(RouteErr::UnknownSelector | RouteErr::BadAbi) => Err(Vec::new()),
        Err(RouteErr::Clearing(e)) => Err(encode_clearing_error(e)),
    }
}

fn dispatch_words(
    storage: &mut StylusClearingEngine,
    selector: u32,
    input: &[u8],
    out: &mut [[u8; 32]; 7],
) -> Result<usize, RouteErr> {
    let mut u0 = U256::ZERO;
    let mut u1 = U256::ZERO;
    let mut i0 = I256::ZERO;

    match selector {
        SEL_INITIALIZE | SEL_CTOR_SNAKE | SEL_CTOR_CAMEL | SEL_CTOR_NOARG => {
            if selector == SEL_CTOR_NOARG {
                let _ = AbiCursor::new_exact(input, 0)?;
                storage.ctor_impl(storage.vm().msg_sender(), false)?;
            } else {
                let mut c = AbiCursor::new_exact(input, 64)?;
                storage.ctor_impl(c.addr()?, c.bool()?)?;
            }
            Ok(0)
        }
        SEL_TRANSFER_ADMIN => {
            let mut c = AbiCursor::new_exact(input, 32)?;
            storage.transfer_admin_impl(c.addr()?)?;
            Ok(0)
        }
        SEL_ACCEPT_ADMIN => {
            let _ = AbiCursor::new_exact(input, 0)?;
            storage.accept_admin_impl()?;
            Ok(0)
        }
        SEL_PENDING_ADMIN => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = word_addr(addr_from_prefix(&storage.sload(&word_u8(SLOT_PENDING_ADMIN)), 12));
            Ok(1)
        }
        SEL_CONFIG_ASSET => {
            let mut c = AbiCursor::new_exact(input, 224)?;
            let aid = c.u8()?;
            let tok = c.addr()?;
            let dec = c.u8()?;
            c.u256(&mut u0)?;
            let hc = c.u16()?;
            let im = c.u16()?;
            let mm = c.u16()?;
            storage.configure_asset_impl(aid, tok, dec, &u0, hc, im, mm)?;
            Ok(0)
        }
        SEL_UPDATE_MARK => {
            let mut c = AbiCursor::new_exact(input, 64)?;
            let aid = c.u8()?;
            c.u256(&mut u0)?;
            storage.update_mark_impl(aid, &u0)?;
            Ok(0)
        }
        SEL_SET_RISK => {
            let mut c = AbiCursor::new_exact(input, 96)?;
            storage.set_risk_impl(c.u64()?, c.u16()?, c.bool()?)?;
            Ok(0)
        }
        SEL_SET_SOLVER => {
            let mut c = AbiCursor::new_exact(input, 64)?;
            storage.set_solver_impl(c.addr()?, c.bool()?)?;
            Ok(0)
        }
        SEL_DEPOSIT | SEL_WITHDRAW => {
            let mut c = AbiCursor::new_exact(input, 64)?;
            let aid = c.u8()?;
            c.u256(&mut u0)?;
            if selector == SEL_DEPOSIT {
                storage.deposit_impl(aid, &u0, &mut i0)?;
            } else {
                storage.withdraw_impl(aid, &u0, &mut i0)?;
            }
            out[0] = i256_be(&i0);
            Ok(1)
        }
        SEL_REPAY_SUB_DEBT => {
            let mut c = AbiCursor::new_exact(input, 32)?;
            storage.repay_sub_quantum_debt_impl(c.u8()?, &mut i0)?;
            out[0] = i256_be(&i0);
            Ok(1)
        }
        SEL_ABSORB_BAD_DEBT => {
            let mut c = AbiCursor::new_exact(input, 64)?;
            storage.absorb_bad_debt_impl(c.addr()?, c.u8()?, &mut u0)?;
            out[0] = u256_be(&u0);
            Ok(1)
        }
        SEL_SWEEP_DUST => {
            let mut c = AbiCursor::new_exact(input, 32)?;
            storage.sweep_dust_impl(c.u8()?, &mut u0)?;
            out[0] = u256_be(&u0);
            Ok(1)
        }
        SEL_SWEEP_FEE => {
            let mut c = AbiCursor::new_exact(input, 64)?;
            storage.sweep_fee_impl(c.u8()?, c.addr()?, &mut u0)?;
            out[0] = u256_be(&u0);
            Ok(1)
        }
        SEL_REG_OB | SEL_REVOKE_OB => {
            let mut c = AbiCursor::new_exact(input, 96)?;
            let cred = c.addr()?;
            let aid = c.u8()?;
            c.u256(&mut u0)?;
            storage.mutate_ob_impl(cred, aid, &u0, selector == SEL_REVOKE_OB, &mut u1)?;
            out[0] = u256_be(&u1);
            Ok(1)
        }
        SEL_INV_NONCES => {
            let mut c = AbiCursor::new_exact(input, 64)?;
            c.u256(&mut u0)?;
            c.u256(&mut u1)?;
            let mut res = U256::ZERO;
            storage.invalidate_nonces_impl(&u0, &u1, &mut res)?;
            out[0] = u256_be(&res);
            Ok(1)
        }
        SEL_LIQUIDATE => {
            let mut c = AbiCursor::new_exact(input, 128)?;
            let uw = c.addr()?;
            let da = c.u8()?;
            let ca = c.u8()?;
            c.u256(&mut u0)?;
            let mut rep = U256::ZERO;
            let mut sz = U256::ZERO;
            storage.liquidate_impl(uw, da, ca, &u0, &mut rep, &mut sz)?;
            out[0] = u256_be(&rep);
            out[1] = u256_be(&sz);
            Ok(2)
        }
        SEL_SEED_BAL => {
            let mut c = AbiCursor::new_exact(input, 96)?;
            let tr = c.addr()?;
            let aid = c.u8()?;
            c.i256(&mut i0)?;
            storage.seed_bal_impl(tr, aid, &i0)?;
            Ok(0)
        }
        SEL_SETTLE_BATCH => {
            let mut c = AbiCursor { buf: input, pos: 0 };
            let (p, o, it) = c.decode_settle_batch()?;
            let cyc = storage.settle_batch_dto(p, &o, &it, &mut u0)?;
            out[0] = word_u32(cyc);
            out[1] = u256_be(&u0);
            Ok(2)
        }
        SEL_ADMIN => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = word_addr(storage.read_header().0);
            Ok(1)
        }
        SEL_BENCHMARK_SEEDING => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = word_bool(storage.read_header().1);
            Ok(1)
        }
        SEL_PERM_SOLVER => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = word_bool(storage.read_header().2);
            Ok(1)
        }
        SEL_MAX_STALE => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = word_u64(storage.read_risk_windows().0);
            Ok(1)
        }
        SEL_MAX_DEV => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = word_u16(storage.read_risk_windows().1);
            Ok(1)
        }
        SEL_APPROVED_SOLVERS => {
            storage.check_non_reentrant()?;
            let mut c = AbiCursor::new_exact(input, 32)?;
            out[0] = word_bool(storage.is_solver(c.addr()?));
            Ok(1)
        }
        SEL_ASSET_COUNT => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = word_u8(storage.read_header().3);
            Ok(1)
        }
        SEL_CUR_EPOCH => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = word_u64(storage.read_header().4);
            Ok(1)
        }
        SEL_DOM_SEP => {
            storage.check_non_reentrant()?;
            let _ = AbiCursor::new_exact(input, 0)?;
            out[0] = storage.domain_separator().0;
            Ok(1)
        }
        SEL_GET_BAL => {
            storage.check_non_reentrant()?;
            let mut c = AbiCursor::new_exact(input, 64)?;
            let tr = c.addr()?;
            let aid = c.u8()?;
            if aid >= storage.read_header().3 {
                return Err(RouteErr::Clearing(ClearingError::InvalidAssetConfig));
            }
            out[0] = i256_be(&storage.get_bal(tr, aid));
            Ok(1)
        }
        SEL_GET_OB => {
            storage.check_non_reentrant()?;
            let mut c = AbiCursor::new_exact(input, 96)?;
            out[0] = u256_be(&storage.get_ob(c.addr()?, c.addr()?, c.u8()?));
            Ok(1)
        }
        SEL_GET_FEE | SEL_GET_VAULT_RAW => {
            storage.check_non_reentrant()?;
            let mut c = AbiCursor::new_exact(input, 32)?;
            let aid = c.u8()?;
            let v = if selector == SEL_GET_FEE {
                storage.get_fee(aid)
            } else {
                storage.get_vault_raw(aid)
            };
            out[0] = u256_be(&v);
            Ok(1)
        }
        SEL_GET_NONCE | SEL_GET_PARTIAL_FILL => {
            storage.check_non_reentrant()?;
            let mut c = AbiCursor::new_exact(input, 64)?;
            let tr = c.addr()?;
            c.u256(&mut u0)?;
            let v = if selector == SEL_GET_NONCE {
                storage.get_nonce_word(tr, &u0)
            } else {
                storage.get_partial_fill(tr, &u0)
            };
            out[0] = u256_be(&v);
            Ok(1)
        }
        SEL_GET_ASSET_CFG => {
            storage.check_non_reentrant()?;
            let mut c = AbiCursor::new_exact(input, 32)?;
            let aid = c.u8()?;
            if aid >= storage.read_header().3 {
                return Err(RouteErr::Clearing(ClearingError::InvalidAssetConfig));
            }
            let rec = storage.read_asset(aid);
            out[0] = word_addr(rec.token);
            out[1] = word_u8(rec.cfg.decimals);
            out[2] = u256_be(&rec.cfg.mark_price_wad);
            out[3] = word_u64(rec.cfg.price_updated_at);
            out[4] = word_u16(rec.cfg.haircut_bps);
            out[5] = word_u16(rec.cfg.im_bps);
            out[6] = word_u16(rec.cfg.mm_bps);
            Ok(7)
        }
        SEL_GET_RISK => {
            let mut c = AbiCursor::new_exact(input, 32)?;
            let mut r = AccountRiskMetrics::default();
            storage.get_risk_impl(c.addr()?, &mut r)?;
            out[0] = u256_be(&r.effective_collateral_wad);
            out[1] = u256_be(&r.total_liability_wad);
            out[2] = u256_be(&r.required_im_wad);
            out[3] = u256_be(&r.required_mm_wad);
            out[4] = i256_be(&r.health_wad);
            out[5] = i256_be(&r.im_surplus_wad);
            Ok(6)
        }
        _ => Err(RouteErr::UnknownSelector),
    }
}

#[cfg(target_arch = "wasm32")]
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn user_entrypoint(len: usize) -> i32 {
    stylus_host_mock::run_wasm_entrypoint(len, |input| {
        let mut engine = StylusClearingEngine::default();
        dispatch_call(&mut engine, input)
    })
}

#[cfg(not(target_arch = "wasm32"))]
pub const SOLIDITY_ABI_SPEC: &str = r#"// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface IStylusClearingEngine {
    struct ObligationInput { uint16 debtor; uint16 creditor; uint8 assetId; uint8 authMode; uint8 v; uint64 maxEpoch; uint256 amountWad; uint256 nonce; bytes32 r; bytes32 s; }
    struct SignedTradeIntent { uint16 trader; uint8 baseAsset; uint8 quoteAsset; uint8 side; uint8 authMode; uint8 v; uint64 maxEpoch; uint256 amountWad; uint256 limitPriceWad; uint256 nonce; bytes32 r; bytes32 s; }
    constructor(address initialAdmin, bool benchmarkSeedingEnabled);
    function initialize(address initialAdmin, bool benchmarkSeedingEnabled) external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;
    function pendingAdmin() external view returns (address);
    function configureAsset(uint8 assetId, address token, uint8 decimals, uint256 markPriceWad, uint16 haircutBps, uint16 imBps, uint16 mmBps) external;
    function updateMarkPrice(uint8 assetId, uint256 markPriceWad) external;
    function setRiskWindows(uint64 maxPriceStalenessSeconds, uint16 maxPriceDeviationBps, bool permissionlessSolverEnabled) external;
    function setApprovedSolver(address solver, bool approved) external;
    function deposit(uint8 assetId, uint256 rawAmount) external returns (int256 newBalanceWad);
    function withdraw(uint8 assetId, uint256 rawAmount) external returns (int256 newBalanceWad);
    function repaySubQuantumDebt(uint8 assetId) external returns (int256 newBalanceWad);
    function absorbBadDebt(address underwater, uint8 debtAsset) external returns (uint256 absorbedWad);
    function sweepDustToFeeVault(uint8 assetId) external returns (uint256 sweptDustWad);
    function sweepFeeVault(uint8 assetId, address recipient) external returns (uint256 sweptWad);
    function registerObligation(address creditor, uint8 assetId, uint256 amountWad) external returns (uint256 totalConfirmedWad);
    function revokeObligation(address creditor, uint8 assetId, uint256 amountWad) external returns (uint256 remainingConfirmedWad);
    function invalidateNonces(uint256 wordPos, uint256 mask) external returns (uint256 updatedWord);
    function liquidate(address underwater, uint8 debtAsset, uint8 collateralAsset, uint256 repayAmountWad) external returns (uint256 repaidDebtWad, uint256 seizedCollateralWad);
    function seedAccountBalance(address trader, uint8 assetId, int256 balanceWad) external;
    function settleBatch(address[] calldata participants, ObligationInput[] calldata obligations, SignedTradeIntent[] calldata intents) external returns (uint32 cyclesEliminated, uint256 totalMatchedVolumeWad);
    function admin() external view returns (address);
    function benchmarkSeedingEnabled() external view returns (bool);
    function permissionlessSolver() external view returns (bool);
    function maxPriceStaleness() external view returns (uint64);
    function maxPriceDeviationBps() external view returns (uint16);
    function approvedSolvers(address solver) external view returns (bool);
    function assetCount() external view returns (uint8);
    function currentEpoch() external view returns (uint64);
    function domainSeparator() external view returns (bytes32);
    function getAccountBalance(address trader, uint8 assetId) external view returns (int256);
    function getConfirmedObligation(address debtor, address creditor, uint8 assetId) external view returns (uint256);
    function getFeeVault(uint8 assetId) external view returns (uint256);
    function getVaultPhysicalRaw(uint8 assetId) external view returns (uint256);
    function getNonceBitmap(address trader, uint256 wordPos) external view returns (uint256);
    function getPartialFill(address trader, uint256 nonce) external view returns (uint256);
    function getAssetConfig(uint8 assetId) external view returns (address token, uint8 decimals, uint256 markPriceWad, uint64 priceUpdatedAt, uint16 haircutBps, uint16 imBps, uint16 mmBps);
    function getAccountRisk(address trader) external view returns (uint256 effectiveCollateralWad, uint256 totalLiabilityWad, uint256 requiredImWad, uint256 requiredMmWad, int256 healthWad, int256 imSurplusWad);
}"#;

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::keccak256;
    use alloy_sol_types::{sol, SolCall, SolError, SolValue};
    use k256::ecdsa::SigningKey;
    use stylus_host_mock::TestVM;

    sol! {
        struct ObligationInput { uint16 debtor; uint16 creditor; uint8 assetId; uint8 authMode; uint8 v; uint64 maxEpoch; uint256 amountWad; uint256 nonce; bytes32 r; bytes32 s; }
        struct SignedTradeIntent { uint16 trader; uint8 baseAsset; uint8 quoteAsset; uint8 side; uint8 authMode; uint8 v; uint64 maxEpoch; uint256 amountWad; uint256 limitPriceWad; uint256 nonce; bytes32 r; bytes32 s; }
        function initialize(address initialAdmin, bool benchmarkSeedingEnabled) external;
        function transferAdmin(address newAdmin) external;
        function acceptAdmin() external;
        function configureAsset(uint8 assetId, address token, uint8 decimals, uint256 markPriceWad, uint16 haircutBps, uint16 imBps, uint16 mmBps) external;
        function updateMarkPrice(uint8 assetId, uint256 markPriceWad) external;
        function deposit(uint8 assetId, uint256 rawAmount) external returns (int256);
        function withdraw(uint8 assetId, uint256 rawAmount) external returns (int256);
        function repaySubQuantumDebt(uint8 assetId) external returns (int256);
        function absorbBadDebt(address underwater, uint8 debtAsset) external returns (uint256);
        function sweepDustToFeeVault(uint8 assetId) external returns (uint256);
        function invalidateNonces(uint256 wordPos, uint256 mask) external returns (uint256);
        function liquidate(address underwater, uint8 debtAsset, uint8 collateralAsset, uint256 repayAmountWad) external returns (uint256, uint256);
        function seedAccountBalance(address trader, uint8 assetId, int256 balanceWad) external;
        function settleBatch(address[] calldata participants, ObligationInput[] calldata obligations, SignedTradeIntent[] calldata intents) external returns (uint32, uint256);
        function domainSeparator() external view returns (bytes32);
        function getPartialFill(address trader, uint256 nonce) external view returns (uint256);
        function balanceOf(address owner) external view returns (uint256);
        function transfer(address to, uint256 value) external returns (bool);
        function transferFrom(address from, address to, uint256 value) external returns (bool);
        error InvalidAssetConfig();
        error StaleMarkPrice();
        error NonceAlreadyUsed();
    }

    fn dispatch(calldata: Vec<u8>) -> Result<Vec<u8>, Vec<u8>> {
        let mut engine = StylusClearingEngine::default();
        dispatch_call(&mut engine, &calldata)
    }

    fn addr_for_key(byte: u8) -> Address {
        let sk_bytes = [byte; 32];
        let sk = SigningKey::from_slice(&sk_bytes).expect("valid key");
        let pt = sk.verifying_key().to_encoded_point(false);
        let h = keccak256(&pt.as_bytes()[1..65]);
        Address::from_slice(&h[12..32])
    }

    fn sign_digest(vm: &TestVM, byte: u8, digest: B256) -> (u8, B256, B256) {
        let sk_bytes = [byte; 32];
        let sk = SigningKey::from_slice(&sk_bytes).expect("valid key");
        let (sig, rec) = sk.sign_prehash_recoverable(digest.as_slice()).expect("sign");
        let raw = sig.to_bytes();
        let mut r = [0u8; 32];
        let mut s = [0u8; 32];
        r.copy_from_slice(&raw[0..32]);
        s.copy_from_slice(&raw[32..64]);
        let v = rec.to_byte() + 27;

        let mut pre_in = [0u8; 128];
        pre_in[0..32].copy_from_slice(digest.as_slice());
        pre_in[63] = v;
        pre_in[64..96].copy_from_slice(&r);
        pre_in[96..128].copy_from_slice(&s);
        let mut pre_out = [0u8; 32];
        pre_out[12..32].copy_from_slice(addr_for_key(byte).as_slice());
        vm.mock_static_call(Address::with_last_byte(0x01), pre_in.to_vec(), Ok(pre_out.to_vec()));
        (v, B256::new(r), B256::new(s))
    }

    #[test]
    fn test_v07_partial_fill_cumulative_vault_reserve_and_admin_circuit_breakers() {
        let vm = TestVM::new();
        let admin = Address::repeat_byte(0xAA);
        let next_admin = Address::repeat_byte(0xAB);
        let buyer = addr_for_key(0x11);
        let seller1 = addr_for_key(0x22);
        let seller2 = addr_for_key(0x33);
        let usdc = Address::repeat_byte(0xCC);
        let wad = U256::from(clearing_core::WAD_U64);
        let iwad = I256::try_from(clearing_core::WAD_U64).unwrap();

        vm.set_sender(admin);
        assert!(dispatch(initializeCall { initialAdmin: admin, benchmarkSeedingEnabled: true }.abi_encode()).is_ok());
        // v1.0.0 P0-1: benchmarkSeedingEnabled() selector 0xed80e033 MUST return true for StylusAtomicFactory
        let seed_flag = dispatch([0xed, 0x80, 0xe0, 0x33].to_vec()).expect("benchmarkSeedingEnabled");
        assert_eq!(seed_flag.len(), 32);
        assert_eq!(seed_flag[31], 1);

        // Two-step admin transfer (`D-32`)
        assert!(dispatch(transferAdminCall { newAdmin: next_admin }.abi_encode()).is_ok());
        vm.set_sender(next_admin);
        assert!(dispatch(acceptAdminCall {}.abi_encode()).is_ok());
        vm.set_sender(next_admin);
        assert!(dispatch(transferAdminCall { newAdmin: admin }.abi_encode()).is_ok());
        vm.set_sender(admin);
        assert!(dispatch(acceptAdminCall {}.abi_encode()).is_ok());

        // Codeless ERC-20 rejected (`D-10`)
        assert_eq!(
            dispatch(configureAssetCall { assetId: 0, token: usdc, decimals: 6, markPriceWad: wad, haircutBps: 0, imBps: 500, mmBps: 250 }.abi_encode()),
            Err(InvalidAssetConfig {}.abi_encode())
        );

        // Configure virtual benchmark assets 0 (USDC) and 1 (WETH)
        assert!(dispatch(configureAssetCall { assetId: 0, token: Address::ZERO, decimals: 6, markPriceWad: wad, haircutBps: 0, imBps: 500, mmBps: 250 }.abi_encode()).is_ok());
        assert!(dispatch(configureAssetCall { assetId: 1, token: Address::ZERO, decimals: 18, markPriceWad: U256::from(2_500u64) * wad, haircutBps: 500, imBps: 1000, mmBps: 500 }.abi_encode()).is_ok());

        // > 50% single-step mark price shock blocked (`D-32`)
        assert_eq!(
            dispatch(updateMarkPriceCall { assetId: 1, markPriceWad: U256::from(4_000u64) * wad }.abi_encode()),
            Err(InvalidAssetConfig {}.abi_encode())
        );

        // Seed accounts and test cumulative EIP-712 partial fill (`D-18`)
        for (who, a0, a1) in [
            (buyer, 10_000i64, 0i64),
            (seller1, 0i64, 1i64),
            (seller2, 0i64, 2i64),
        ] {
            assert!(dispatch(seedAccountBalanceCall { trader: who, assetId: 0, balanceWad: I256::try_from(a0).unwrap() * iwad }.abi_encode()).is_ok());
            assert!(dispatch(seedAccountBalanceCall { trader: who, assetId: 1, balanceWad: I256::try_from(a1).unwrap() * iwad }.abi_encode()).is_ok());
        }

        let ds_raw = dispatch(domainSeparatorCall {}.abi_encode()).unwrap();
        let dom_sep = B256::abi_decode(&ds_raw, true).unwrap();
        let buy_nonce = U256::from(77u64);
        let buy_digest = clearing_core::compute_trade_intent_digest(
            dom_sep, buyer, 1, 0, clearing_core::OrderSide::Buy, U256::from(2u64) * wad, U256::from(2_500u64) * wad, 10, buy_nonce
        );
        let (bv, br, bs) = sign_digest(&vm, 0x11, buy_digest);

        // Batch 1: seller1 sells 1 WETH against buyer's 2 WETH EIP-712 order -> partial fill = 1 WETH
        vm.set_sender(seller1);
        let b1 = dispatch(settleBatchCall {
            participants: vec![buyer, seller1],
            obligations: vec![],
            intents: vec![
                SignedTradeIntent { trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 1, v: bv, maxEpoch: 10, amountWad: U256::from(2u64) * wad, limitPriceWad: U256::from(2_500u64) * wad, nonce: buy_nonce, r: br, s: bs },
                SignedTradeIntent { trader: 1, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 0, v: 0, maxEpoch: 10, amountWad: wad, limitPriceWad: U256::from(2_500u64) * wad, nonce: U256::from(1u64), r: B256::ZERO, s: B256::ZERO },
            ],
        }.abi_encode()).expect("batch 1 partial fill");
        let (_, m1) = <(u32, U256)>::abi_decode_params(&b1, true).unwrap();
        assert_eq!(m1, wad);

        let pf_raw = dispatch(getPartialFillCall { trader: buyer, nonce: buy_nonce }.abi_encode()).unwrap();
        assert_eq!(U256::abi_decode(&pf_raw, true).unwrap(), wad);

        // Batch 2: seller2 tries to fill 2 WETH against buyer's SAME 2 WETH signature -> capped to remaining 1 WETH, then nonce burned!
        vm.set_sender(seller2);
        let b2 = dispatch(settleBatchCall {
            participants: vec![buyer, seller2],
            obligations: vec![],
            intents: vec![
                SignedTradeIntent { trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 1, v: bv, maxEpoch: 10, amountWad: U256::from(2u64) * wad, limitPriceWad: U256::from(2_500u64) * wad, nonce: buy_nonce, r: br, s: bs },
                SignedTradeIntent { trader: 1, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 0, v: 0, maxEpoch: 10, amountWad: U256::from(2u64) * wad, limitPriceWad: U256::from(2_500u64) * wad, nonce: U256::from(2u64), r: B256::ZERO, s: B256::ZERO },
            ],
        }.abi_encode()).expect("batch 2 completes remaining 1 WETH");
        let (_, m2) = <(u32, U256)>::abi_decode_params(&b2, true).unwrap();
        assert_eq!(m2, wad);

        // Batch 3: replay after 100% fill MUST revert NonceAlreadyUsed!
        assert_eq!(
            dispatch(settleBatchCall {
                participants: vec![buyer, seller2],
                obligations: vec![],
                intents: vec![
                    SignedTradeIntent { trader: 0, baseAsset: 1, quoteAsset: 0, side: 0, authMode: 1, v: bv, maxEpoch: 10, amountWad: U256::from(2u64) * wad, limitPriceWad: U256::from(2_500u64) * wad, nonce: buy_nonce, r: br, s: bs },
                    SignedTradeIntent { trader: 1, baseAsset: 1, quoteAsset: 0, side: 1, authMode: 0, v: 0, maxEpoch: 10, amountWad: wad, limitPriceWad: U256::from(2_500u64) * wad, nonce: U256::from(3u64), r: B256::ZERO, s: B256::ZERO },
                ],
            }.abi_encode()),
            Err(NonceAlreadyUsed {}.abi_encode())
        );
    }

    #[test]
    fn test_v07_subquantum_debt_repay_bad_debt_absorb_and_dust_staleness() {
        let vm = TestVM::new();
        let admin = Address::repeat_byte(0xAA);
        let trader = Address::repeat_byte(0x11);
        let usdc = Address::repeat_byte(0xCC);
        let wad = U256::from(clearing_core::WAD_U64);
        let iwad = I256::try_from(clearing_core::WAD_U64).unwrap();
        let mut bool_true = [0u8; 32];
        bool_true[31] = 1;

        vm.set_code_size(usdc, 256);
        vm.set_sender(admin);
        assert!(dispatch(initializeCall { initialAdmin: admin, benchmarkSeedingEnabled: true }.abi_encode()).is_ok());
        assert!(dispatch(configureAssetCall { assetId: 0, token: usdc, decimals: 6, markPriceWad: wad, haircutBps: 0, imBps: 500, mmBps: 250 }.abi_encode()).is_ok());
        assert!(dispatch(configureAssetCall { assetId: 1, token: Address::ZERO, decimals: 18, markPriceWad: U256::from(2_000u64) * wad, haircutBps: 500, imBps: 1000, mmBps: 500 }.abi_encode()).is_ok());

        // Deposit 1000 USDC (`balanceOf` delta strictly enforced)
        let raw_dep = U256::from(1_000_000_000u64);
        let this_addr = vm.contract_address();
        let mut bal_call = Vec::with_capacity(36);
        bal_call.extend_from_slice(&SEL_ERC20_BALANCE_OF);
        bal_call.extend_from_slice(&word_addr(this_addr));
        vm.mock_static_call(usdc, bal_call.clone(), Ok(u256_be(&raw_dep).to_vec()));
        vm.mock_call(usdc, transferFromCall { from: trader, to: this_addr, value: raw_dep }.abi_encode(), U256::ZERO, Ok(bool_true.to_vec()));
        // Without balance delta (post == pre), deposit MUST revert InvalidAssetConfig (FoT protection)
        vm.set_sender(trader);
        assert_eq!(
            dispatch(depositCall { assetId: 0, rawAmount: raw_dep }.abi_encode()),
            Err(InvalidAssetConfig {}.abi_encode())
        );

        // Configure virtual asset 2 for sub-quantum dust sweep staleness check (`D-20`)
        vm.set_sender(admin);
        assert!(dispatch(configureAssetCall { assetId: 2, token: Address::ZERO, decimals: 6, markPriceWad: wad, haircutBps: 0, imBps: 500, mmBps: 250 }.abi_encode()).is_ok());
        // P1-2: configureAsset MUST enforce 50% mark price step breaker on already-initialized asset
        assert_eq!(
            dispatch(configureAssetCall { assetId: 2, token: Address::ZERO, decimals: 6, markPriceWad: U256::from(3u64) * wad, haircutBps: 0, imBps: 500, mmBps: 250 }.abi_encode()),
            Err(InvalidAssetConfig {}.abi_encode())
        );
        assert!(dispatch(seedAccountBalanceCall { trader, assetId: 2, balanceWad: I256::try_from(500_000_000_000i64).unwrap() }.abi_encode()).is_ok());
        assert!(dispatch(seedAccountBalanceCall { trader, assetId: 1, balanceWad: -iwad }.abi_encode()).is_ok());
        vm.set_block_timestamp(10_000);
        vm.set_sender(trader);
        assert_eq!(
            dispatch(sweepDustToFeeVaultCall { assetId: 2 }.abi_encode()),
            Err(StaleMarkPrice {}.abi_encode())
        );
        // Reset clock for absorbBadDebt check
        vm.set_block_timestamp(100);

        // Clear WETH debt and test absorbBadDebt (`D-16`) on a separate leaf account
        let leaf = Address::repeat_byte(0x55);
        vm.set_sender(admin);
        assert!(dispatch(seedAccountBalanceCall { trader: leaf, assetId: 1, balanceWad: -iwad }.abi_encode()).is_ok());
        assert!(dispatch(seedAccountBalanceCall { trader: admin, assetId: 1, balanceWad: I256::try_from(5i64).unwrap() * iwad }.abi_encode()).is_ok());
        let abs_raw = dispatch(absorbBadDebtCall { underwater: leaf, debtAsset: 1 }.abi_encode()).expect("admin backstops bad debt");
        assert_eq!(U256::abi_decode(&abs_raw, true).unwrap(), wad);
        // v1.0.0 P0-3: configureAsset MUST reject same-block mark price change even within 50% step
        assert_eq!(
            dispatch(configureAssetCall { assetId: 2, token: Address::ZERO, decimals: 6, markPriceWad: U256::from(11u64) * wad / U256::from(10u64), haircutBps: 0, imBps: 500, mmBps: 250 }.abi_encode()),
            Err(InvalidAssetConfig {}.abi_encode())
        );
        // v1.0.0 P1-5: seedAccountBalance MUST reject Address::ZERO
        assert_eq!(
            dispatch(seedAccountBalanceCall { trader: Address::ZERO, assetId: 2, balanceWad: iwad }.abi_encode()),
            Err(InvalidAssetConfig {}.abi_encode())
        );
    }
}
