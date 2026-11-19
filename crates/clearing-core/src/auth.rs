use alloy_primitives::{Address, B256, U256};

use crate::auction::OrderSide;
use crate::error::ClearingError;
use crate::math::cmp_u256;

pub const EIP712_TRADE_INTENT_SIGNATURE: &str =
    "TradeIntent(address trader,uint8 baseAsset,uint8 quoteAsset,uint8 side,uint256 amountWad,uint256 limitPriceWad,uint64 maxEpoch,uint256 nonce)";

pub const EIP712_OBLIGATION_SIGNATURE: &str =
    "ObligationAttestation(address debtor,address creditor,uint8 assetId,uint256 amountWad,uint64 maxEpoch,uint256 nonce)";


/// secp256k1 curve order `N` and `N / 2` (`EIP-2` malleability ceiling).
pub const SECP256K1_N: U256 = U256::from_limbs([
    0xBFD25E8CD0364141,
    0xBAAEDCE6AF48A03B,
    0xFFFFFFFFFFFFFFFE,
    0xFFFFFFFFFFFFFFFF,
]);
pub const SECP256K1_HALF_N: U256 = U256::from_limbs([
    0xDFE92F46681B20A0,
    0x5D576E7357A4501D,
    0xFFFFFFFFFFFFFFFF,
    0x7FFFFFFFFFFFFFFF,
]);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthWitness {
    DirectCaller,
    Eip712Signature { v: u8, r: B256, s: B256 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ObligationAuth {
    PreRegisteredLedger,
    DirectDebtor { max_epoch: u64, nonce: U256 },
    Eip712Debtor {
        max_epoch: u64,
        nonce: U256,
        v: u8,
        r: B256,
        s: B256,
    },
}

pub trait SignatureVerifier {
    fn ecrecover(&self, digest: B256, v: u8, r: B256, s: B256) -> Option<Address>;

    fn keccak256(&self, bytes: &[u8]) -> B256 {
        #[cfg(not(target_arch = "wasm32"))]
        {
            // Pure-Rust Keccak-f[1600] sponge for offline std/CLI callers (`keccak256` without HostIO)
            keccak256_soft(bytes)
        }
        #[cfg(target_arch = "wasm32")]
        {
            let _ = bytes;
            B256::ZERO
        }
    }
}

#[inline]
fn put_bytes(dst: &mut [u8], off: usize, src: &[u8]) {
    let mut i = 0;
    while i < src.len() {
        dst[off + i] = src[i];
        i += 1;
    }
}

#[inline(never)]
pub fn compute_domain_separator_with<V: SignatureVerifier>(
    verifier: &V,
    chain_id: u64,
    verifying_contract: Address,
) -> B256 {
    let mut buf = [0u8; 160];
    put_bytes(&mut buf, 0, verifier.keccak256(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)").as_slice());
    put_bytes(&mut buf, 32, verifier.keccak256(b"StylusClear").as_slice());
    put_bytes(&mut buf, 64, verifier.keccak256(b"1").as_slice());
    put_bytes(&mut buf, 120, &chain_id.to_be_bytes());
    put_bytes(&mut buf, 140, verifying_contract.as_slice());
    verifier.keccak256(&buf)
}

#[inline(never)]
fn hash_eip712_typed_data<V: SignatureVerifier>(
    verifier: &V,
    domain_separator: &B256,
    struct_hash: &B256,
) -> B256 {
    let mut dbuf = [0u8; 66];
    dbuf[0] = 0x19;
    dbuf[1] = 0x01;
    put_bytes(&mut dbuf, 2, domain_separator.as_slice());
    put_bytes(&mut dbuf, 34, struct_hash.as_slice());
    verifier.keccak256(&dbuf)
}

#[inline(never)]
#[allow(clippy::too_many_arguments)]
pub fn compute_trade_intent_digest_with<V: SignatureVerifier>(
    verifier: &V,
    domain_separator: &B256,
    trader: Address,
    base_asset: u8,
    quote_asset: u8,
    side: OrderSide,
    amount_wad: &U256,
    limit_price_wad: &U256,
    max_epoch: u64,
    nonce: &U256,
) -> B256 {
    let mut sbuf = [0u8; 288];
    put_bytes(&mut sbuf, 0, verifier.keccak256(EIP712_TRADE_INTENT_SIGNATURE.as_bytes()).as_slice());
    put_bytes(&mut sbuf, 44, trader.as_slice());
    sbuf[95] = base_asset;
    sbuf[127] = quote_asset;
    sbuf[159] = side as u8;
    put_bytes(&mut sbuf, 160, &amount_wad.to_be_bytes::<32>());
    put_bytes(&mut sbuf, 192, &limit_price_wad.to_be_bytes::<32>());
    put_bytes(&mut sbuf, 248, &max_epoch.to_be_bytes());
    put_bytes(&mut sbuf, 256, &nonce.to_be_bytes::<32>());
    let sh = verifier.keccak256(&sbuf);
    hash_eip712_typed_data(verifier, domain_separator, &sh)
}

#[inline(never)]
#[allow(clippy::too_many_arguments)]
pub fn compute_obligation_digest_with<V: SignatureVerifier>(
    verifier: &V,
    domain_separator: &B256,
    debtor: Address,
    creditor: Address,
    asset_id: u8,
    amount_wad: &U256,
    max_epoch: u64,
    nonce: &U256,
) -> B256 {
    let mut sbuf = [0u8; 224];
    put_bytes(&mut sbuf, 0, verifier.keccak256(EIP712_OBLIGATION_SIGNATURE.as_bytes()).as_slice());
    put_bytes(&mut sbuf, 44, debtor.as_slice());
    put_bytes(&mut sbuf, 76, creditor.as_slice());
    sbuf[127] = asset_id;
    put_bytes(&mut sbuf, 128, &amount_wad.to_be_bytes::<32>());
    put_bytes(&mut sbuf, 184, &max_epoch.to_be_bytes());
    put_bytes(&mut sbuf, 192, &nonce.to_be_bytes::<32>());
    let sh = verifier.keccak256(&sbuf);
    hash_eip712_typed_data(verifier, domain_separator, &sh)
}

#[inline]
pub fn split_bitmap_nonce_ref(nonce: &U256) -> (U256, u8) {
    let bit = (nonce.as_limbs()[0] & 0xFF) as u8;
    (*nonce >> 8usize, bit)
}

#[inline]
pub fn split_bitmap_nonce(nonce: U256) -> (U256, u8) {
    split_bitmap_nonce_ref(&nonce)
}

#[inline(never)]
pub fn consume_bitmap_bit_ref(word: &mut U256, bit_pos: u8) -> Result<(), ClearingError> {
    let mask = U256::from(1u64) << usize::from(bit_pos);
    if !(*word & mask).is_zero() {
        return Err(ClearingError::NonceAlreadyUsed);
    }
    *word |= mask;
    Ok(())
}

#[cfg(not(target_arch = "wasm32"))]
pub fn consume_bitmap_bit(word: U256, bit_pos: u8) -> Result<U256, ClearingError> {
    let mut w = word;
    consume_bitmap_bit_ref(&mut w, bit_pos)?;
    Ok(w)
}

#[inline(never)]
pub fn verify_eip712_signature<V: SignatureVerifier>(
    verifier: &V,
    digest: B256,
    expected_signer: Address,
    v: u8,
    r: B256,
    s: B256,
) -> Result<(), ClearingError> {
    if expected_signer.is_zero() || (v != 27 && v != 28) {
        return Err(ClearingError::InvalidSignature);
    }
    let r_u = U256::from_be_bytes(r.0);
    let s_u = U256::from_be_bytes(s.0);
    if r_u.is_zero()
        || cmp_u256(&r_u, &SECP256K1_N).is_ge()
        || s_u.is_zero()
        || cmp_u256(&s_u, &SECP256K1_HALF_N).is_gt()
    {
        return Err(ClearingError::InvalidSignature);
    }
    match verifier.ecrecover(digest, v, r, s) {
        Some(recovered) if !recovered.is_zero() && recovered == expected_signer => Ok(()),
        _ => Err(ClearingError::InvalidSignature),
    }
}

#[cfg(not(target_arch = "wasm32"))]
struct SoftKeccakOnly;
#[cfg(not(target_arch = "wasm32"))]
impl SignatureVerifier for SoftKeccakOnly {
    fn ecrecover(&self, _: B256, _: u8, _: B256, _: B256) -> Option<Address> {
        None
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub fn compute_domain_separator(chain_id: u64, verifying_contract: Address) -> B256 {
    compute_domain_separator_with(&SoftKeccakOnly, chain_id, verifying_contract)
}

#[cfg(not(target_arch = "wasm32"))]
#[allow(clippy::too_many_arguments)]
pub fn compute_trade_intent_digest(
    domain_separator: B256,
    trader: Address,
    base_asset: u8,
    quote_asset: u8,
    side: OrderSide,
    amount_wad: U256,
    limit_price_wad: U256,
    max_epoch: u64,
    nonce: U256,
) -> B256 {
    compute_trade_intent_digest_with(
        &SoftKeccakOnly,
        &domain_separator,
        trader,
        base_asset,
        quote_asset,
        side,
        &amount_wad,
        &limit_price_wad,
        max_epoch,
        &nonce,
    )
}

#[cfg(not(target_arch = "wasm32"))]
pub fn compute_obligation_digest(
    domain_separator: B256,
    debtor: Address,
    creditor: Address,
    asset_id: u8,
    amount_wad: U256,
    max_epoch: u64,
    nonce: U256,
) -> B256 {
    compute_obligation_digest_with(
        &SoftKeccakOnly,
        &domain_separator,
        debtor,
        creditor,
        asset_id,
        &amount_wad,
        max_epoch,
        &nonce,
    )
}

#[cfg(not(target_arch = "wasm32"))]
fn keccak256_soft(input: &[u8]) -> B256 {
    const RC: [u64; 24] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ];
    const ROT: [u32; 24] = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
    ];
    const PILN: [usize; 24] = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
    ];
    fn keccakf(st: &mut [u64; 25]) {
        for &rc in &RC {
            let mut bc = [0u64; 5];
            for i in 0..5 {
                bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20];
            }
            for i in 0..5 {
                let t = bc[(i + 4) % 5] ^ bc[(i + 1) % 5].rotate_left(1);
                for j in (0..25).step_by(5) {
                    st[j + i] ^= t;
                }
            }
            let mut t = st[1];
            for i in 0..24 {
                let j = PILN[i];
                let tmp = st[j];
                st[j] = t.rotate_left(ROT[i]);
                t = tmp;
            }
            for j in (0..25).step_by(5) {
                let row = [st[j], st[j + 1], st[j + 2], st[j + 3], st[j + 4]];
                for i in 0..5 {
                    st[j + i] ^= (!row[(i + 1) % 5]) & row[(i + 2) % 5];
                }
            }
            st[0] ^= rc;
        }
    }

    let mut st = [0u64; 25];
    let rate = 136usize;
    let mut off = 0usize;
    while off + rate <= input.len() {
        for i in 0..17 {
            let mut b = [0u8; 8];
            b.copy_from_slice(&input[off + i * 8..off + (i + 1) * 8]);
            st[i] ^= u64::from_le_bytes(b);
        }
        keccakf(&mut st);
        off += rate;
    }
    let mut block = [0u8; 136];
    let rem = input.len() - off;
    block[..rem].copy_from_slice(&input[off..]);
    block[rem] = 0x01;
    block[rate - 1] |= 0x80;
    for i in 0..17 {
        let mut b = [0u8; 8];
        b.copy_from_slice(&block[i * 8..(i + 1) * 8]);
        st[i] ^= u64::from_le_bytes(b);
    }
    keccakf(&mut st);
    let mut out = [0u8; 32];
    for i in 0..4 {
        out[i * 8..(i + 1) * 8].copy_from_slice(&st[i].to_le_bytes());
    }
    B256::new(out)
}
