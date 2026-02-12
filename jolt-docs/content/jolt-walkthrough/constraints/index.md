+++
title = "Constraints"
weight = 4

[extra]
katex = true
math = true
+++

TODO: THIS IS ONE OF THE MOST IMPORTANT CHAPTERS IN THE THIS DOCUMENT 

Relevant traits
```rust
pub trait LookupQuery<const XLEN: usize> {
    /// Returns a tuple of the instruction's inputs. If the instruction has only one input,
    /// one of the tuple values will be 0.
    fn to_instruction_inputs(&self) -> (u64, i128);

    /// Returns a tuple of the instruction's lookup operands. By default, these are the
    /// same as the instruction inputs returned by `to_instruction_inputs`, but in some cases
    /// (e.g. ADD, MUL) the instruction inputs are combined to form a single lookup operand.
    fn to_lookup_operands(&self) -> (u64, u128) {
        let (x, y) = self.to_instruction_inputs();
        (x, (y as u64) as u128)
    }

    /// Converts this instruction's operands into a lookup index (as used in sparse-dense Shout).
    /// By default, interleaves the two bits of the two operands together.
    fn to_lookup_index(&self) -> u128 {
        let (x, y) = LookupQuery::<XLEN>::to_lookup_operands(self);
        interleave_bits(x, y as u64)
    }

    /// Computes the output lookup entry for this instruction as a u64.
    fn to_lookup_output(&self) -> u64;
}
```

## Per-Cycle R1CS Inputs

Every execution cycle $j$ produces a row of 37 values that feed into the Spartan outer sumcheck. These are the "virtual polynomials" — they are not committed directly but are derived from the committed polynomials (Inc, Ra, advice) and the bytecode preprocessing during proving.

**Source:** `jolt-core/src/zkvm/r1cs/inputs.rs` (struct `R1CSCycleInputs`, lines 200-266; constructed by `from_trace`, lines 272-402)

---

### Instruction Inputs and Product

These fields capture the two operands that an instruction consumes, plus their field-element product.

| Field | Type | Meaning |
|-------|------|---------|
| LeftInstructionInput | u64 | Left operand of the instruction. Either Rs1Value or UnexpandedPC, selected by CircuitFlags. |
| RightInstructionInput | S64 | Right operand (signed-magnitude). Either Rs2Value or Imm, selected by CircuitFlags. |
| Product | S128 | LeftInstructionInput * RightInstructionInput, computed in field via signed-magnitude truncated multiply. Used by MUL/MULH/etc. — these instructions do NOT use a lookup table. |

**How they are computed** (`inputs.rs:295-304`):
```
(left_input, right_i128) = LookupQuery::to_instruction_inputs(cycle)
product = S64(left_input) * S128(right_i128)   // truncated field multiply
```

The selection logic lives in each instruction's `to_instruction_inputs()` implementation. For most ALU instructions: left = rs1, right = rs2 or imm.

---

### Lookup Operands and Output

These fields are the actual operands and result of the Twist/Shout lookup table. They differ from LeftInstructionInput/RightInstructionInput for arithmetic instructions.

| Field | Type | Meaning |
|-------|------|---------|
| LeftLookupOperand | u64 | Left operand fed to the lookup table. For bitwise ops (AND, XOR, etc.): same as LeftInstructionInput. For add/sub/mul: forced to 0 (the combined operand goes in the right). |
| RightLookupOperand | u128 | Right operand fed to the lookup table. For bitwise ops: same as RightInstructionInput (two 64-bit values get interleaved into a 128-bit lookup address). For ADD: Left + Right. For SUB: Left - Right + $2^{64}$. For MUL: Product. |
| LookupOutput | u64 | The lookup table's output for this cycle. For branches, this is 1 (taken) or 0 (not taken). For ALU ops, this is the instruction result. |

**Why LeftLookupOperand vs LeftInstructionInput differ:** For ADD/SUB/MUL, Jolt combines the two instruction operands into a single lookup operand (stored in RightLookupOperand) and zeros out the left. The R1CS constraints enforce this relationship:

- `AddOperands => LeftLookupOperand == 0, RightLookupOperand == Left + Right`
- `SubtractOperands => LeftLookupOperand == 0, RightLookupOperand == Left - Right + 2^64`
- `MultiplyOperands => LeftLookupOperand == 0, RightLookupOperand == Product`
- Otherwise: `LeftLookupOperand == LeftInstructionInput, RightLookupOperand == RightInstructionInput`

---

### Register Values

| Field | Type | Meaning |
|-------|------|---------|
| Rs1Value | u64 | Value read from register rs1 this cycle (0 if no rs1 read). |
| Rs2Value | u64 | Value read from register rs2 this cycle (0 if no rs2 read). |
| RdWriteValue | u64 | Value written to register rd this cycle (0 if no rd write). |

---

### RAM Values

| Field | Type | Meaning |
|-------|------|---------|
| RamAddress | u64 | RAM address accessed this cycle. Non-zero only for Load/Store instructions; enforced by R1CS to equal Rs1Value + Imm when Load or Store. |
| RamReadValue | u64 | For Load: the value at that address. For Store: the pre-write value. For NoOp: 0. |
| RamWriteValue | u64 | For Load: same as RamReadValue (reads don't modify). For Store: the new value written. For NoOp: 0. |

---

### Program Counter

| Field | Type | Meaning |
|-------|------|---------|
| PC | u64 | Expanded PC — the bytecode row index in the preprocessed program table. Used by the bytecode read-RAF sumcheck. |
| NextPC | u64 | Expanded PC of the next cycle. For virtual (inline) sequences: PC + 1. 0 for the last cycle. |
| UnexpandedPC | u64 | The actual RISC-V program counter (instruction address). |
| NextUnexpandedPC | u64 | UnexpandedPC of the next cycle. Updated by R1CS constraints depending on jump/branch/inline. 0 for the last cycle. |

**PC vs UnexpandedPC:** A single RISC-V instruction may expand into multiple "virtual" cycles (e.g., ECALL sequences). All virtual cycles in a sequence share the same UnexpandedPC, but each gets a distinct PC (bytecode row).

---

### Immediate

| Field | Type | Meaning |
|-------|------|---------|
| Imm | S64 | The instruction's immediate operand as signed-magnitude. Decoded from the RISC-V instruction encoding. 0 for R-type instructions that have no immediate. |

---

### Derived Booleans

These are products of other fields. They cannot be computed by R1CS directly (R1CS is linear), so they are proved via the **Product Virtualization** sumcheck (Stage 2a).

| Field | Type | Meaning | Product constraint |
|-------|------|---------|-------------------|
| WriteLookupOutputToRD | bool | Should the lookup output be written to rd? | IsRdNotZero * OpFlags(WriteLookupOutputToRD) |
| WritePCtoRD | bool | Should the return address (PC+4 or PC+2) be written to rd? (JAL/JALR) | IsRdNotZero * OpFlags(Jump) |
| ShouldBranch | bool | Is this a branch that is taken? | LookupOutput * InstructionFlags(Branch) |
| ShouldJump | bool | Is this a jump to a non-noop target? | OpFlags(Jump) * (1 - NextIsNoop) |

---

### Next-Cycle Flags

These look one cycle ahead. They are proved via the **Shift Sumcheck** (Stage 3a), which uses EqPlusOne to relate cycle $j$ to cycle $j+1$.

| Field | Type | Meaning |
|-------|------|---------|
| NextIsNoop | bool | Whether the next cycle is a no-op (padding). Used in ShouldJump. |
| NextIsVirtual | bool | Whether the next cycle is a virtual instruction (part of an inline sequence). |
| NextIsFirstInSequence | bool | Whether the next cycle starts a new virtual sequence. |

---

### Circuit Flags (OpFlags)

14 boolean flags extracted from the bytecode preprocessing for each instruction. These are the "guards" in the R1CS constraints — most constraints are conditional on one or more of these flags.

| Flag | Meaning |
|------|---------|
| AddOperands | Lookup operand is Left + Right (ADD, ADDI, AUIPC, etc.) |
| SubtractOperands | Lookup operand is Left - Right (SUB) |
| MultiplyOperands | Lookup operand is Left * Right (MUL, MULH, etc.) |
| Load | Instruction is a load (LB, LH, LW, LD) |
| Store | Instruction is a store (SB, SH, SW, SD) |
| Jump | Instruction is a jump (JAL, JALR) |
| WriteLookupOutputToRD | The lookup table output should be stored in rd |
| VirtualInstruction | Cycle is part of a virtual inline sequence (Section 6.1 of Jolt paper) |
| Assert | Instruction is an assertion — lookup output must equal 1 |
| DoNotUpdateUnexpandedPC | UnexpandedPC stays the same next cycle (mid-sequence virtual instructions) |
| Advice | Instruction uses untrusted advice (the prover supplies a witness value) |
| IsCompressed | Instruction is a compressed (16-bit) RISC-V instruction — PC increments by 2 instead of 4 |
| IsFirstInSequence | First cycle in a virtual instruction sequence |
| IsLastInSequence | Last cycle in a virtual instruction sequence |

**Source:** `jolt-core/src/zkvm/instruction/mod.rs` (enum `CircuitFlags`, lines 59-89)

---

### Instruction Flags (not in R1CS inputs directly)

These are separate from CircuitFlags and appear only inside product constraints and instruction-level logic:

| Flag | Meaning |
|------|---------|
| LeftOperandIsPC | Left instruction input comes from PC, not Rs1 |
| RightOperandIsImm | Right instruction input comes from Imm, not Rs2 |
| LeftOperandIsRs1Value | Left instruction input comes from Rs1 |
| RightOperandIsRs2Value | Right instruction input comes from Rs2 |
| Branch | Instruction is a conditional branch |
| IsNoop | Cycle is a no-op (padding) |
| IsRdNotZero | Destination register rd is not x0 (writes to x0 are discarded in RISC-V) |

**Source:** `jolt-core/src/zkvm/instruction/mod.rs` (enum `InstructionFlags`, lines 107-122)

---

## Uniform R1CS Constraints

All constraints have the form: $\text{condition} \cdot (\text{left} - \text{right}) = 0$. When the condition is 1, the constraint enforces left == right. When 0, the constraint is trivially satisfied.

**Source:** `jolt-core/src/zkvm/r1cs/constraints.rs` (array `R1CS_CONSTRAINTS`, lines 231-402)

There are 19 constraints total, split into two groups for the univariate-skip optimization:
- **First group** (10 constraints): boolean guard (Az), ~64-bit magnitude difference (Bz)
- **Second group** (9 constraints): potentially wider Bz (~128 bits)

### RAM Constraints

| # | Label | Condition | Enforces |
|---|-------|-----------|----------|
| 1 | RamAddrEqRs1PlusImmIfLoadStore | Load + Store | RamAddress == Rs1Value + Imm |
| 2 | RamAddrEqZeroIfNotLoadStore | 1 - Load - Store | RamAddress == 0 |
| 3 | RamReadEqRamWriteIfLoad | Load | RamReadValue == RamWriteValue |
| 4 | RamReadEqRdWriteIfLoad | Load | RamReadValue == RdWriteValue |
| 5 | Rs2EqRamWriteIfStore | Store | Rs2Value == RamWriteValue |

### Lookup Operand Routing

| # | Label | Condition | Enforces |
|---|-------|-----------|----------|
| 6 | LeftLookupZeroUnlessAddSubMul | Add + Sub + Mul | LeftLookupOperand == 0 |
| 7 | LeftLookupEqLeftInputOtherwise | 1 - Add - Sub - Mul | LeftLookupOperand == LeftInstructionInput |
| 8 | RightLookupAdd | Add | RightLookupOperand == LeftInstructionInput + RightInstructionInput |
| 9 | RightLookupSub | Sub | RightLookupOperand == LeftInstructionInput - RightInstructionInput + $2^{64}$ |
| 10 | RightLookupEqProductIfMul | Mul | RightLookupOperand == Product |
| 11 | RightLookupEqRightInputOtherwise | 1 - Add - Sub - Mul - Advice | RightLookupOperand == RightInstructionInput |

### Assertion

| # | Label | Condition | Enforces |
|---|-------|-----------|----------|
| 12 | AssertLookupOne | Assert | LookupOutput == 1 |

### Register Write Routing

| # | Label | Condition | Enforces |
|---|-------|-----------|----------|
| 13 | RdWriteEqLookupIfWriteLookupToRd | WriteLookupOutputToRD | RdWriteValue == LookupOutput |
| 14 | RdWriteEqPCPlusConstIfWritePCtoRD | WritePCtoRD | RdWriteValue == UnexpandedPC + 4 - 2*IsCompressed |

### Program Counter Update

| # | Label | Condition | Enforces |
|---|-------|-----------|----------|
| 15 | NextUnexpPCEqLookupIfShouldJump | ShouldJump | NextUnexpandedPC == LookupOutput |
| 16 | NextUnexpPCEqPCPlusImmIfShouldBranch | ShouldBranch | NextUnexpandedPC == UnexpandedPC + Imm |
| 17 | NextUnexpPCUpdateOtherwise | 1 - ShouldBranch - Jump | NextUnexpandedPC == UnexpandedPC + 4 - 4*DoNotUpdatePC - 2*IsCompressed |

### Virtual Instruction Sequencing

| # | Label | Condition | Enforces |
|---|-------|-----------|----------|
| 18 | NextPCEqPCPlusOneIfInline | VirtualInstruction - IsLastInSequence | NextPC == PC + 1 |
| 19 | MustStartSequenceFromBeginning | NextIsVirtual - NextIsFirstInSequence | 1 == DoNotUpdateUnexpandedPC |

---

## Product Constraints

These are proved in Stage 2a (Product Virtualization). Each is a multiplication that R1CS cannot express linearly.

**Source:** `jolt-core/src/zkvm/r1cs/constraints.rs` (array `PRODUCT_CONSTRAINTS`, lines 567-611)

| # | Output | Left Factor | Right Factor |
|---|--------|-------------|--------------|
| 0 | Product | LeftInstructionInput | RightInstructionInput |
| 1 | WriteLookupOutputToRD | IsRdNotZero | OpFlags(WriteLookupOutputToRD) |
| 2 | WritePCtoRD | IsRdNotZero | OpFlags(Jump) |
| 3 | ShouldBranch | LookupOutput | InstructionFlags(Branch) |
| 4 | ShouldJump | OpFlags(Jump) | 1 - NextIsNoop |

---

## Advice

Advice values are prover-supplied witness values that bypass the normal instruction lookup pipeline. They exist because some computations (e.g., cryptographic primitives via jolt-inlines) are more efficient to verify than to prove through the standard lookup tables.

**Source:** `jolt-core/src/zkvm/instruction/virtual_advice.rs`, `virtual_advice_load.rs`, `virtual_advice_len.rs`

### How Advice Differs from Normal Instructions

For a normal ALU instruction (e.g., AND):
1. Instruction inputs (rs1, rs2) become lookup operands
2. The lookup table computes the result
3. R1CS constrains RightLookupOperand == RightInstructionInput (constraint #11)

For an advice instruction:
1. Instruction inputs are (0, 0) — no real operands
2. The prover supplies an arbitrary value as the lookup operand
3. Constraint #11 is **disabled** (the `Advice` flag removes it from the guard)
4. The lookup goes through a **RangeCheckTable** — only verifying the value is in range, not that it's the correct computation
5. The lookup output (= the advice value) is written to rd via WriteLookupOutputToRD

The prover can put any in-range value into the advice slot. Correctness of the advice value is enforced **externally** — by the advice commitment and the claim reduction sumchecks (Stages 6-7), which prove the advice polynomial is consistent with what the prover committed to.

### Trusted vs Untrusted Advice

| Aspect | TrustedAdvice | UntrustedAdvice |
|--------|---------------|-----------------|
| Committed when | Preprocessing (before proving) | During proving |
| Verifier has commitment | Yes (from preprocessing) | No (reads it from proof) |
| Use case | Data known before execution (e.g., precomputed tables, program constants) | Data determined at proof time (e.g., intermediate computation results) |
| Dory context | `DoryContext::TrustedAdvice` | `DoryContext::UntrustedAdvice` |

**Source:** `jolt-core/src/zkvm/prover.rs` (lines 640-695 for commitment; lines 1600-1626 for preprocessing)

Both live in the I/O region of the memory layout, each with a dedicated address range:

**Source:** `common/src/jolt_device.rs` (lines 192-197)
```
trusted_advice_start .. trusted_advice_end
untrusted_advice_start .. untrusted_advice_end
```

The JoltDevice reads from these address ranges during emulation (`jolt_device.rs:65-77`). The data is supplied as `Vec<u8>` via `program_io.trusted_advice` and `program_io.untrusted_advice`.

### Advice Instructions

All three set `CircuitFlags::Advice = true` and `CircuitFlags::WriteLookupOutputToRD = true`. All use `RangeCheckTable` as their lookup table.

| Instruction | Lookup operand | What it does |
|-------------|---------------|--------------|
| VirtualAdvice | `self.advice` (a u64 field on the instruction) | Loads a direct advice value into rd. The value is baked into the instruction by the compiler/inliner. |
| VirtualAdviceLoad | `self.register_state.rd.1` (rd post-execution value) | Reads from the advice tape at runtime. The emulator calls `advice_tape_read()` to pop bytes from a FIFO tape, then the read value becomes the lookup operand. |
| VirtualAdviceLen | rd post-execution value | Returns the number of remaining bytes on the advice tape. |

### How Advice is Proved (Stages 6-7)

**Source:** `jolt-core/src/zkvm/claim_reductions/advice.rs`

The advice polynomial is a multilinear extension of the advice data, embedded as a Dory matrix. The claim reduction happens in two phases:

**Phase 1 (Stage 6 — Cycle Variables):** Binds cycle-derived coordinates of the advice evaluation point. Outputs an intermediate scalar claim.

**Phase 2 (Stage 7 — Address Variables):** Binds address-derived coordinates. Caches the final advice opening for the batched Dory opening in Stage 8.

Trusted and untrusted advice run as **separate sumcheck instances** (they may have different Dory matrix dimensions). Both ultimately produce openings that get batched into the Stage 8 Dory opening proof.

### Advice Tape (Runtime Mechanism)

**Source:** `tracer/src/emulator/cpu.rs` (lines 73-84)

The advice tape is a FIFO buffer on the CPU:
- `advice_tape_write(cpu, bytes)` — pushes bytes (used by jolt-inlines to provide intermediate results)
- `advice_tape_read(cpu, num_bytes)` — pops bytes (used by VirtualAdviceLoad)
- `advice_tape_remaining(cpu)` — returns remaining count (used by VirtualAdviceLen)

This is how jolt-inlines work: the inline implementation writes precomputed results to the advice tape, then a sequence of VirtualAdviceLoad instructions reads them back and stores them in registers. The proof system verifies the values are consistent with the committed advice polynomial, and the R1CS + lookup constraints verify they're in range.
