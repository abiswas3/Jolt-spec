+++
title = "Emulation"
weight = 3
+++

## Overview 

The goal of this phase is to go from sequence of instructions in Jolt-assembly to trace of execution.
As we are emulating an entire CPU there is a lot of code that gets run in this section. 
However, as this series is about understanding how Jolt works, we abstract over implementation details such as how we implemented a memory efficient tracer. 
In the [Jolt Blog](TODO:) series we cover implementation details which discuss several optimisations made to make sure the Jolt prover runs as fast as possible.
Still we will outline the code sections that get invoked, so the interested reader can investigate in their own time.

The mental model is the following 

![Gekki](./mental_model.svg)


## Worked Out Examples


The name of registers in the RISC-V assembly, and the jolt assembly is slight slightly different. 
Here is a partial map that enables us to walk through both sets of code.

| Number | ABI Name | Purpose |
|--------|----------|---------|
| x0 | zero | Always 0 |
| x1 | ra | Return address |
| x2 | sp | Stack pointer |
| x10 | a0 | Arg 0 / Return value 0 |
| x11 | a1 | Arg 1 / Return value 1 |
| x12 | a2 | Arg 2 |
| x13 | a3 | Arg 3 |
| x14 | a4 | Arg 4 |


### First Instruction Execution 

We start with the first instruction in the RISC-V assembly code.

```asm
80000000:	00001117          	auipc	sp,0x1
```

which as we have extensively discussed in the [Compilation](@/jolt-walkthrough/1_compilation/index.md) chapter, gets transformed into Jolt-assembly as follows:

```rust
AUIPC(AUIPC { address: 2147483648, operands: FormatU { rd: 2, imm: 4096 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
```

```rust
let (_lazy_trace, trace, _, program_io) = program.trace(&serialized_input, &[], &[]);
```

There is no virtual expansion to deal with. 
The program counter is at `pc= 2147483648 = 0x80000000`. 
The instruction sets the destination register `rd = pc + (imm << 12)`. In the Jolt-assembly format, we already do the shift and store it in the immediate field. 
So after execution, the only change to the system we expect is that the stack pointer `sp` which in Jolt is `a2`

```rust
AUIPC(
        RISCVCycle { 
            instruction: AUIPC { address: 2147483648, operands: FormatU { rd: 2, imm: 4096 }, 
                         virtual_sequence_remaining: None, 
                         is_first_in_sequence: false, 
                        is_compressed: false }, 
            register_state: RegisterStateFormatU { rd: (0, 2147487744) }, 
            ram_access: () 
    }
)
```

The first field is just the instruction being executed. 
This instruction does not touch memory, so we have `ram_access` to `None`. 
Finally the `register_state` says this instruction was in `FormatU` (see [Instruction Formats](@/references/instruction-format.md) for details), and we store the before and after value.
At the start all registers are set to 0, so before is set to 0. 
After should be `2147483648 + 4096 = 2147487744` as instructed.
And that's all there is to the `Cycle` struct. 



### Instruction with Memory Acces and Expansion 

We now shift our attention to a RISCV instruction that is expanded into a sequence of Jolt instruction. 
Consulting our [ISA](@/references/jolt-isa.md) we get 

> LB (Load Byte): Loads an 8-bit byte from memory at `rs1 + offset`, sign-extending the result into `rd`.

```asm
80000044:	00050583          	lb	a1,0(a0) # 0x7fffa000
```

Instead of a single `RISCVCycle` we should expect many to all have the same address with the `virtual_sequence_remaining` field counting where in the expansion sequence we are.

Looking at the table above `a0` maps to register number 10, and `a1` which is our destination maps to register 11.
So the first thing to check is what is stored in address given by the contents `rs1=a0`. 
Now the disassembler gives us a hint that the contents of `a0 + 0 = 0x7FFFA000 = 2147459072`

So we are reading at the right address, and we read all 64 bits of memory starting at that address.
In Line 3 we see that we have `ram_access: RAMRead { address: 2147459072, value: 1619328 }`

So the memory looks like this: as `1619328 = 0x18B580`


| LSB |  |  |  |  |  |  | MSB |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 0x80 | 0xB5 | 0x18 | 0x00 | 0x00 | 0x00 | 0x00 | 0x00 |

| Decimal    | Address    | Value | Description |
|------------|------------|-------|-------------|
| 2147459072 | 0x7fffa000 | 0x80  | LSB (Byte 0)|
| 2147459073 | 0x7fffa001 | 0xB5  | Byte 1      |
| 2147459074 | 0x7fffa002 | 0x18  | Byte 2      |
| 2147459075 | 0x7fffa003 | 0x00  | Byte 3      |
| 2147459076 | 0x7fffa004 | 0x00  | Byte 4      |
| 2147459077 | 0x7fffa005 | 0x00  | Byte 5      |
| 2147459078 | 0x7fffa006 | 0x00  | Byte 6      |
| 2147459079 | 0x7fffa007 | 0x00  | MSB (Byte 7)|


> **EXPECTED ANSWER**: Now in Jolt (I'm pretty certain) it's memory is little-endian, so the answer that goes into `a1` here is `0x80`.
which sign extended is `0xFFFFFFFFFFFFFF80` which is -128 (as a signed 64-bit integer in two's complement).
If you interpret it as an unsigned 64-bit integer, it would be `18446744073709551488`


```rust,linenos
    ADDI(RISCVCycle { instruction: ADDI { address: 2147483716, operands: FormatI { rd: 32, rs1: 10, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false }, register_state: RegisterStateFormatI { rd: (0, 2147459072), rs1: 2147459072 }, ram_access: () })
    ANDI(RISCVCycle { instruction: ANDI { address: 2147483716, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false }, register_state: RegisterStateFormatI { rd: (0, 2147459072), rs1: 2147459072 }, ram_access: () })
    LD(RISCVCycle { instruction: LD { address: 2147483716, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false }, register_state: RegisterStateFormatLoad { rd: (0, 1619328), rs1: 2147459072 }, ram_access: RAMRead { address: 2147459072, value: 1619328 } })
    XORI(RISCVCycle { instruction: XORI { address: 2147483716, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false }, register_state: RegisterStateFormatI { rd: (0, 2147459079), rs1: 2147459072 }, ram_access: () })
    VirtualMULI(RISCVCycle { instruction: VirtualMULI { address: 2147483716, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false }, register_state: RegisterStateFormatI { rd: (2147459079, 17179672632), rs1: 2147459079 }, ram_access: () })
    VirtualPow2(RISCVCycle { instruction: VirtualPow2 { address: 2147483716, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false }, register_state: RegisterStateFormatI { rd: (0, 72057594037927936), rs1: 17179672632 }, ram_access: () })
    MUL(RISCVCycle { instruction: MUL { address: 2147483716, operands: FormatR { rd: 11, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false }, register_state: RegisterStateFormatR { rd: (0, 9223372036854775808), rs1: 1619328, rs2: 72057594037927936 }, ram_access: () })
    VirtualSRAI(RISCVCycle { instruction: VirtualSRAI { address: 2147483716, operands: FormatVirtualRightShiftI { rd: 11, rs1: 11, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false }, register_state: RegisterStateFormatVirtualI { rd: (9223372036854775808, 18446744073709551488), rs1: 9223372036854775808 }, ram_access: () })
```


Now if you look at the last `rd` value in the instruction we see it has `18446744073709551488`
We step through the trace to illustrate this.

#### Step 1: ADDI - Get effective address
Adds the sign-extended 12-bit immediate to register `rs1`. Arithmetic overflow is ignored and the result is simply the low `XLEN` bits of the result.

```rust
asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
// v_address = 0x7FFFA000
// Confirmed: RegisterStateFormatI { rd: (0, 2147459072), rs1: 2147459072 }
```

#### Step 2: ANDI - Align to dword boundary
Performs bitwise AND on register `rs1` and the sign-extended 12-bit immediate and places the result in `rd`. This clears the last 3 bits.

```rust
asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
// v_dword_address = 0x7FFFA000
// Confirmed: RegisterStateFormatI { rd: (0, 2147459072), rs1: 2147459072 }
```

#### Step 3: LD - Load dword from memory
Loads a 64-bit value from memory into register `rd` for RV64I.

```rust
asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
// v_dword = 0x0000000000018B580 = 1619328
//             MSB                                              LSB
// v_dword = | 0x00 | 0x00 | 0x00 | 0x00 | 0x00 | 0x18 | 0xB5 | 0x80 |
// Confirmed: RegisterStateFormatLoad { rd: (0, 1619328), rs1: 2147459072 }
//            ram_access: RAMRead { address: 2147459072, value: 1619328 }
```

#### Step 4: XORI - Calculate byte offset from MSB
Performs bitwise XOR on register `rs1` and the sign-extended 12-bit immediate and places the result in `rd`. Flips the lowest 3 bits (originally 000, now 111).

```rust
asm.emit_i::<XORI>(*v_shift, *v_address, 7);
// v_shift = 0x7FFFA007 = 2147459079
// Confirmed: RegisterStateFormatI { rd: (0, 2147459079), rs1: 2147459072 }
```

#### Step 5: VirtualMULI - Convert byte offset to bit offset
Multiplies the value in register `rs1` by 8 (equivalent to SLLI by 3).

```rust
asm.emit_virtual::<VirtualMULI>(*v_shift, *v_shift, 8);
// v_shift = 0x3FFFFD0038 = 17179672632
// Lowest 6 bits of v_shift are now 111000 = 56
// Confirmed: RegisterStateFormatI { rd: (2147459079, 17179672632), rs1: 2147459079 }
```

#### Step 6: VirtualPow2 - Calculate shift mask
Computes 2^(v_shift) to create a power-of-2 value.

```rust
asm.emit_virtual::<VirtualPow2>(*v_pow2, *v_shift, 0);
// v_pow2 = 2^56 = 0x100000000000000 = 72057594037927936
// Confirmed: RegisterStateFormatI { rd: (0, 72057594037927936), rs1: 17179672632 }
```

#### Step 7: MUL - Shift byte to MSB position
Multiplies v_dword by 2^56, effectively shifting the target byte to the MSB position.

```rust
asm.emit_r::<MUL>(self.operands.rd, *v_dword, *v_pow2);
// v_dword = 0x0000000000018B580 * 2^56 = 0x8000000000000000
// rd = | 0x80 | 0x00 | 0x00 | 0x00 | 0x00 | 0x00 | 0x00 | 0x00 |
// Confirmed: RegisterStateFormatR { rd: (0, 9223372036854775808), rs1: 1619328, rs2: 72057594037927936 }
```

#### Step 8: VirtualSRAI - Sign-extend from MSB
Performs arithmetic right shift on the value in register `rs1` by 56 bits. The sign bit is copied into the vacated upper bits.

```rust
asm.emit_virtual::<VirtualSRAI>(self.operands.rd, self.operands.rd, 56);
// rd = 0x8000000000000000 >> (s) 56 = 0xFFFFFFFFFFFFFF80
// rd = | 0xFF | 0xFF | 0xFF | 0xFF | 0xFF | 0xFF | 0xFF | 0x80 |
// rd = -128 (signed) = 18446744073709551488 (unsigned)
// Confirmed: RegisterStateFormatVirtualI { rd: (9223372036854775808, 18446744073709551488), rs1: 9223372036854775808 }
```

*Final Result*: `rd = 0xFFFFFFFFFFFFFF80 = -128` (as expected)


## The RISCVCycle Data Structure

The Cycle data structure is exactly what we said it was -- it's a bookkeeping device. 
We list the instruction being run, the registers being used, the immedate values, and the before and after state of all the registers that change; and before/after state of memory. 
That's all there is to it.

```rust
LD(RISCVCycle 
    { 
        instruction: LD { 
            address: 2147483716, 
            operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, 
            virtual_sequence_remaining: Some(5), 
            is_first_in_sequence: false, 
            is_compressed: false 
        }, 
        register_state: RegisterStateFormatLoad { rd: (0, 1619328), rs1: 2147459072 }, 
        ram_access: RAMRead { address: 2147459072, value: 1619328 } 
    }
)

```

Formally it is just 

```rust
pub struct RISCVCycle<T: RISCVInstruction> {
    pub instruction: T,
    pub register_state: <T::Format as InstructionFormat>::RegisterState,
    pub ram_access: T::RAMAccess,
}
```

where we have already covered instruction in detail (see [Jolt ISA](@/references/jolt-isa.md)).
`RegisterState` is just any type that implements the trait 

```rust
pub trait InstructionRegisterState:
    Default + Copy + Clone + Serialize + DeserializeOwned + Debug
{
    fn rs1_value(&self) -> Option<u64> {
        None
    }
    fn rs2_value(&self) -> Option<u64> {
        None
    }
    fn rd_values(&self) -> Option<(u64, u64)> {
        None
    }
}
```

It just gives the before and after values of registers.
And `RAMAccess` is also self explanatory.

```rust
#[derive(Default, Debug, Copy, Clone, Serialize, Deserialize, PartialEq)]
pub struct RAMRead {
    pub address: u64,
    pub value: u64,
}

#[derive(Default, Debug, Copy, Clone, Serialize, Deserialize, PartialEq)]
pub struct RAMWrite {
    pub address: u64,
    pub pre_value: u64,
    pub post_value: u64,
}

pub enum RAMAccess {
    Read(RAMRead),
    Write(RAMWrite),
    NoOp,
}
```

So what the Jolt CPU does (and we don't cover how in this post), it takes all the instructions in Jolt-assembly, executes them, and creates a record of what it did. 
This record will act as the ground truth of what the Jolt VM did when given a user program.
If the reader is interested in looking into the block of code that actually executes each Jolt instruction they can inspect 



In `/Users/francis/Work-With-A16z/jolt/tracer/src/instruction/mod.rs` we describe how the tracer should trace each instruction.
It essentially relies on the execute function we write for each instruction.
This is where looking athe operands or formatting will be useful.

```rust
    fn trace(&self, cpu: &mut Cpu, trace: Option<&mut Vec<Cycle>>) {
        let mut cycle: RISCVCycle<Self> = RISCVCycle {
            instruction: *self,
            register_state: Default::default(),
            ram_access: Default::default(),
        };
        self.operands()
            .capture_pre_execution_state(&mut cycle.register_state, cpu);
        self.execute(cpu, &mut cycle.ram_access);
        self.operands()
            .capture_post_execution_state(&mut cycle.register_state, cpu);
        if let Some(trace_vec) = trace {
            trace_vec.push(cycle.into());
        }
    }
```

Based on the format of the instruction, each of them will have a pre/post execution state capture.

```rust
// FORMAT R: will want to extract this for everything else.
fn capture_pre_execution_state(&self, state: &mut Self::RegisterState, cpu: &mut Cpu) {
        state.rs1 = normalize_register_value(cpu.x[self.rs1 as usize], &cpu.xlen);
        state.rs2 = normalize_register_value(cpu.x[self.rs2 as usize], &cpu.xlen);
        state.rd.0 = normalize_register_value(cpu.x[self.rd as usize], &cpu.xlen);
    }

    fn capture_post_execution_state(&self, state: &mut Self::RegisterState, cpu: &mut Cpu) {
        state.rd.1 = normalize_register_value(cpu.x[self.rd as usize], &cpu.xlen);
    }
```

The details of emulation is not terribly important for understanding the next steps. 
All we need to remember, is that Jolt took the user program compiled it to Jolt assembly, executed each instruction, and kept a log of everything it did at every time step.
Jolt also saves the initial state of memory, and the final state of memory after all instructions are run.
From this `trace` (executions) and `memory` initial, and final -- we will create the following data structures: 

## Jolt Specific Data Structures.

We have finished executing the program -- now the proof.
So far we have not discussed any details of what constitutes a proof besides stating in the overview that we will get a system of polynomial eqautions. 
We will not get to polynomial equations in this section, but we will get to all the data structures we can construct polynomial equations, in the remainder of this document. 

Let's work backwards and focus on the following snipped in file `jolt-core/benches/e2e_profiling.rs`

The first snippet is constructing a `JoltCpuProver`. 
The next step asks this prover to prove that it ran the program correctly.
```rust
let prover = RV64IMACProver::gen_from_elf(
            &preprocessing,
            elf_contents,
            &serialized_input,
            &[],
            &[],
            None,
            None,
        );
        let program_io = prover.program_io.clone();
        let (jolt_proof, _) = prover.prove();

```

The declaration of the function is given asu 

```rust
pub fn gen_from_elf(
        preprocessing: &'a JoltProverPreprocessing<F, PCS>, // See below
        elf_contents: &[u8], // The RISC-V code in bytes
        inputs: &[u8], // This will be 5 as a vector of bytes in our example.
        untrusted_advice: &[u8],// Nothing passed []
        trusted_advice: &[u8], // Nothing passed []
        trusted_advice_commitment: Option<PCS::Commitment>, // None
        trusted_advice_hint: Option<PCS::OpeningProofHint>, // None
    )
```

We will defer to proving in the backend -- but this above function returns a `JoltCpuProver`. 
Our main protagonist.

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

There is a lot going on. Some fields seem familiar, while others seem to have come out of the blue from nowhere. 
Let's start with what we understand: 

1. `trace`: The list of bookeeping records we've discussed ad nauseam. 
2. `lazy_trace`: A clever way to iterate the trace. We do not need to focus on what's clever about it for now. 
4. `unpadded_trace_len`: Length of the trace. 
5. `paddeed_trace_len`: Length of trace padded with `NOOPS` to the next power of 2. 
6. `proof_transcript` : We have no discussed this, but think of this as an empty log file (we have not proven anything). We will write the proof to this log. 
7. `initial_ram_state`: Memory before program execution
8. `final_ram_state`: Memory after program finished. 


This leaves us with 

1. `preprocessing`
2. `program_io`
3. `advice`
4. `advice_reduction_prover_untrusted`
5. `advice_reduction_prover_trusted`
6. `opening_accumulator`
7. `spartan_key`
8. `one_hot_params`
9. `rw_config`

Let's get rid of a few easy ones, digging deeper into the implementations we find, when initialisng the `JoltCPUProver` we have 

```rust
//...
 advice: JoltAdvice {
                untrusted_advice_polynomial: None,
                trusted_advice_commitment, // set to None in args
                trusted_advice_polynomial: None,
                untrusted_advice_hint: None,
                trusted_advice_hint, // set to None in args
            },
advice_reduction_prover_trusted: None,
advice_reduction_prover_untrusted: None,
//.. 
```

`program_io` is relatively simple. It captures user inputs and outputs to Jolt and is given by 

```rust
TODO:
```
`pre_processing` is not terribly interesting either -- it's more bookeeping, and we discuss it at the end for completeness. 
Think of this as things both the user and prover will know and keep track of. 

So all of this is just `None` and we can forget about this for now.
We will get to `preprocessing` and `program_io` in a 


The `UniformSpartanKey` stores 2 numbers and a hash, we can ignore the hash for now as that has to do with the verifier. 
We are only interested in proving for now. 
`num_cons_total`=$T \times M$ where $T$ is the number of cycles (padded to a power of 2) and $M$ is the number of constraints known as the `R1CS` constraints. 
Remember when we said proving will eventually boil down to constructing some equalities -- these will be the first set of constraints (but sadly not all) that we **MUST** satisfy. 
We will discuss them in great detail in the next chapter on [Constraints](@/jolt-walkthrough/constraints/index.md). 
For now we just there that $M$ of them and move on. 

```rust
#[derive(Clone, Copy, CanonicalSerialize, CanonicalDeserialize)]
pub struct UniformSpartanKey<F: JoltField> {
    /// Number of constraints across all steps padded to nearest power of 2
    pub num_cons_total: usize,

    /// Number of steps padded to the nearest power of 2
    pub num_steps: usize,

    /// Digest of verifier key
    pub(crate) vk_digest: F,
}
```

`OneHotParams` is also just a bunch of numbers. 
These numbers will make a lot of sense when we get to discussing memory-checking arguments. 
All a memory checking argument is that it allows us to check if the instruction was supposed to write $X$ to address $A$ or read $Y$ from location $B$ -- it did so.
Foreshadowing the future, we will write that check as a polynomial equation as well, for practical purposes related to polynomial commitment schemes these numbers will become clearer. 
Still we list what it is for completeness. 

```rust
#[derive(Allocative, Clone, Debug, Default)]
pub struct OneHotParams {
    pub log_k_chunk: usize,
    pub lookups_ra_virtual_log_k_chunk: usize,
    pub k_chunk: usize,

    pub bytecode_k: usize,
    pub ram_k: usize,

    pub instruction_d: usize,
    pub bytecode_d: usize,
    pub ram_d: usize,

    instruction_shifts: Vec<usize>,
    ram_shifts: Vec<usize>,
    bytecode_shifts: Vec<usize>,
}
```


```rust
/// Configuration for read-write checking sumchecks.
///
/// Contains parameters that control phase structure for RAM and register
/// read-write checking sumchecks. All fields are `u8` to minimize proof size.
#[derive(Clone, Debug, PartialEq, Eq, CanonicalSerialize, CanonicalDeserialize)]
pub struct ReadWriteConfig {
    /// RAM read-write checking: number of cycle variables to bind in phase 1.
    pub ram_rw_phase1_num_rounds: u8,

    /// RAM read-write checking: number of address variables to bind in phase 2.
    pub ram_rw_phase2_num_rounds: u8,

    /// Registers read-write checking: number of cycle variables to bind in phase 1.
    pub registers_rw_phase1_num_rounds: u8,

    /// Registers read-write checking: number of address variables to bind in phase 2.
    pub registers_rw_phase2_num_rounds: u8,
}
```

We do not discuss the `OpeningAccumulator` as we will cover it in detail during the sum-checks. 

### Preprocessing 

TODO:

## Appendices

### Appendix A: The Entire Trace File 

TODO:
