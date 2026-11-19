#[cfg(not(target_arch = "wasm32"))]
use alloc::collections::BTreeMap;
use alloc::vec::Vec;
use alloy_primitives::{I256, U256};
use core::cmp::Ordering;
#[cfg(not(target_arch = "wasm32"))]
use core::iter::FromIterator;

use crate::error::ClearingError;

/// 18-decimal fixed-point unit (`10^18`).
pub const WAD_U64: u64 = 1_000_000_000_000_000_000;
/// Basis points denominator (`10_000` = 100.00%).
pub const BPS_DENOM_U64: u64 = 10_000;
/// Minimum order lot and quantization quantum (`10^9` = 1 Gwei).
pub const MIN_INTENT_AMOUNT_U64: u64 = 1_000_000_000;

/// Compact deterministic associative map avoiding `alloc::collections::BTreeMap` WASM bloat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlatMap<K, V>(Vec<(K, V)>);

impl<K, V> Default for FlatMap<K, V> {
    fn default() -> Self {
        Self(Vec::new())
    }
}

impl<K: Ord, V> FlatMap<K, V> {
    #[inline]
    pub const fn new() -> Self {
        Self(Vec::new())
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.0.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn get(&self, key: &K) -> Option<&V> {
        for (k, v) in &self.0 {
            if k == key {
                return Some(v);
            }
        }
        None
    }

    pub fn insert(&mut self, key: K, val: V) -> Option<V> {
        for slot in &mut self.0 {
            if slot.0 == key {
                return Some(core::mem::replace(&mut slot.1, val));
            }
        }
        self.0.push((key, val));
        None
    }

    pub fn ensure_with<F: FnOnce() -> V>(&mut self, key: K, f: F) -> &V {
        for (idx, slot) in self.0.iter().enumerate() {
            if slot.0 == key {
                return &self.0[idx].1;
            }
        }
        self.0.push((key, f()));
        let last = self.0.len() - 1;
        &self.0[last].1
    }

    #[inline]
    pub fn iter(&self) -> core::slice::Iter<'_, (K, V)> {
        self.0.iter()
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl<K: Ord, V> FromIterator<(K, V)> for FlatMap<K, V> {
    fn from_iter<I: IntoIterator<Item = (K, V)>>(iter: I) -> Self {
        let mut m = Self::new();
        for (k, v) in iter {
            m.insert(k, v);
        }
        m
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl<K: Ord, V> From<BTreeMap<K, V>> for FlatMap<K, V> {
    fn from(src: BTreeMap<K, V>) -> Self {
        Self(src.into_iter().collect())
    }
}

impl<K, V> IntoIterator for FlatMap<K, V> {
    type Item = (K, V);
    type IntoIter = alloc::vec::IntoIter<(K, V)>;
    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}

impl<'a, K, V> IntoIterator for &'a FlatMap<K, V> {
    type Item = &'a (K, V);
    type IntoIter = core::slice::Iter<'a, (K, V)>;
    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

/// Stable deterministic insertion sort for bounded batch arrays (`<= 259` elements).
pub fn insertion_sort_by<T, F: FnMut(&T, &T) -> Ordering>(slice: &mut [T], mut cmp: F) {
    for i in 1..slice.len() {
        let mut j = i;
        while j > 0 && cmp(&slice[j - 1], &slice[j]) == Ordering::Greater {
            slice.swap(j - 1, j);
            j -= 1;
        }
    }
}

#[inline]
pub fn wad_u256() -> U256 {
    U256::from(WAD_U64)
}

#[inline]
pub fn bps_denom_u256() -> U256 {
    U256::from(BPS_DENOM_U64)
}

#[inline]
pub fn min_intent_amount_u256() -> U256 {
    U256::from(MIN_INTENT_AMOUNT_U64)
}

#[inline(never)]
pub fn cmp_u256(a: &U256, b: &U256) -> Ordering {
    a.cmp(b)
}

#[inline(never)]
pub fn cmp_i256(a: &I256, b: &I256) -> Ordering {
    a.cmp(b)
}

#[inline(never)]
fn widen_mul_512(a: &U256, b: &U256) -> [u64; 8] {
    let al = a.as_limbs();
    let bl = b.as_limbs();
    let mut out = [0u64; 8];
    for i in 0..4 {
        let mut carry = 0u128;
        let ai = u128::from(al[i]);
        for j in 0..4 {
            let acc = u128::from(out[i + j]) + ai * u128::from(bl[j]) + carry;
            out[i + j] = acc as u64;
            carry = acc >> 64;
        }
        out[i + 4] = carry as u64;
    }
    out
}

#[inline]
fn cmp_512(a: &[u64; 8], b: &[u64; 8]) -> Ordering {
    let mut i = 8;
    while i > 0 {
        i -= 1;
        if a[i] != b[i] {
            return if a[i] < b[i] {
                Ordering::Less
            } else {
                Ordering::Greater
            };
        }
    }
    Ordering::Equal
}

#[inline(never)]
fn extract_u256(limbs: &[u64; 8], out: &mut U256) -> Result<(), ClearingError> {
    if (limbs[4] | limbs[5] | limbs[6] | limbs[7]) != 0 {
        return Err(ClearingError::MathOverflow);
    }
    *out = U256::from_limbs([limbs[0], limbs[1], limbs[2], limbs[3]]);
    Ok(())
}

#[inline(never)]
pub fn uadd_assign(acc: &mut U256, b: &U256) -> Result<(), ClearingError> {
    *acc = acc.checked_add(*b).ok_or(ClearingError::MathOverflow)?;
    Ok(())
}

#[inline(never)]
pub fn usub_assign(acc: &mut U256, b: &U256) -> Result<(), ClearingError> {
    *acc = acc.checked_sub(*b).ok_or(ClearingError::MathOverflow)?;
    Ok(())
}

#[inline]
pub fn uadd_ref(a: &U256, b: &U256, out: &mut U256) -> Result<(), ClearingError> {
    *out = *a;
    uadd_assign(out, b)
}

#[inline]
pub fn usub_ref(a: &U256, b: &U256, out: &mut U256) -> Result<(), ClearingError> {
    *out = *a;
    usub_assign(out, b)
}

#[inline(never)]
pub fn umul_ref(a: &U256, b: &U256, out: &mut U256) -> Result<(), ClearingError> {
    let p = widen_mul_512(a, b);
    extract_u256(&p, out)
}

#[inline(never)]
pub fn iadd_assign(acc: &mut I256, b: &I256) -> Result<(), ClearingError> {
    *acc = acc.checked_add(*b).ok_or(ClearingError::MathOverflow)?;
    Ok(())
}

#[inline(never)]
pub fn isub_assign(acc: &mut I256, b: &I256) -> Result<(), ClearingError> {
    *acc = acc.checked_sub(*b).ok_or(ClearingError::MathOverflow)?;
    Ok(())
}

#[inline]
pub fn iadd_ref(a: &I256, b: &I256, out: &mut I256) -> Result<(), ClearingError> {
    *out = *a;
    iadd_assign(out, b)
}

#[inline]
pub fn isub_ref(a: &I256, b: &I256, out: &mut I256) -> Result<(), ClearingError> {
    *out = *a;
    isub_assign(out, b)
}

#[inline(never)]
pub fn u2i_ref(v: &U256, out: &mut I256) -> Result<(), ClearingError> {
    *out = I256::try_from(*v).map_err(|_| ClearingError::MathOverflow)?;
    Ok(())
}

#[inline(never)]
pub fn i_abs_ref(v: &I256, out: &mut U256) -> Result<(), ClearingError> {
    if *v == I256::MIN {
        return Err(ClearingError::MathOverflow);
    }
    *out = v.unsigned_abs();
    Ok(())
}

#[inline(never)]
fn div_rem_512(
    num: &[u64; 8],
    den: &[u64; 8],
    q_out: &mut [u64; 8],
    r_out: &mut [u64; 8],
) -> Result<(), ClearingError> {
    if (den[0] | den[1] | den[2] | den[3] | den[4] | den[5] | den[6] | den[7]) == 0 {
        return Err(ClearingError::DivisionByZero);
    }
    *q_out = [0u64; 8];
    if cmp_512(num, den) == Ordering::Less {
        *r_out = *num;
        return Ok(());
    }

    let mut top_limb = 7usize;
    while top_limb > 0 && num[top_limb] == 0 {
        top_limb -= 1;
    }
    let total_bits = top_limb * 64 + (64 - num[top_limb].leading_zeros() as usize);

    let mut rem = [0u64; 8];
    let mut bit_idx = total_bits;
    while bit_idx > 0 {
        bit_idx -= 1;
        let mut carry = (num[bit_idx >> 6] >> (bit_idx & 63)) & 1;
        for slot in &mut rem {
            let next_carry = *slot >> 63;
            *slot = (*slot << 1) | carry;
            carry = next_carry;
        }
        if cmp_512(&rem, den) != Ordering::Less {
            let mut borrow = 0u64;
            for i in 0..8 {
                let (d1, b1) = rem[i].overflowing_sub(den[i]);
                let (d2, b2) = d1.overflowing_sub(borrow);
                rem[i] = d2;
                borrow = u64::from(b1) + u64::from(b2);
            }
            q_out[bit_idx >> 6] |= 1u64 << (bit_idx & 63);
        }
    }
    *r_out = rem;
    Ok(())
}

#[inline(never)]
pub fn mul_div_ref(
    a: &U256,
    b: &U256,
    denom: &U256,
    ceil: bool,
    out: &mut U256,
) -> Result<(), ClearingError> {
    if denom.is_zero() {
        return Err(ClearingError::DivisionByZero);
    }
    let numerator = widen_mul_512(a, b);
    if (numerator[0]
        | numerator[1]
        | numerator[2]
        | numerator[3]
        | numerator[4]
        | numerator[5]
        | numerator[6]
        | numerator[7])
        == 0
    {
        *out = U256::ZERO;
        return Ok(());
    }
    let dl = denom.as_limbs();
    let den512 = [dl[0], dl[1], dl[2], dl[3], 0, 0, 0, 0];
    let mut q = [0u64; 8];
    let mut r = [0u64; 8];
    div_rem_512(&numerator, &den512, &mut q, &mut r)?;
    if ceil && (r[0] | r[1] | r[2] | r[3] | r[4] | r[5] | r[6] | r[7]) != 0 {
        let mut carry = 1u64;
        for slot in &mut q {
            let (s, c) = slot.overflowing_add(carry);
            *slot = s;
            carry = u64::from(c);
            if carry == 0 {
                break;
            }
        }
        if carry != 0 {
            return Err(ClearingError::MathOverflow);
        }
    }
    extract_u256(&q, out)
}

#[inline]
pub fn mul_u64_div_u64_ref(
    a: &U256,
    mul_bps: u64,
    div_bps: u64,
    ceil: bool,
    out: &mut U256,
) -> Result<(), ClearingError> {
    mul_div_ref(a, &U256::from(mul_bps), &U256::from(div_bps), ceil, out)
}

#[inline]
pub fn mul_wad_ref(a: &U256, b: &U256, ceil: bool, out: &mut U256) -> Result<(), ClearingError> {
    mul_div_ref(a, b, &U256::from(WAD_U64), ceil, out)
}

#[inline(never)]
pub fn div_rem_u256_ref(
    num: &U256,
    den: &U256,
    q_out: &mut U256,
    r_out: &mut U256,
) -> Result<(), ClearingError> {
    let nl = num.as_limbs();
    let dl = den.as_limbs();
    let n512 = [nl[0], nl[1], nl[2], nl[3], 0, 0, 0, 0];
    let d512 = [dl[0], dl[1], dl[2], dl[3], 0, 0, 0, 0];
    let mut q = [0u64; 8];
    let mut r = [0u64; 8];
    div_rem_512(&n512, &d512, &mut q, &mut r)?;
    extract_u256(&q, q_out)?;
    extract_u256(&r, r_out)
}

#[inline]
pub fn quantize_down_ref(amount: &U256, step: &U256, out: &mut U256) -> Result<(), ClearingError> {
    let mut q = U256::ZERO;
    let mut r = U256::ZERO;
    div_rem_u256_ref(amount, step, &mut q, &mut r)?;
    umul_ref(&q, step, out)
}

#[inline(never)]
pub fn abs_diff_ref(a: &U256, b: &U256, out: &mut U256) {
    if cmp_u256(a, b).is_ge() {
        *out = *a - *b;
    } else {
        *out = *b - *a;
    }
}

#[inline(never)]
pub fn gt_mul_512_ref(a: &U256, b: &U256, c: &U256, d: &U256) -> bool {
    cmp_512(&widen_mul_512(a, b), &widen_mul_512(c, d)) == Ordering::Greater
}

#[inline]
pub fn pow10_u256(exp: u8) -> Result<U256, ClearingError> {
    if exp > 18 {
        return Err(ClearingError::InvalidAssetConfig);
    }
    Ok(U256::from(10u64.pow(u32::from(exp))))
}

#[inline(never)]
pub fn scale_raw_to_wad_ref(
    raw_amount: &U256,
    decimals: u8,
    out: &mut U256,
) -> Result<(), ClearingError> {
    if raw_amount.is_zero() || decimals > 18 {
        return Err(ClearingError::InvalidAssetConfig);
    }
    let factor = pow10_u256(18 - decimals)?;
    umul_ref(raw_amount, &factor, out)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn scale_raw_to_wad(raw_amount: U256, decimals: u8) -> Result<U256, ClearingError> {
    let mut o = U256::ZERO;
    scale_raw_to_wad_ref(&raw_amount, decimals, &mut o)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn checked_add_u256(a: U256, b: U256) -> Result<U256, ClearingError> {
    let mut o = a;
    uadd_assign(&mut o, &b)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn checked_sub_u256(a: U256, b: U256) -> Result<U256, ClearingError> {
    let mut o = a;
    usub_assign(&mut o, &b)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn checked_mul_u256(a: U256, b: U256) -> Result<U256, ClearingError> {
    let mut o = U256::ZERO;
    umul_ref(&a, &b, &mut o)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn checked_add_i256(a: I256, b: I256) -> Result<I256, ClearingError> {
    let mut o = a;
    iadd_assign(&mut o, &b)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn checked_sub_i256(a: I256, b: I256) -> Result<I256, ClearingError> {
    let mut o = a;
    isub_assign(&mut o, &b)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn u256_to_i256(v: U256) -> Result<I256, ClearingError> {
    let mut o = I256::ZERO;
    u2i_ref(&v, &mut o)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn abs_i256_to_u256(v: I256) -> Result<U256, ClearingError> {
    let mut o = U256::ZERO;
    i_abs_ref(&v, &mut o)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn div_u256(num: U256, den: U256) -> Result<U256, ClearingError> {
    let mut q = U256::ZERO;
    let mut r = U256::ZERO;
    div_rem_u256_ref(&num, &den, &mut q, &mut r)?;
    Ok(q)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn rem_u256(num: U256, den: U256) -> Result<U256, ClearingError> {
    let mut q = U256::ZERO;
    let mut r = U256::ZERO;
    div_rem_u256_ref(&num, &den, &mut q, &mut r)?;
    Ok(r)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn mul_div_floor(a: U256, b: U256, denom: U256) -> Result<U256, ClearingError> {
    let mut o = U256::ZERO;
    mul_div_ref(&a, &b, &denom, false, &mut o)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn mul_div_ceil(a: U256, b: U256, denom: U256) -> Result<U256, ClearingError> {
    let mut o = U256::ZERO;
    mul_div_ref(&a, &b, &denom, true, &mut o)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn mul_wad_floor(a: U256, b: U256) -> Result<U256, ClearingError> {
    let mut o = U256::ZERO;
    mul_wad_ref(&a, &b, false, &mut o)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn mul_wad_ceil(a: U256, b: U256) -> Result<U256, ClearingError> {
    let mut o = U256::ZERO;
    mul_wad_ref(&a, &b, true, &mut o)?;
    Ok(o)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn abs_diff_u256(a: U256, b: U256) -> U256 {
    let mut o = U256::ZERO;
    abs_diff_ref(&a, &b, &mut o);
    o
}
