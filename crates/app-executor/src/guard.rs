//! Write rules for imported L1 accounts, enforced when a write is attempted (an inspector),
//! not by filtering the final diff:
//!
//! | Attempt | Rule |
//! |---|---|
//! | `SSTORE` in an imported storage context (the frame's target address, so DELEGATECALL is checked against the proxy's storage, not the library's) | L1 value at the pin proven non-zero: the frame reverts with `L1SlotProtected(account, slot)`. Proven zero: allowed, into the overlay. Not fetchable: the whole transaction fails (no frame can catch it) |
//! | `SSTORE` under STATICCALL | Untouched here: the EVM's own static rule refuses it |
//! | A value transfer from or to an imported account (CALL, CALLCODE, the transaction itself) | reverts with `L1AccountProtected(account)` |
//! | `CREATE`/`CREATE2` by an imported account (its nonce would change) | reverts with `L1AccountProtected(account)` |
//! | `SELFDESTRUCT` of, or paying, an imported account | reverts with `L1AccountProtected(account)` |
//!
//! Zero doesn't mean unused: a zero flag or mapping entry of an L1 contract can matter, and
//! an overlay write there makes the app's copy diverge from L1 on purpose.

use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{SolError, sol};
use revm::{
    Inspector,
    context_interface::ContextTr,
    handler::MainnetContext,
    interpreter::{
        CallInputs, CallOutcome, CreateInputs, CreateOutcome, Gas, InstructionResult, Interpreter,
        InterpreterAction, InterpreterResult,
        interpreter_types::{InputsTr, Jumps, LoopControl, RuntimeFlag},
    },
};

use crate::db::{Db, DbError};

sol! {
    error L1SlotProtected(address account, bytes32 slot);
    error L1AccountProtected(address account);
}

const SSTORE: u8 = 0x55;
const SELFDESTRUCT: u8 = 0xff;

#[derive(Default)]
pub struct Guard {
    /// A base value that couldn't be fetched and verified: the transaction must fail.
    pub fault: Option<DbError>,
}

fn revert_data(data: Vec<u8>) -> Bytes {
    Bytes::from(data)
}

fn slot_protected(account: Address, slot: U256) -> Bytes {
    revert_data(
        L1SlotProtected {
            account,
            slot: slot.into(),
        }
        .abi_encode(),
    )
}

fn account_protected(account: Address) -> Bytes {
    revert_data(L1AccountProtected { account }.abi_encode())
}

fn revert(interp: &mut Interpreter, data: Bytes) {
    let gas = interp.gas;
    interp.bytecode.set_action(InterpreterAction::new_return(
        InstructionResult::Revert,
        data,
        gas,
    ));
}

impl<'a> Inspector<MainnetContext<Db<'a>>> for Guard {
    fn step(&mut self, interp: &mut Interpreter, ctx: &mut MainnetContext<Db<'a>>) {
        let op = interp.bytecode.opcode();
        if op != SSTORE && op != SELFDESTRUCT {
            return;
        }
        if interp.runtime_flag.is_static() {
            return; // the EVM refuses state changes under STATICCALL itself
        }
        let target = interp.input.target_address();
        let db = &mut *ctx.db_mut().0;
        if op == SELFDESTRUCT {
            let beneficiary = interp
                .stack
                .peek(0)
                .map(|v| Address::from_word(v.into()))
                .unwrap_or_default();
            for a in [target, beneficiary] {
                if db.is_imported(&a) {
                    return revert(interp, account_protected(a));
                }
            }
            return;
        }
        if !db.is_imported(&target) {
            return;
        }
        let Ok(slot) = interp.stack.peek(0) else {
            return;
        };
        match db.base_slot(target, slot) {
            Ok(v) if v.is_zero() => {}
            Ok(_) => revert(interp, slot_protected(target, slot)),
            Err(e) => {
                self.fault = Some(e);
                interp.halt_fatal();
            }
        }
    }

    fn call(
        &mut self,
        ctx: &mut MainnetContext<Db<'a>>,
        inputs: &mut CallInputs,
    ) -> Option<CallOutcome> {
        if !inputs.transfers_value() {
            return None;
        }
        let db = &*ctx.db().0;
        let hit = [inputs.transfer_from(), inputs.transfer_to()]
            .into_iter()
            .find(|a| db.is_imported(a))?;
        Some(CallOutcome::new(
            InterpreterResult {
                result: InstructionResult::Revert,
                output: account_protected(hit),
                gas: Gas::new(inputs.gas_limit),
            },
            inputs.return_memory_offset.clone(),
        ))
    }

    fn create(
        &mut self,
        ctx: &mut MainnetContext<Db<'a>>,
        inputs: &mut CreateInputs,
    ) -> Option<CreateOutcome> {
        let caller = inputs.caller();
        if !ctx.db().0.is_imported(&caller) {
            return None;
        }
        Some(CreateOutcome::new(
            InterpreterResult {
                result: InstructionResult::Revert,
                output: account_protected(caller),
                gas: Gas::new(inputs.gas_limit()),
            },
            None,
        ))
    }
}
