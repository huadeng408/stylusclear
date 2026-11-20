//! Dual-target Arbitrum Stylus `vm_hooks` HostIO bridge & deterministic offline `TestVM`.
//! - On `wasm32`: binds directly to canonical Arbitrum Stylus `"vm_hooks"` HostIO imports
//!   with `mini-alloc` (`0.8.4`) and zero `stylus-sdk` macro bloat (`AIP-31605` reproducible).
//! - On non-`wasm32`: provides a thread-local `TestVM` with realistic Ink metering, storage
//!   emulation, code-size simulation, and external ERC-20/precompile call mocking.

#![cfg_attr(target_arch = "wasm32", no_std)]

extern crate alloc;
#[cfg(target_arch = "wasm32")]
use alloc::vec;

use alloc::vec::Vec;
use alloy_primitives::{Address, B256, U256};

#[cfg(target_arch = "wasm32")]
#[global_allocator]
static ALLOC: mini_alloc::MiniAlloc = mini_alloc::MiniAlloc::INIT;

#[cfg(all(target_arch = "wasm32", not(test)))]
#[panic_handler]
fn panic_handler(_info: &core::panic::PanicInfo<'_>) -> ! {
    core::arch::wasm32::unreachable()
}

#[cfg(target_arch = "wasm32")]
mod wasm_ffi {
    #[link(wasm_import_module = "vm_hooks")]
    extern "C" {
        pub fn read_args(dest: *mut u8);
        pub fn write_result(data: *const u8, len: usize);
        pub fn storage_load_bytes32(key: *const u8, dest: *mut u8);
        pub fn storage_cache_bytes32(key: *const u8, value: *const u8);
        pub fn storage_flush_cache(clear: bool);
        pub fn native_keccak256(bytes: *const u8, len: usize, output: *mut u8);
        pub fn account_code_size(address: *const u8) -> usize;
        pub fn call_contract(
            contract: *const u8,
            calldata: *const u8,
            calldata_len: usize,
            value: *const u8,
            gas: u64,
            return_data_len: *mut usize,
        ) -> u8;
        pub fn static_call_contract(
            contract: *const u8,
            calldata: *const u8,
            calldata_len: usize,
            gas: u64,
            return_data_len: *mut usize,
        ) -> u8;
        pub fn read_return_data(dest: *mut u8, offset: usize, size: usize) -> usize;
        pub fn emit_log(data: *const u8, len: usize, topics: usize);
        pub fn msg_reentrant() -> bool;
        pub fn msg_sender(sender: *mut u8);
        pub fn msg_value(value: *mut u8);
        pub fn contract_address(address: *mut u8);
        pub fn chainid() -> u64;
        pub fn block_timestamp() -> u64;
        pub fn evm_ink_left() -> u64;
        pub fn tx_ink_price() -> u32;
        pub fn pay_for_memory_grow(pages: u16);
    }

    #[no_mangle]
    pub extern "C" fn mark_used() {
        unsafe {
            pay_for_memory_grow(0);
        }
    }
}

#[cfg(target_arch = "wasm32")]
pub fn run_wasm_entrypoint<F>(args_len: usize, handler: F) -> i32
where
    F: FnOnce(&[u8]) -> Result<Vec<u8>, Vec<u8>>,
{
    let mut input = vec![0u8; args_len];
    if args_len > 0 {
        unsafe {
            wasm_ffi::read_args(input.as_mut_ptr());
        }
    }
    match handler(&input) {
        Ok(out) => {
            unsafe {
                wasm_ffi::storage_flush_cache(false);
                wasm_ffi::write_result(out.as_ptr(), out.len());
            }
            0
        }
        Err(err) => {
            unsafe {
                wasm_ffi::write_result(err.as_ptr(), err.len());
            }
            1
        }
    }
}

#[derive(Clone, Copy, Default)]
pub struct HostEnv;

#[cfg(target_arch = "wasm32")]
impl HostEnv {
    #[inline]
    pub fn msg_reentrant(&self) -> bool {
        unsafe { wasm_ffi::msg_reentrant() }
    }

    #[inline(never)]
    pub fn msg_sender(&self) -> Address {
        let mut out = [0u8; 20];
        unsafe {
            wasm_ffi::msg_sender(out.as_mut_ptr());
        }
        Address::new(out)
    }

    #[inline(never)]
    pub fn msg_value(&self) -> U256 {
        let mut out = [0u8; 32];
        unsafe {
            wasm_ffi::msg_value(out.as_mut_ptr());
        }
        U256::from_be_bytes(out)
    }

    #[inline(never)]
    pub fn contract_address(&self) -> Address {
        let mut out = [0u8; 20];
        unsafe {
            wasm_ffi::contract_address(out.as_mut_ptr());
        }
        Address::new(out)
    }

    #[inline]
    pub fn chain_id(&self) -> u64 {
        unsafe { wasm_ffi::chainid() }
    }

    #[inline]
    pub fn block_timestamp(&self) -> u64 {
        unsafe { wasm_ffi::block_timestamp() }
    }

    #[inline]
    pub fn evm_ink_left(&self) -> u64 {
        unsafe { wasm_ffi::evm_ink_left() }
    }

    #[inline]
    pub fn ink_to_gas(&self, ink: u64) -> u64 {
        let price = u64::from(unsafe { wasm_ffi::tx_ink_price() });
        ink.checked_div(price).unwrap_or(0)
    }

    #[inline(never)]
    pub fn native_keccak256(&self, bytes: &[u8]) -> B256 {
        let mut out = [0u8; 32];
        unsafe {
            wasm_ffi::native_keccak256(bytes.as_ptr(), bytes.len(), out.as_mut_ptr());
        }
        B256::new(out)
    }

    #[inline(never)]
    fn word_slot(&self, key: &[u8; 32]) -> [u8; 32] {
        let mut buf = [0u8; 64];
        let mut i = 0;
        while i < 32 {
            buf[i] = key[i];
            i += 1;
        }
        self.native_keccak256(&buf).0
    }

    #[inline(never)]
    pub fn sload(&self, key: &[u8; 32]) -> [u8; 32] {
        let slot = self.word_slot(key);
        let mut out = [0u8; 32];
        unsafe {
            wasm_ffi::storage_load_bytes32(slot.as_ptr(), out.as_mut_ptr());
        }
        out
    }

    #[inline(never)]
    pub fn sstore(&self, key: &[u8; 32], val: &[u8; 32]) {
        let slot = self.word_slot(key);
        unsafe {
            wasm_ffi::storage_cache_bytes32(slot.as_ptr(), val.as_ptr());
        }
    }

    #[inline]
    pub fn account_code_size(&self, addr: Address) -> usize {
        unsafe { wasm_ffi::account_code_size(addr.as_slice().as_ptr()) }
    }

    #[inline(never)]
    fn raw_call(&self, to: Address, data: &[u8], is_static: bool) -> Option<Vec<u8>> {
        let mut ret_len: usize = 0;
        let status = unsafe {
            wasm_ffi::storage_flush_cache(!is_static);
            if is_static {
                wasm_ffi::static_call_contract(
                    to.as_slice().as_ptr(),
                    data.as_ptr(),
                    data.len(),
                    u64::MAX,
                    &mut ret_len as *mut usize,
                )
            } else {
                let zero_val = [0u8; 32];
                wasm_ffi::call_contract(
                    to.as_slice().as_ptr(),
                    data.as_ptr(),
                    data.len(),
                    zero_val.as_ptr(),
                    u64::MAX,
                    &mut ret_len as *mut usize,
                )
            }
        };
        const MAX_RETURN_DATA_BYTES: usize = 64;
        if status != 0 || ret_len > MAX_RETURN_DATA_BYTES {
            return None;
        }
        let mut ret = vec![0u8; ret_len];
        if ret_len > 0 {
            unsafe {
                wasm_ffi::read_return_data(ret.as_mut_ptr(), 0, ret_len);
            }
        }
        Some(ret)
    }

    #[inline]
    pub fn static_call(&self, to: Address, data: &[u8]) -> Option<Vec<u8>> {
        self.raw_call(to, data, true)
    }

    #[inline]
    pub fn call_zero_value(&self, to: Address, data: &[u8]) -> Option<Vec<u8>> {
        self.raw_call(to, data, false)
    }

    #[inline(never)]
    pub fn emit_log(&self, data: &[u8], topics: usize) {
        unsafe {
            wasm_ffi::emit_log(data.as_ptr(), data.len(), topics);
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
mod host_mock {
    use super::*;
    use alloy_primitives::keccak256;
    use std::cell::RefCell;
    use std::collections::HashMap;

    type MockCallResult = Result<Vec<u8>, Vec<u8>>;
    type StaticMockMap = HashMap<(Address, Vec<u8>), MockCallResult>;
    type MutatingMockMap = HashMap<(Address, Vec<u8>, U256), MockCallResult>;

    struct MockHostState {
        storage: HashMap<[u8; 32], [u8; 32]>,
        code_sizes: HashMap<Address, usize>,
        sender: Address,
        contract_addr: Address,
        block_timestamp: u64,
        chain_id: u64,
        reentrant: bool,
        msg_value: U256,
        ink_left: u64,
        tx_ink_price: u32,
        logs: Vec<(usize, Vec<u8>)>,
        static_mocks: StaticMockMap,
        call_mocks: MutatingMockMap,
    }

    impl MockHostState {
        fn new_clean() -> Self {
            Self {
                storage: HashMap::new(),
                code_sizes: HashMap::new(),
                sender: Address::repeat_byte(0x01),
                contract_addr: Address::repeat_byte(0xC0),
                block_timestamp: 1_000,
                chain_id: 421_614,
                reentrant: false,
                msg_value: U256::ZERO,
                ink_left: 5_000_000_000,
                tx_ink_price: 10_000,
                logs: Vec::new(),
                static_mocks: HashMap::new(),
                call_mocks: HashMap::new(),
            }
        }
    }

    thread_local! {
        static HOST_STATE: RefCell<MockHostState> = RefCell::new(MockHostState::new_clean());
    }

    #[derive(Clone, Default)]
    pub struct TestVM;

    impl TestVM {
        pub fn new() -> Self {
            HOST_STATE.with(|st| *st.borrow_mut() = MockHostState::new_clean());
            Self
        }

        pub fn contract_address(&self) -> Address {
            HOST_STATE.with(|st| st.borrow().contract_addr)
        }

        pub fn set_contract_address(&self, addr: Address) {
            HOST_STATE.with(|st| st.borrow_mut().contract_addr = addr);
        }

        pub fn set_sender(&self, sender: Address) {
            HOST_STATE.with(|st| st.borrow_mut().sender = sender);
        }

        pub fn set_block_timestamp(&self, ts: u64) {
            HOST_STATE.with(|st| st.borrow_mut().block_timestamp = ts);
        }

        pub fn set_chain_id(&self, cid: u64) {
            HOST_STATE.with(|st| st.borrow_mut().chain_id = cid);
        }

        pub fn set_reentrant(&self, reentrant: bool) {
            HOST_STATE.with(|st| st.borrow_mut().reentrant = reentrant);
        }

        pub fn set_msg_value(&self, val: U256) {
            HOST_STATE.with(|st| st.borrow_mut().msg_value = val);
        }

        pub fn set_code_size(&self, addr: Address, size: usize) {
            HOST_STATE.with(|st| {
                st.borrow_mut().code_sizes.insert(addr, size);
            });
        }

        pub fn mock_static_call(&self, to: Address, data: Vec<u8>, ret: MockCallResult) {
            HOST_STATE.with(|st| {
                st.borrow_mut().static_mocks.insert((to, data), ret);
            });
        }

        pub fn mock_call(&self, to: Address, data: Vec<u8>, value: U256, ret: MockCallResult) {
            HOST_STATE.with(|st| {
                let mut s = st.borrow_mut();
                s.code_sizes.entry(to).or_insert(128);
                s.call_mocks.insert((to, data, value), ret);
            });
        }

        pub fn emitted_logs(&self) -> Vec<(usize, Vec<u8>)> {
            HOST_STATE.with(|st| st.borrow().logs.clone())
        }
    }

    impl HostEnv {
        pub fn msg_reentrant(&self) -> bool {
            HOST_STATE.with(|st| st.borrow().reentrant)
        }

        pub fn msg_sender(&self) -> Address {
            HOST_STATE.with(|st| st.borrow().sender)
        }

        pub fn msg_value(&self) -> U256 {
            HOST_STATE.with(|st| st.borrow().msg_value)
        }

        pub fn contract_address(&self) -> Address {
            HOST_STATE.with(|st| st.borrow().contract_addr)
        }

        pub fn chain_id(&self) -> u64 {
            HOST_STATE.with(|st| st.borrow().chain_id)
        }

        pub fn block_timestamp(&self) -> u64 {
            HOST_STATE.with(|st| st.borrow().block_timestamp)
        }

        pub fn evm_ink_left(&self) -> u64 {
            HOST_STATE.with(|st| {
                let mut s = st.borrow_mut();
                s.ink_left = s.ink_left.saturating_sub(1_000);
                s.ink_left
            })
        }

        pub fn ink_to_gas(&self, ink: u64) -> u64 {
            HOST_STATE.with(|st| {
                let p = u64::from(st.borrow().tx_ink_price);
                ink.checked_div(p).unwrap_or(0)
            })
        }

        pub fn native_keccak256(&self, bytes: &[u8]) -> B256 {
            keccak256(bytes)
        }

        fn word_slot(&self, key: &[u8; 32]) -> [u8; 32] {
            let mut buf = [0u8; 64];
            buf[0..32].copy_from_slice(key);
            keccak256(buf).0
        }

        pub fn sload(&self, key: &[u8; 32]) -> [u8; 32] {
            let slot = self.word_slot(key);
            HOST_STATE.with(|st| st.borrow().storage.get(&slot).copied().unwrap_or([0u8; 32]))
        }

        pub fn sstore(&self, key: &[u8; 32], val: &[u8; 32]) {
            let slot = self.word_slot(key);
            HOST_STATE.with(|st| {
                if *val == [0u8; 32] {
                    st.borrow_mut().storage.remove(&slot);
                } else {
                    st.borrow_mut().storage.insert(slot, *val);
                }
            });
        }

        pub fn account_code_size(&self, addr: Address) -> usize {
            HOST_STATE.with(|st| st.borrow().code_sizes.get(&addr).copied().unwrap_or(0))
        }

        pub fn static_call(&self, to: Address, data: &[u8]) -> Option<Vec<u8>> {
            HOST_STATE.with(|st| {
                let mut s = st.borrow_mut();
                s.ink_left = s.ink_left.saturating_sub(30_000_000);
                match s.static_mocks.get(&(to, data.to_vec())).cloned() {
                    Some(Ok(ret)) => Some(ret),
                    _ => None,
                }
            })
        }

        pub fn call_zero_value(&self, to: Address, data: &[u8]) -> Option<Vec<u8>> {
            HOST_STATE.with(|st| {
                let s = st.borrow();
                match s.call_mocks.get(&(to, data.to_vec(), U256::ZERO)).cloned() {
                    Some(Ok(ret)) => Some(ret),
                    _ => None,
                }
            })
        }

        pub fn emit_log(&self, data: &[u8], topics: usize) {
            HOST_STATE.with(|st| st.borrow_mut().logs.push((topics, data.to_vec())));
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub use host_mock::TestVM;
