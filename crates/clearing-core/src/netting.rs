#[cfg(not(target_arch = "wasm32"))]
use alloc::vec;
use alloc::vec::Vec;
use alloy_primitives::{Address, U256};

use crate::error::ClearingError;
#[cfg(not(target_arch = "wasm32"))]
use crate::math::umul_ref;
use crate::math::{cmp_u256, insertion_sort_by, uadd_assign, usub_assign};

pub const MAX_OBLIGATIONS: usize = 128;
const MAX_NETTING_ACCOUNTS: usize = 64;
const NONE_U8: u8 = 0xFF;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ObligationEdge {
    pub debtor: u16,
    pub creditor: u16,
    pub asset_id: u8,
    pub amount_wad: U256,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CycleCompressionOutcome {
    pub cycles_eliminated: u32,
    pub compressed_volume_by_asset: Vec<U256>,
    pub residual_obligations: Vec<ObligationEdge>,
}

/// Exact `O(V^2)` 2-Origin BFS cycle finder (`D-31`):
/// Always prefers a multilateral cycle (`length >= 3`: `start -> first -> ... -> last -> start`, `first != last`)
/// over a bilateral `2`-cycle (`start -> v -> start`), with zero recursion and strict polynomial runtime.
fn find_canonical_cycle_bfs(
    start: usize,
    num_accounts: usize,
    mat: &[U256],
    path: &mut [u8; MAX_NETTING_ACCOUNTS],
) -> usize {
    let mut r1 = [NONE_U8; MAX_NETTING_ACCOUNTS];
    let mut r2 = [NONE_U8; MAX_NETTING_ACCOUNTS];
    let mut q_node = [0u8; MAX_NETTING_ACCOUNTS * 2];
    let mut q_orig = [0u8; MAX_NETTING_ACCOUNTS * 2];
    let mut q_par = [NONE_U8; MAX_NETTING_ACCOUNTS * 2];
    let mut q_head = 0usize;
    let mut q_tail = 0usize;

    for f in (start + 1)..num_accounts {
        if !mat[start * num_accounts + f].is_zero() {
            let f_u8 = f as u8;
            r1[f] = f_u8;
            q_node[q_tail] = f_u8;
            q_orig[q_tail] = f_u8;
            q_tail += 1;
        }
    }

    while q_head < q_tail {
        let cur_qi = q_head;
        let u = usize::from(q_node[cur_qi]);
        let orig = q_orig[cur_qi];
        q_head += 1;

        if orig != (u as u8) && !mat[u * num_accounts + start].is_zero() {
            let mut rev = [0u8; MAX_NETTING_ACCOUNTS];
            let mut rlen = 0usize;
            let mut qi = cur_qi as u8;
            while qi != NONE_U8 {
                rev[rlen] = q_node[usize::from(qi)];
                rlen += 1;
                qi = q_par[usize::from(qi)];
            }
            path[0] = start as u8;
            for i in 0..rlen {
                path[1 + i] = rev[rlen - 1 - i];
            }
            return 1 + rlen;
        }

        for nxt in (start + 1)..num_accounts {
            if !mat[u * num_accounts + nxt].is_zero() {
                if r1[nxt] == NONE_U8 {
                    r1[nxt] = orig;
                    q_node[q_tail] = nxt as u8;
                    q_orig[q_tail] = orig;
                    q_par[q_tail] = cur_qi as u8;
                    q_tail += 1;
                } else if r1[nxt] != orig && r2[nxt] == NONE_U8 {
                    r2[nxt] = orig;
                    q_node[q_tail] = nxt as u8;
                    q_orig[q_tail] = orig;
                    q_par[q_tail] = cur_qi as u8;
                    q_tail += 1;
                }
            }
        }
    }

    for f in (start + 1)..num_accounts {
        if !mat[start * num_accounts + f].is_zero() && !mat[f * num_accounts + start].is_zero() {
            path[0] = start as u8;
            path[1] = f as u8;
            return 2;
        }
    }
    0
}

#[inline(never)]
pub fn compress_obligation_cycles(
    account_addresses: &[Address],
    num_assets: usize,
    obligations: &[ObligationEdge],
) -> Result<CycleCompressionOutcome, ClearingError> {
    let num_accounts = account_addresses.len();
    if obligations.len() > MAX_OBLIGATIONS || num_accounts > MAX_NETTING_ACCOUNTS {
        return Err(ClearingError::BatchCapacityExceeded);
    }

    if obligations.is_empty() {
        return Ok(CycleCompressionOutcome {
            cycles_eliminated: 0,
            #[cfg(not(target_arch = "wasm32"))]
            compressed_volume_by_asset: vec![U256::ZERO; num_assets],
            #[cfg(target_arch = "wasm32")]
            compressed_volume_by_asset: Vec::new(),
            residual_obligations: Vec::new(),
        });
    }

    let mut asset_mask: u16 = 0;
    for ob in obligations {
        let u_orig = usize::from(ob.debtor);
        let v_orig = usize::from(ob.creditor);
        let a = usize::from(ob.asset_id);
        if u_orig >= num_accounts
            || v_orig >= num_accounts
            || u_orig == v_orig
            || a >= num_assets
            || ob.amount_wad.is_zero()
        {
            return Err(ClearingError::InvalidObligation);
        }
        asset_mask |= 1u16 << a;
    }

    let mut rank_to_orig = [0u8; MAX_NETTING_ACCOUNTS];
    for (idx_r, slot) in rank_to_orig.iter_mut().take(num_accounts).enumerate() {
        *slot = idx_r as u8;
    }
    insertion_sort_by(&mut rank_to_orig[..num_accounts], |&a, &b| {
        account_addresses[usize::from(a)].cmp(&account_addresses[usize::from(b)])
    });
    let mut orig_to_rank = [0u8; MAX_NETTING_ACCOUNTS];
    for (rank, &orig) in rank_to_orig[..num_accounts].iter().enumerate() {
        orig_to_rank[usize::from(orig)] = rank as u8;
    }

    let mat_len = num_accounts * num_accounts;
    let mut mat = Vec::with_capacity(mat_len);
    for _ in 0..mat_len {
        mat.push(U256::ZERO);
    }
    let mut path = [0u8; MAX_NETTING_ACCOUNTS];
    #[cfg(not(target_arch = "wasm32"))]
    let mut compressed_volume_by_asset = vec![U256::ZERO; num_assets];
    #[cfg(target_arch = "wasm32")]
    let compressed_volume_by_asset = Vec::new();
    let mut cycles_eliminated: u32 = 0;
    let mut residual_obligations = Vec::new();

    #[allow(clippy::needless_range_loop)]
    for a in 0..num_assets {
        if (asset_mask & (1u16 << a)) == 0 {
            continue;
        }
        mat.fill(U256::ZERO);
        for ob in obligations {
            if usize::from(ob.asset_id) != a {
                continue;
            }
            let u = usize::from(orig_to_rank[usize::from(ob.debtor)]);
            let v = usize::from(orig_to_rank[usize::from(ob.creditor)]);
            uadd_assign(&mut mat[u * num_accounts + v], &ob.amount_wad)?;
        }

        for start in 0..num_accounts {
            loop {
                let path_len = find_canonical_cycle_bfs(start, num_accounts, &mat, &mut path);
                if path_len == 0 {
                    break;
                }

                let mut bottleneck = U256::MAX;
                for step_idx in 0..path_len {
                    let x = usize::from(path[step_idx]);
                    let y = usize::from(path[(step_idx + 1) % path_len]);
                    let w = &mat[x * num_accounts + y];
                    if cmp_u256(w, &bottleneck).is_lt() {
                        bottleneck = *w;
                    }
                }

                for step_idx in 0..path_len {
                    let x = usize::from(path[step_idx]);
                    let y = usize::from(path[(step_idx + 1) % path_len]);
                    usub_assign(&mut mat[x * num_accounts + y], &bottleneck)?;
                }

                #[cfg(not(target_arch = "wasm32"))]
                {
                    let mut cycle_gross = U256::ZERO;
                    umul_ref(&bottleneck, &U256::from(path_len as u64), &mut cycle_gross)?;
                    uadd_assign(&mut compressed_volume_by_asset[a], &cycle_gross)?;
                }
                cycles_eliminated = cycles_eliminated
                    .checked_add(1)
                    .ok_or(ClearingError::MathOverflow)?;
            }
        }

        for u_rank in 0..num_accounts {
            let u_orig = u16::from(rank_to_orig[u_rank]);
            for v_rank in 0..num_accounts {
                let w = mat[u_rank * num_accounts + v_rank];
                if !w.is_zero() {
                    residual_obligations.push(ObligationEdge {
                        debtor: u_orig,
                        creditor: u16::from(rank_to_orig[v_rank]),
                        asset_id: a as u8,
                        amount_wad: w,
                    });
                }
            }
        }
    }

    Ok(CycleCompressionOutcome {
        cycles_eliminated,
        compressed_volume_by_asset,
        residual_obligations,
    })
}
