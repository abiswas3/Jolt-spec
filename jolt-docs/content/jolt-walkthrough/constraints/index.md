+++
title = "R1CS Constraints"
weight = 4

[extra]
katex = true
math = true
+++

To recall, the five data structures from the [Emulation](@/jolt-walkthrough/2_emulation/index.md) chapter are:

1. **`RdInc`** — Register increment array (length $T$)
2. **`RamInc`** — RAM increment array (length $T$)
3. **`BytecodeRa(d)`** — Bytecode address one-hot matrices ($d$ matrices of dimension $T \times K^{1/d}$)
4. **`RamRa(d)`** — RAM address one-hot matrices ($d$ matrices of dimension $T \times K^{1/d}$)
5. **`InstructionRa(d)`** — Instruction lookup address one-hot matrices ($d$ matrices of dimension $T \times K^{1/d}$)

We will park them for a minute and proceed to the next computation from the `trace`.
Before that, we discuss some notation.

{% theorem(type="box", title="Vectors as Functions") %}

**Vectors as Functions**

Recapping from the [Emulation](@/jolt-walkthrough/2_emulation/index.md) chapter, we have arrays of length $T$ containing `u64` integers, or one-hot encoded matrices of size $T \times K$ (or $d$ of them, each of size $T \times K^{1/d}$). Note that $T$ and $K$ are always powers of 2.

We will often refer to arrays/vectors as functions and vice versa. Here is what we mean:

Let $\FF$ denote a finite field large enough to hold `u64` values without overflow (in Jolt, $\FF$ can hold 256-bit numbers). We write $[T] = \range{T}$.
Given a vector $\mathbf{a} \in \FF^T$, we define the associated function $f_{\mathbf{a}}: \hypercube{T} \rightarrow \FF$ by

$$
f_{\mathbf{a}}(\bin{i}) = \mathbf{a}[i] \quad \forall \, i \in [T]
$$

where $\bin{i} \in \bit^{\log_2 T}$ is the binary representation of $i$.

For example, let $T = 8$ and $\mathbf{a} = [5, 3, 7, 1, 0, 9, 2, 6]$. Then $f_{\mathbf{a}}: \bit^3 \rightarrow \FF$ and:

```
  Vector (array)            Function
  index | value             input    | output
  ------+------             ---------+-------
    0   |  5                f(0,0,0) |  5
    1   |  3                f(0,0,1) |  3
    2   |  7                f(0,1,0) |  7
    3   |  1                f(0,1,1) |  1
    4   |  0                f(1,0,0) |  0
    5   |  9                f(1,0,1) |  9
    6   |  2                f(1,1,0) |  2
    7   |  6                f(1,1,1) |  6
        ^                       ^
      a[i]                  f(<i>_2)
```

It is the same data expressed in function notation. What will be critical is that we can extend $f_{\mathbf{a}}$ to its multilinear extension $\mle{f_{\mathbf{a}}}: \FFlog{T} \rightarrow \FF$, which agrees with $f_{\mathbf{a}}$ on all Boolean inputs but is defined over all of $\FFlog{T}$. See TODO: Add citation about Justin's book.

{% end %}


## R1CS Inputs Data Structure

With that out of the way, we describe the next important data structure -- `R1CSCycleInputs`.

```rust
/// Fully materialized, typed view of all R1CS inputs for a single row (cycle).
/// Filled once and reused to evaluate all constraints without re-reading the trace.
/// Total size: 208 bytes, alignment: 16 bytes
#[derive(Clone, Debug)]
pub struct R1CSCycleInputs {
    /// Left instruction input as a u64 bit-pattern.
    /// Typically `Rs1Value` or the current `UnexpandedPC`, depending on `CircuitFlags`.
    pub left_input: u64,
    /// Right instruction input as signed-magnitude `S64`.
    /// Typically `Imm` or `Rs2Value` with exact integer semantics.
    pub right_input: S64,
    /// Signed-magnitude `S128` product consistent with the `Product` witness.
    /// Computed from `left_input` × `right_input` using the same truncation semantics as the witness.
    pub product: S128,

    /// Left lookup operand (u64) for the instruction lookup query.
    /// Matches `LeftLookupOperand` virtual polynomial semantics.
    pub left_lookup: u64,
    /// Right lookup operand (u128) for the instruction lookup query.
    /// Full-width integer encoding used by add/sub/mul/advice cases.
    pub right_lookup: u128,
    /// Instruction lookup output (u64) for this cycle.
    pub lookup_output: u64,

    /// Value read from Rs1 in this cycle.
    pub rs1_read_value: u64,
    /// Value read from Rs2 in this cycle.
    pub rs2_read_value: u64,
    /// Value written to Rd in this cycle.
    pub rd_write_value: u64,

    /// RAM address accessed this cycle.
    pub ram_addr: u64,
    /// RAM read value for `Read`, pre-write value for `Write`, or 0 for `NoOp`.
    pub ram_read_value: u64,
    /// RAM write value: equals read value for `Read`, post-write value for `Write`, or 0 for `NoOp`.
    pub ram_write_value: u64,

    /// Expanded PC used by bytecode instance.
    pub pc: u64,
    /// Expanded PC for next cycle, or 0 if this is the last cycle in the domain.
    pub next_pc: u64,
    /// Unexpanded PC (normalized instruction address) for this cycle.
    pub unexpanded_pc: u64,
    /// Unexpanded PC for next cycle, or 0 if this is the last cycle in the domain.
    pub next_unexpanded_pc: u64,

    /// Immediate operand as signed-magnitude `S64`.
    pub imm: S64,

    /// Per-instruction circuit flags indexed by `CircuitFlags`.
    pub flags: [bool; NUM_CIRCUIT_FLAGS],
    /// `IsNoop` flag for the next cycle (false for last cycle).
    pub next_is_noop: bool,

    /// Derived: `Jump && !NextIsNoop`.
    pub should_jump: bool,
    /// Derived: `Branch && (LookupOutput == 1)`.
    pub should_branch: bool,

    /// `IsRdNotZero` && ` `WriteLookupOutputToRD`
    pub write_lookup_output_to_rd_addr: bool,
    /// `IsRdNotZero` && `Jump`
    pub write_pc_to_rd_addr: bool,

    /// `VirtualInstruction` flag for the next cycle (false for last cycle).
    pub next_is_virtual: bool,
    /// `FirstInSequence` flag for the next cycle (false for last cycle).
    pub next_is_first_in_sequence: bool,
}
```
 
TODO: (ari) PICTURE

Each field of `R1CSCycleInputs` is populated from the execution trace. The full construction lives in TODO: filepath. We walk through each field below.

### Instruction Inputs and Product

`left_input` is the left operand (typically `Rs1Value` or `UnexpandedPC`), `right_input` is the right operand as signed-magnitude (typically `Rs2Value` or `Imm`), and `product` is their truncated field multiply (used by MUL/MULH).

```rust
let (left_input, right_i128) = LookupQuery::<XLEN>::to_instruction_inputs(cycle);
let right_input = S64::from_u64_with_sign(right_i128.unsigned_abs() as u64, right_i128 >= 0);
let product: S128 = S64::from_u64(left_input).mul_trunc::<2, 2>(&S128::from_i128(right_i128));
```

### Lookup Operands and Output

`left_lookup` and `right_lookup` are the operands fed to the lookup table. For bitwise ops these match the instruction inputs; for ADD/SUB/MUL the two inputs are combined into `right_lookup` and `left_lookup` is zeroed. `lookup_output` is the table's result.

```rust
let (left_lookup, right_lookup) = LookupQuery::<XLEN>::to_lookup_operands(cycle);
let lookup_output = LookupQuery::<XLEN>::to_lookup_output(cycle);
```

### Register Values

The before/after register values, read directly from the cycle's register state.

```rust
let rs1_read_value = cycle.rs1_read().unwrap_or_default().1;
let rs2_read_value = cycle.rs2_read().unwrap_or_default().1;
let rd_write_value = cycle.rd_write().unwrap_or_default().2;
```

### RAM Values

`ram_addr` is the memory address accessed. For reads, `ram_read_value == ram_write_value` (memory unchanged). For writes, they differ. For NoOps, all zero.

```rust
let ram_addr = cycle.ram_access().address() as u64;
let (ram_read_value, ram_write_value) = match cycle.ram_access() {
    RAMAccess::Read(r)  => (r.value, r.value),
    RAMAccess::Write(w) => (w.pre_value, w.post_value),
    RAMAccess::NoOp     => (0u64, 0u64),
};
```

### Program Counter

`pc` is the expanded bytecode row index; `unexpanded_pc` is the actual RISC-V address. A single RISC-V instruction may expand into multiple virtual cycles that share the same `unexpanded_pc` but have distinct `pc` values. The `next_*` variants look one cycle ahead (0 for the last cycle).

```rust
let pc = bytecode_preprocessing.get_pc(cycle) as u64;
let next_pc = next_cycle.map_or(0u64, |nc| bytecode_preprocessing.get_pc(nc) as u64);
let unexpanded_pc = norm.address as u64;
let next_unexpanded_pc = next_cycle.map_or(0u64, |nc| nc.instruction().normalize().address as u64);
```

### Immediate

The instruction's immediate operand, stored as signed-magnitude.

```rust
let imm_i128 = norm.operands.imm;
let imm = S64::from_u64_with_sign(imm_i128.unsigned_abs() as u64, imm_i128 >= 0);
```

### Circuit Flags

14 boolean flags extracted from the bytecode preprocessing for each instruction. These act as guards in the R1CS constraints.

```rust
let mut flags = [false; NUM_CIRCUIT_FLAGS];
for flag in CircuitFlags::iter() {
    flags[flag] = flags_view[flag];
}
```

### Next-Cycle Flags

These look one cycle ahead and are used for sequencing constraints.

```rust
let next_is_noop = next_cycle.map_or(false, |nc|
    nc.instruction().instruction_flags()[InstructionFlags::IsNoop]);
let (next_is_virtual, next_is_first_in_sequence) = next_cycle.map_or((false, false), |nc| {
    let f = nc.instruction().circuit_flags();
    (f[CircuitFlags::VirtualInstruction], f[CircuitFlags::IsFirstInSequence])
});
```

### Derived Booleans

These are products of other fields. R1CS is linear, so these multiplications are proved via a separate product sumcheck.

```rust
let should_jump = flags[CircuitFlags::Jump] && !next_is_noop;
let should_branch = instruction_flags[InstructionFlags::Branch] && (lookup_output == 1);
let write_lookup_output_to_rd_addr =
    flags[CircuitFlags::WriteLookupOutputToRD] && instruction_flags[InstructionFlags::IsRdNotZero];
let write_pc_to_rd_addr =
    flags[CircuitFlags::Jump] && instruction_flags[InstructionFlags::IsRdNotZero];
```



Now we have all the data structures to define the R1CS constraints.

{% theorem(type="box") %}
The key idea is that "if $P$ then $Q$" can be expressed as a single arithmetic equation. If $P$ is a boolean (0 or 1) and $Q$ is an equality $L = R$, then

$$
P \cdot (L - R) = 0
$$

enforces exactly the right thing: when $P = 1$ the constraint forces $L = R$, and when $P = 0$ the equation holds trivially regardless of $L$ and $R$.
{% end %}

There are 19 constraints, and every single one has this shape. For every timestep $t \in [T]$:

$$
\text{condition}(t) \cdot \big(\text{Left}(t) - \text{Right}(t)\big) = 0
$$

The condition is a boolean derived from the circuit flags, and Left/Right are expressions over the `R1CSCycleInputs` fields.

## R1CS Constraints

The full list of constraints is:

```rust
pub enum R1CSConstraintLabel {
    RamAddrEqRs1PlusImmIfLoadStore,
    RamAddrEqZeroIfNotLoadStore,
    RamReadEqRamWriteIfLoad,
    RamReadEqRdWriteIfLoad,
    Rs2EqRamWriteIfStore,
    LeftLookupZeroUnlessAddSubMul,
    LeftLookupEqLeftInputOtherwise,
    RightLookupAdd,
    RightLookupSub,
    RightLookupEqProductIfMul,
    RightLookupEqRightInputOtherwise,
    AssertLookupOne,
    RdWriteEqLookupIfWriteLookupToRd,
    RdWriteEqPCPlusConstIfWritePCtoRD,
    NextUnexpPCEqLookupIfShouldJump,
    NextUnexpPCEqPCPlusImmIfShouldBranch,
    NextUnexpPCUpdateOtherwise,
    NextPCEqPCPlusOneIfInline,
    MustStartSequenceFromBeginning,
}
```

We group them by what they enforce.

### RAM Constraints

**1. RamAddrEqRs1PlusImmIfLoadStore** — If the instruction is a Load or Store, the RAM address must equal `Rs1Value + Imm`.

```rust
if Load || Store { assert!(RamAddress == Rs1Value + Imm) }
```

**2. RamAddrEqZeroIfNotLoadStore** — If the instruction is neither a Load nor a Store, the RAM address must be zero.

```rust
if !(Load || Store) { assert!(RamAddress == 0) }
```

**3. RamReadEqRamWriteIfLoad** — Loads do not modify memory, so the read and write values must match.

```rust
if Load { assert!(RamReadValue == RamWriteValue) }
```

**4. RamReadEqRdWriteIfLoad** — The value loaded from memory goes into the destination register.

```rust
if Load { assert!(RamReadValue == RdWriteValue) }
```

**5. Rs2EqRamWriteIfStore** — Stores write the value from `Rs2` into memory.

```rust
if Store { assert!(Rs2Value == RamWriteValue) }
```

### Lookup Operand Routing

These constraints route the instruction inputs into the correct lookup operands. For ADD/SUB/MUL, the two inputs are combined into `RightLookupOperand` and `LeftLookupOperand` is zeroed. For all other instructions, the lookup operands match the instruction inputs directly.

**6. LeftLookupZeroUnlessAddSubMul** — Zero out the left lookup operand for combined-operand instructions.

```rust
if Add || Sub || Mul { assert!(LeftLookupOperand == 0) }
```

**7. LeftLookupEqLeftInputOtherwise** — Otherwise, pass through.

```rust
if !(Add || Sub || Mul) { assert!(LeftLookupOperand == LeftInstructionInput) }
```

**8. RightLookupAdd** — For ADD, the right lookup operand is the sum of both inputs.

```rust
if Add { assert!(RightLookupOperand == LeftInstructionInput + RightInstructionInput) }
```

**9. RightLookupSub** — For SUB, the right lookup operand is the difference, shifted by $2^{64}$ to stay unsigned.

```rust
if Sub { assert!(RightLookupOperand == LeftInstructionInput - RightInstructionInput + 2^64) }
```

**10. RightLookupEqProductIfMul** — For MUL, the right lookup operand is the truncated product.

```rust
if Mul { assert!(RightLookupOperand == Product) }
```

**11. RightLookupEqRightInputOtherwise** — For everything else (except Advice, which supplies an arbitrary witness), pass through.

```rust
if !(Add || Sub || Mul || Advice) { assert!(RightLookupOperand == RightInstructionInput) }
```

### Assertion

**12. AssertLookupOne** — Assertion instructions require the lookup output to be 1.

```rust
if Assert { assert!(LookupOutput == 1) }
```

### Register Write Routing

**13. RdWriteEqLookupIfWriteLookupToRd** — If the lookup result should be written to `rd`, enforce it.

```rust
if WriteLookupOutputToRD { assert!(RdWriteValue == LookupOutput) }
```

**14. RdWriteEqPCPlusConstIfWritePCtoRD** — For JAL/JALR, the return address (`PC + 4`, or `PC + 2` for compressed instructions) is written to `rd`.

```rust
if WritePCtoRD { assert!(RdWriteValue == UnexpandedPC + 4 - 2*IsCompressed) }
```

### Program Counter Update

**15. NextUnexpPCEqLookupIfShouldJump** — For jumps (that don't land on a noop), the next PC comes from the lookup output.

```rust
if ShouldJump { assert!(NextUnexpandedPC == LookupOutput) }
```

**16. NextUnexpPCEqPCPlusImmIfShouldBranch** — For taken branches, the next PC is the current PC plus the immediate offset.

```rust
if ShouldBranch { assert!(NextUnexpandedPC == UnexpandedPC + Imm) }
```

**17. NextUnexpPCUpdateOtherwise** — For all other instructions, PC advances by 4 (or 2 if compressed, or 0 if mid-virtual-sequence).

```rust
if !(ShouldBranch || Jump) {
    assert!(NextUnexpandedPC == UnexpandedPC + 4 - 4*DoNotUpdatePC - 2*IsCompressed)
}
```

### Virtual Instruction Sequencing

**18. NextPCEqPCPlusOneIfInline** — Within a virtual instruction sequence (but not the last step), the expanded PC increments by 1.

```rust
if VirtualInstruction && !IsLastInSequence { assert!(NextPC == PC + 1) }
```

**19. MustStartSequenceFromBeginning** — If the next cycle is virtual but not the first in its sequence, then this cycle must have `DoNotUpdateUnexpandedPC` set (i.e., you can only enter a virtual sequence from its beginning).

```rust
if NextIsVirtual && !NextIsFirstInSequence { assert!(DoNotUpdateUnexpandedPC == 1) }
```

### Summary Table

All 19 constraints in one place. Each row enforces $A(t) \cdot B(t) = 0$ for every timestep $t \in \hypercube{T}$. They are split into two groups for the univariate-skip optimization: Group 1 has boolean $A$ and ~64-bit $B$; Group 2 has potentially wider $B$ (~128 bits).

**Group 1** (10 constraints):

| # | Label | $A$ (condition) | $B$ (equality to enforce) |
|---|-------|----------------|--------------------------|
| 1 | RamAddrEqRs1PlusImmIfLoadStore | Load + Store | RamAddress - (Rs1Value + Imm) |
| 2 | RamAddrEqZeroIfNotLoadStore | 1 - Load - Store | RamAddress |
| 3 | RamReadEqRamWriteIfLoad | Load | RamReadValue - RamWriteValue |
| 4 | RamReadEqRdWriteIfLoad | Load | RamReadValue - RdWriteValue |
| 5 | Rs2EqRamWriteIfStore | Store | Rs2Value - RamWriteValue |
| 6 | LeftLookupZeroUnlessAddSubMul | Add + Sub + Mul | LeftLookupOperand |
| 7 | LeftLookupEqLeftInputOtherwise | 1 - Add - Sub - Mul | LeftLookupOperand - LeftInstructionInput |
| 8 | RightLookupAdd | Add | RightLookupOperand - (LeftInstructionInput + RightInstructionInput) |
| 9 | RightLookupSub | Sub | RightLookupOperand - (LeftInstructionInput - RightInstructionInput + $2^{64}$) |
| 10 | RightLookupEqProductIfMul | Mul | RightLookupOperand - Product |

**Group 2** (9 constraints):

| # | Label | $A$ (condition) | $B$ (equality to enforce) |
|---|-------|----------------|--------------------------|
| 11 | RightLookupEqRightInputOtherwise | 1 - Add - Sub - Mul - Advice | RightLookupOperand - RightInstructionInput |
| 12 | AssertLookupOne | Assert | LookupOutput - 1 |
| 13 | RdWriteEqLookupIfWriteLookupToRd | WriteLookupOutputToRD | RdWriteValue - LookupOutput |
| 14 | RdWriteEqPCPlusConstIfWritePCtoRD | WritePCtoRD | RdWriteValue - (UnexpandedPC + 4 - 2*IsCompressed) |
| 15 | NextUnexpPCEqLookupIfShouldJump | ShouldJump | NextUnexpandedPC - LookupOutput |
| 16 | NextUnexpPCEqPCPlusImmIfShouldBranch | ShouldBranch | NextUnexpandedPC - (UnexpandedPC + Imm) |
| 17 | NextUnexpPCUpdateOtherwise | 1 - ShouldBranch - Jump | NextUnexpandedPC - (UnexpandedPC + 4 - 4*DoNotUpdatePC - 2*IsCompressed) |
| 18 | NextPCEqPCPlusOneIfInline | VirtualInstruction - IsLastInSequence | NextPC - (PC + 1) |
| 19 | MustStartSequenceFromBeginning | NextIsVirtual - NextIsFirstInSequence | 1 - DoNotUpdateUnexpandedPC |


## Our First Polynomial Constraint

Remember, we said we will reduce correctness to polynomial equality constraints. We have our first example:

{% math() %}
$$
\begin{aligned}
& \forall t \in \hypercube{T}, b \in \bit, c \in \{-5, \ldots, 4\}: \\\\[10pt]
& \quad A(t, b, c) \cdot B(t, b, c) = 0
\end{aligned}
$$
{% end %}

Here $t$ indexes the timestep, $b \in \bit$ selects the constraint group (0 for Group 1, 1 for Group 2), and $c$ ranges over 10 consecutive integers to index the constraint within each group. Group 1 uses all 10 slots; Group 2 uses 9 (the last is zero-padded).

{% theorem(type="box") %}
**Why $c \in \{-5, \ldots, 4\}$ instead of $c \in \range{10}$ or $c \in \bit^4$?**

This is deliberate. We could index constraints with a binary representation ($c \in \bit^4$, padding to 16 slots) or a natural range ($c \in \range{10}$), but neither would let us exploit the **univariate skip** optimization. 
We will add a blog post detailing this optimisation.

TODO: Univariate skip opts
{% end %}

All this to say: for the prover to have faithfully executed the user program, it must at least satisfy the above constraints.
These alone are not sufficient, but they are necessary.
The way the prover demonstrates satisfaction of these constraints is via the sumcheck protocol, which we cover in future chapters.
However, we sketch the key idea here.

First, instead of the actual functions $A$ and $B$, we work with their multilinear extensions $\mle{A}, \mle{B}: \FF^{\log_2 T + 2} \to \FF$. 
Here the $\log_2 T$ dimensions correspond to times teps $t$, one dimension to $b$ for group index, and one dimension to $c$ for constraint given group and time step. 
If $A(t, b, c) \cdot B(t, b, c) = 0$ for all inputs $(t, b, c) \in \hypercube{T} \times \bit \times \\{-5, \ldots, 4\\}$, then $\mle{A} \cdot \mle{B}$ is a zero polynomial on that domain. 
The verifier checks this by sampling a random point $\tau = (\tau_t, \tau_b, \tau_c) \in \FF^{\log_2 T + 2}$ and verifying:

{% math() %}
\begin{equation}
\mle{A}(\tau_t, \tau_b, \tau_c) \cdot \mle{B}(\tau_t, \tau_b, \tau_c) = 0 \label{eq:A}
\end{equation}
{% end %}

By the Schwartz-Zippel lemma, if the polynomial is nonzero, this check fails with overwhelming probability.

We rewrite the above check as a sumcheck. Let $\X{X} = (\X{X_t}, \X{X_b}, \X{X_c})$ denote the indeterminate variables. Define the multilinear equality polynomial:

{% math() %}
$$
\eqpoly{\tau}{\X{X}} = \prod_{i=1}^{\log_2 T + 2} \big((1 - \tau_i)(1 - \X{X_i}) + \tau_i \, \X{X_i}\big)
$$
{% end %}

{% theorem(type="box") %}

**Spartan Outer Sumcheck:** We refer to this equation as the *Spartan outer sumcheck*.
All we have done is re-expressed $\eqref{eq:A}$ in the Lagrange basis.
{% math() %}
$$
\sum_{\substack{\X{X} = (\X{X_t}, \X{X_b}, \X{X_c}) \\\\ \X{X_t} \in \hypercube{T}, \X{X_b} \in \bit, \X{X_c} \in \\{-5,\ldots,4\\}}} \eqpoly{\tau}{\X{X}} \cdot \mle{A}(\X{X}) \cdot \mle{B}(\X{X}) = 0
$$


{% end %}

{% end %}

We continue in the [Stage 1: Spartan Outer Sumcheck](@/jolt-walkthrough/stage1/index.md) chapter.
