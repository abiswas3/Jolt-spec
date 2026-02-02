+++
title = "Emulation"
weight = 3
+++

All our emulation will be a single command found in the `prove_example` function of the file `jolt/jolt-core/benches/e2e_profiling.rs` 

```rust
let (_lazy_trace, trace, _, program_io) = program.trace(&serialized_input, &[], &[]);
```

Our main protagonist in this phase will the `JoltCPU`. 
There are a lot of fields, and words in these fields that we have not yet defined. 
Jolt is a complex system with a lot of moving parts. 
We can ignore most of the fields for now.
We will define things as needed.

```rust
pub struct JoltCpuProver<
    'a,
    F: JoltField,
    PCS: StreamingCommitmentScheme<Field = F>,
    ProofTranscript: Transcript,
> {
    pub preprocessing: &'a JoltProverPreprocessing<F, PCS>,
    pub program_io: JoltDevice,
    pub lazy_trace: LazyTraceIterator,
    pub trace: Arc<Vec<Cycle>>,
    pub advice: JoltAdvice<F, PCS>,
    /// The advice claim reduction sumcheck effectively spans two stages (6 and 7).
    /// Cache the prover state here between stages.
    advice_reduction_prover_trusted: Option<AdviceClaimReductionProver<F>>,
    /// The advice claim reduction sumcheck effectively spans two stages (6 and 7).
    /// Cache the prover state here between stages.
    advice_reduction_prover_untrusted: Option<AdviceClaimReductionProver<F>>,
    pub unpadded_trace_len: usize,
    pub padded_trace_len: usize,
    pub transcript: ProofTranscript,
    pub opening_accumulator: ProverOpeningAccumulator<F>,
    pub spartan_key: UniformSpartanKey<F>,
    pub initial_ram_state: Vec<u64>,
    pub final_ram_state: Vec<u64>,
    pub one_hot_params: OneHotParams,
    pub rw_config: ReadWriteConfig,
}
```

An important object of study for us. 


```rust
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

where the circuit flags are given by 

```rust
pub enum CircuitFlags {
    /// 1 if the first lookup operand is the sum of the two instruction operands.
    AddOperands,
    /// 1 if the first lookup operand is the difference between the two instruction operands.
    SubtractOperands,
    /// 1 if the first lookup operand is the product of the two instruction operands.
    MultiplyOperands,
    /// 1 if the instruction is a load (i.e. `LW`)
    Load,
    /// 1 if the instruction is a store (i.e. `SW`)
    Store,
    /// 1 if the instruction is a jump (i.e. `JAL`, `JALR`)
    Jump,
    /// 1 if the lookup output is to be stored in `rd` at the end of the step.
    WriteLookupOutputToRD,
    /// 1 if the instruction is "virtual", as defined in Section 6.1 of the Jolt paper.
    VirtualInstruction,
    /// 1 if the instruction is an assert, as defined in Section 6.1.1 of the Jolt paper.
    Assert,
    /// Used in inline sequences; the program counter should be the same for the full sequence.
    DoNotUpdateUnexpandedPC,
    /// Is (virtual) advice instruction
    Advice,
    /// Is a compressed instruction (i.e. increase UnexpandedPc by 2 only)
    IsCompressed,
    /// Is instruction the first in a virtual sequence
    IsFirstInSequence,
}
```


