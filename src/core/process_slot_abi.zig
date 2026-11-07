// SPDX-License-Identifier: BSD-2-Clause
//! Shared ABI for the statically provisioned Phase 8 execution slot.

pub const state_address: usize = 0x4200_0000;
pub const stack_bottom: u64 = 0x4300_0000;
pub const stack_size: u64 = 0x4000;
pub const stack_top: u64 = stack_bottom + stack_size;

pub const ready_magic: u64 = 0x5a57_4549_4753_4c54;
pub const result_magic: u64 = 0x5048_4153_4538_4f4b;
pub const max_runs: u64 = 1024;

pub const SharedState = extern struct {
    magic: u64,
    entry: u64,
    entry_page: u64,
    run_count: u64,
    last_result: u64,
};
