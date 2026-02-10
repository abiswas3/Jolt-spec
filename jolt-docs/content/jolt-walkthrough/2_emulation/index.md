+++
title = "Emulation"
weight = 3
+++

## Overview 

{% mermaid() %}
sequenceDiagram
    participant JC as Jolt Compiler
    participant JE as Jolt Emulator
    participant JP as Jolt Prover Data Structures
    participant JCon as Jolt Constraints

{% end %}

The goal of this phase is to go from a sequence of instructions in Jolt assembly to a trace of execution.
As we are emulating an entire CPU there is a lot of code that gets run in this section. 
However, as this series is about understanding how Jolt works, and not so much how it is implemented exactly, we abstract over some implementation details — such as how we implemented a memory-efficient tracer.

In the [Jolt Blog](@/blog/_index.md) series we cover implementation details which discuss several optimisations made to make sure the Jolt prover runs as fast as possible.
Still we will outline the code sections that get invoked, so the interested reader can investigate in their own time.
The mental model for this section is the following.

![Gekki](./mental_model.svg)

TODO: A little excerpt on what this image shows -- leave it be for now

## Worked Out Examples

To best understand what the `trace` data structure captures, it is best to work through a few examples. 
In what follows, the name of registers in the RISC-V assembly and the Jolt assembly is slightly different.
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


We continue with our recurring example of the Fibonacci Rust program.

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
The instruction sets the destination register `rd = pc + (imm << 12)`. In the Jolt assembly format, the shift is already applied and stored in the immediate field.
So after execution, the only change to the system we expect is that the stack pointer `sp` (register `x2` in Jolt) is updated.

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
This instruction does not touch memory, so `ram_access` is empty.
Finally the `register_state` says this instruction was in `FormatU` (see [Instruction Formats](@/references/instruction-format.md) for details), and we store the before and after value.
At the start all registers are set to 0, so before is set to 0. 
After should be `2147483648 + 4096 = 2147487744` as instructed.
And that's all there is to the `Cycle` struct. 



### Instruction with Memory Access and Expansion

We now shift our attention to a RISC-V instruction that is expanded into a sequence of Jolt instructions.
Consulting our [ISA](@/references/jolt-isa.md) we get:

> LB (Load Byte): Loads an 8-bit byte from memory at `rs1 + offset`, sign-extending the result into `rd`.

```asm
80000044:	00050583          	lb	a1,0(a0) # 0x7fffa000
```

Instead of a single `RISCVCycle`, we should expect several, all sharing the same address, with the `virtual_sequence_remaining` field counting down through the expansion sequence.

Looking at the table above `a0` maps to register number 10, and `a1` which is our destination maps to register 11.
So the first thing to check is what is stored at the address given by the contents of `rs1` (`a0`).
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


Jolt's memory is little-endian, so the byte that goes into `a1` here is `0x80`.
Sign-extended, this is `0xFFFFFFFFFFFFFF80`, which is −128 as a signed 64-bit integer in two's complement.
Interpreted as an unsigned 64-bit integer, it would be `18446744073709551488`.


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
We list the instruction being run, the registers being used, the immediate values, and the before and after state of all the registers that change; and the before/after state of memory.
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
And `RAMAccess` is also self-explanatory.

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

So what the Jolt CPU does (and we do not cover how in this section) is take all the instructions in Jolt assembly, execute them, and create a record of what it did.
This record will act as the ground truth of what the Jolt VM did when given a user program.
If the reader is interested in looking into the block of code that actually executes each Jolt instruction they can inspect 



In `tracer/src/instruction/mod.rs` we describe how the tracer should trace each instruction.
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

{% theorem(type="box") %}

All we need to remember, is that Jolt took the user program compiled it to Jolt assembly, executed each instruction, and kept a log of everything it did at every time step.
Jolt also saves the initial state of memory, and the final state of memory after all instructions are run.
From this `trace` (executions) and `memory` initial, and final -- we will create the following data structures: 

{% end %}


## Jolt Specific Data Structures.

We have finished executing the program -- and generated a `trace` that records everything we have done. 
The next thing we want to do is use this trace to construct a few data structures that facilitate proving. 
The inputs to to this phase, our simply the `trace` vector and the initial and final memory state. 

{% theorem(type="box") %}

There is a large body of code that is present in between the data structures we define, and this step. 
Once again we are abstracting implementation details. 
Later in a more specific blog post, we will detail how the prover was implemented. 

{% end %}


TODO: Put in mermaid digram 

The first set of data structures we discuss are what we call the "committed polynomials".
They are named

1. `RdInc`
2. `RamInc`
3. `InstructionRa(d)`
4. `BytecodeRa(d)`
5. `RamRa(d)`

Before proceeding to describe what these data structures look like, we introduce some notation.
Let $T$ be the length of the `trace` padded with `NoOp` cycles to make $T$ a power of 2.
In Jolt, multilinear polynomials are represented by storing their evaluations over the Boolean hypercube $\\{0,1\\}^{\log T}$.
So when we write `RdInc[j]`, we mean the evaluation of the polynomial at the $j$-th point of the hypercube -- which is just the $j$-th entry of a length-$T$ array.

All witness generation lives in two methods on the `CommittedPolynomial` enum:
- Non-streaming: `generate_witness()` at [`witness.rs:137`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/witness.rs#L137)
- Streaming (for Dory tier-1 commitment): `stream_witness_and_commit_rows()` at [`witness.rs:63`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/witness.rs#L63)

Both contain the same mathematical logic; the streaming path processes row-sized chunks rather than materializing the full polynomial.

### Chunking Configuration

The three Ra polynomial families (`InstructionRa`, `BytecodeRa`, `RamRa`) all decompose an address into $d$ chunks of $\log_2(K_{\text{chunk}})$ bits each.
The chunk size is set based on trace length in `OneHotConfig::new` at [`config.rs:135`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/config.rs#L135):

| Parameter | $\log T < 25$ | $\log T \geq 25$ |
|---|---|---|
| `log_k_chunk` | $4$ | $8$ |
| $K_{\text{chunk}} = 2^{\texttt{log\\_k\\_chunk}}$ | $16$ | $256$ |
| $d_{\text{instr}}$ (`instruction_d`) | $32$ | $16$ |
| $d_{\text{bc}}$ (`bytecode_d`) | $\lceil \log_2(\texttt{bytecode\_k}) / 4 \rceil$ | $\lceil \log_2(\texttt{bytecode\_k}) / 8 \rceil$ |
| $d_{\text{ram}}$ (`ram_d`) | $\lceil \log_2(\texttt{ram\_k}) / 4 \rceil$ | $\lceil \log_2(\texttt{ram\_k}) / 8 \rceil$ |

TODO: Explain what $d$ is and why we decompose addresses into chunks.

The number of chunks is $d = \lceil \log_2(\text{address space size}) / \texttt{log\_k\_chunk} \rceil$, computed in `OneHotParams::from_config` at [`config.rs:228`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/config.rs#L228). For instruction lookups, the address space is $2^{128}$ (two interleaved 64-bit operands, so $\texttt{LOG\_K} = 128$), giving a fixed $d_{\text{instr}}$. For bytecode and RAM, $d$ depends on the program's bytecode size and memory footprint respectively.

The $i$-th chunk of an address $a$ is extracted in big-endian order:

{% math() %}
$$\text{chunk}_i(a) = \left\lfloor \frac{a}{K_{\text{chunk}}^{d-1-i}} \right\rfloor \bmod K_{\text{chunk}}$$
{% end %}

The three extraction functions are at [`config.rs:275-285`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/config.rs#L275):

```rust
ram_address_chunk(addr, i)    = (addr >> ram_shifts[i])         & (k_chunk - 1)
bytecode_pc_chunk(pc, i)      = (pc >> bytecode_shifts[i])      & (k_chunk - 1)
lookup_index_chunk(index, i)  = (index >> instruction_shifts[i]) & (k_chunk - 1)
```

### 1. `RdInc` -- Register Increment Polynomial

A single multilinear polynomial of length $T$ over $\log T$ variables. Each evaluation is a signed integer representing the *change* in the destination register's value at that cycle.

**Construction** ([`witness.rs:176-184`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/witness.rs#L176)):

{% math() %}
$$\texttt{RdInc}[j] = \texttt{rd\_post\_value}(\text{cycle}_j) - \texttt{rd\_pre\_value}(\text{cycle}_j)$$
{% end %}

Every instruction in the [Jolt-ISA](@/references/jolt-isa.md) can update at most one destination register.
The method `cycle.rd_write()` (at [`tracer/src/instruction/mod.rs:479`](https://github.com/a16z/jolt/blob/main/tracer/src/instruction/mod.rs#L479)) returns `Option<(rd_index, pre_value, post_value)>`.
If the cycle does not write to any register (NoOp or read-only instruction), `rd_write()` returns `None`, and we get $\texttt{RdInc}[j] = 0$.

Internally this is stored as a `CompactPolynomial<i128>` -- the values are native `i128` integers (differences of 64-bit values) and are promoted to field elements lazily during sumcheck. This saves memory.

**Role in the protocol:** This is the "Inc" polynomial for the Twist read-write memory checking protocol on registers. During the register read-write checking sumcheck, it encodes the identity $\text{write\_value}(j) = \text{read\_value}(j) + \texttt{RdInc}[j]$.

### 2. `RamInc` -- RAM Increment Polynomial

A single multilinear polynomial of length $T$ over $\log T$ variables. Same idea as `RdInc`, but for RAM -- and with one important asymmetry.

**Construction** ([`witness.rs:186-199`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/witness.rs#L186)):

{% math() %}
$$\texttt{RamInc}[j] = \begin{cases} \texttt{post\_value} - \texttt{pre\_value} & \text{if cycle}_j \text{ is a RAM store (write)} \\\ 0 & \text{if cycle}_j \text{ is a RAM load (read) or NoOp} \end{cases}$$
{% end %}

The key difference from `RdInc`: loads contribute 0, because a load does not change memory.
The `cycle.ram_access()` method (at [`tracer/src/instruction/mod.rs:413`](https://github.com/a16z/jolt/blob/main/tracer/src/instruction/mod.rs#L413)) returns a `RAMAccess` enum:

```rust
enum RAMAccess {
    Read(RAMRead),     // { address, value }
    Write(RAMWrite),   // { address, pre_value, post_value }
    NoOp,
}
```

Only the `Write` variant carries both `pre_value` and `post_value`; `Read` and `NoOp` map to 0.

Internally stored as `CompactPolynomial<i128>`, same as `RdInc`.

**Role in the protocol:** The "Inc" polynomial for the Twist protocol on RAM, used in the RAM read-write checking sumcheck at [`ram/read_write_checking.rs`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/ram/read_write_checking.rs).

### 3. `InstructionRa(i)` -- Instruction Lookup One-Hot Polynomials

A family of $d_{\text{instr}} = \lceil 128 / \texttt{log\_k\_chunk} \rceil$ one-hot multilinear polynomials ($16$ when $\texttt{log\_k\_chunk}=8$, $32$ when $\texttt{log\_k\_chunk}=4$).
Each polynomial has $T \times K_{\text{chunk}}$ evaluations over $\log T + \log K_{\text{chunk}}$ variables.

**Construction** ([`witness.rs:201-213`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/witness.rs#L201)):

For each cycle $j$, the prover:

1. Computes a 128-bit **lookup index** by interleaving the two instruction operands (at [`instruction/mod.rs:32-34`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/instruction/mod.rs#L32)):

{% math() %}
$$\texttt{lookup\_index} = \texttt{interleave\_bits}(x, y)$$
{% end %}

where $(x, y)$ are the instruction's operands (typically `rs1`, `rs2`). The `interleave_bits` function (at [`utils/mod.rs:145`](https://github.com/a16z/jolt/blob/main/jolt-core/src/utils/mod.rs#L145)) places $x$'s bits at even positions and $y$'s bits at odd positions of a 128-bit value. This interleaving is what makes Jolt's decomposable lookup tables work -- each chunk of the interleaved index corresponds to a small sub-table lookup.

2. Extracts the $i$-th chunk: $c_i = \texttt{lookup\_index\_chunk}(\texttt{lookup\_index}, i)$

3. Sets the one-hot indicator:

{% math() %}
$$\texttt{InstructionRa}(i)[j, k] = \begin{cases} 1 & \text{if } k = c_i \\\ 0 & \text{otherwise}\end{cases}$$
{% end %}

**Internal representation.** Rather than materializing the full $K_{\text{chunk}} \times T$ matrix, these are stored as `OneHotPolynomial<F>` (at [`poly/one_hot_polynomial.rs:25`](https://github.com/a16z/jolt/blob/main/jolt-core/src/poly/one_hot_polynomial.rs#L25)):

```rust
struct OneHotPolynomial<F> {
    K: usize,                              // k_chunk (16 or 256)
    nonzero_indices: Arc<Vec<Option<u8>>>,  // length T: which row is "hot" per column
}
```

Only the index of the single nonzero entry per column (cycle) is stored. For `InstructionRa`, every entry is `Some(chunk_value)` -- there is always an instruction at every cycle (NoOps produce `lookup_index = 0`, so chunk = 0).

**Role in the protocol:** These are the Ra polynomials for the Shout lookup argument on instruction lookups. During the Ra virtual sumcheck (at [`instruction_lookups/ra_virtual.rs`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/instruction_lookups/ra_virtual.rs)), groups of committed Ra polynomials are multiplied together to form larger "virtual" Ra polynomials:

{% math() %}
$$\texttt{VirtualRa}_i(\vec{r}) = \prod_{j=0}^{M-1} \texttt{InstructionRa}(i \cdot M + j)(\vec{r})$$
{% end %}

where $M = \texttt{lookups\_ra\_virtual\_log\_k\_chunk} / \texttt{log\_k\_chunk}$. The product reconstructs the indicator for a larger chunk of the address space.

### 4. `BytecodeRa(i)` -- Bytecode One-Hot Polynomials

A family of $d_{\text{bc}} = \lceil \log_2(\texttt{bytecode\_k}) / \texttt{log\_k\_chunk} \rceil$ one-hot multilinear polynomials (program-dependent count).
`bytecode_k` is the size of the bytecode table (next power of 2 above the number of instructions).
Same $T \times K_{\text{chunk}}$ structure as `InstructionRa`.

**Construction** ([`witness.rs:148-160`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/witness.rs#L148)):

For each cycle $j$, the prover:

1. Maps the cycle to a **virtual PC** -- a dense sequential index into the bytecode table. This is done by `BytecodePreprocessing::get_pc` (at [`bytecode/mod.rs:36-43`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/bytecode/mod.rs#L36)):

```rust
fn get_pc(&self, cycle: &Cycle) -> usize {
    if matches!(cycle, Cycle::NoOp) { return 0; }
    let instr = cycle.instruction().normalize();
    self.pc_map.get_pc(instr.address, instr.virtual_sequence_remaining.unwrap_or(0))
}
```

The `BytecodePCMapper::get_pc` (at [`bytecode/mod.rs:92-98`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/bytecode/mod.rs#L92)) converts the raw ELF address into a dense index:

{% math() %}
$$\texttt{virtual\_pc} = \texttt{base\_pc} + (\texttt{max\_inline\_seq} - \texttt{virtual\_sequence\_remaining})$$
{% end %}

NoOp cycles map to PC = 0 (a dummy noop row in the bytecode table).

2. Extracts the $i$-th chunk: $c_i = \texttt{bytecode\_pc\_chunk}(\texttt{virtual\_pc}, i)$

3. Sets the one-hot indicator:

{% math() %}
$$\texttt{BytecodeRa}(i)[j, k] = \begin{cases} 1 & \text{if } k = c_i \\\ 0 & \text{otherwise}\end{cases}$$
{% end %}

**Internal representation.** Same `OneHotPolynomial<F>` as `InstructionRa`. Every entry is `Some(chunk_value)` since every cycle fetches some bytecode row.

**Role in the protocol:** These are the Ra polynomials for the Shout lookup argument on bytecode. The product of all $d_{\text{bc}}$ polynomials reconstructs the full bytecode address indicator, used in the bytecode Read+RAF checking sumcheck at [`bytecode/read_raf_checking.rs`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/bytecode/read_raf_checking.rs):

{% math() %}
$$\text{ra}(k, j) = \prod_{i=0}^{d_{\text{bc}}-1} \texttt{BytecodeRa}(i)(k_i, j)$$
{% end %}


### 5. `RamRa(i)` -- RAM Address One-Hot Polynomials

A family of $d_{\text{ram}} = \lceil \log_2(\texttt{ram\_k}) / \texttt{log\_k\_chunk} \rceil$ one-hot multilinear polynomials (program-dependent count).
`ram_k` is the size of the RAM address space (next power of 2). Same $T \times K_{\text{chunk}}$ structure as the other Ra families, but with one critical difference: **entries can be `None`**.

Also note: for RAM, **ra and wa are the same polynomial**, because there is at most one load or store per cycle. The same polynomial serves as both the read-address and write-address indicator.

**Construction** ([`witness.rs:162-174`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/witness.rs#L162)):

For each cycle $j$, the prover:

1. Gets the raw byte address via `cycle.ram_access().address()`.

2. **Remaps** the address to a word-aligned index in the RAM table, via `remap_address` (at [`ram/mod.rs:128-139`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/ram/mod.rs#L128)):

```rust
fn remap_address(address: u64, memory_layout: &MemoryLayout) -> Option<u64> {
    if address == 0 { return None; }   // No RAM access this cycle
    let lowest_address = memory_layout.get_lowest_address();
    Some((address - lowest_address) / 8)  // Byte addr -> 8-byte word index
}
```

If `address == 0`, there was no memory operation this cycle, so we get `None`.
Otherwise, the remapped address is `(byte_address - base) / 8`.

3. If `Some(addr)`, extracts the $i$-th chunk: $c_i = \texttt{ram\_address\_chunk}(\texttt{addr}, i)$. If `None`, the entry is `None`.

4. Sets the one-hot indicator:

{% math() %}
$$\texttt{RamRa}(i)[j, k] = \begin{cases} 1 & \text{if remap}(j) = \text{Some}(\text{addr}) \text{ and } k = \text{chunk}_i(\text{addr}) \\\ 0 & \text{otherwise (including when remap}(j) = \text{None)} \end{cases}$$
{% end %}

When `None`, the entire column of the $K_{\text{chunk}} \times T$ matrix is zero -- no row is "hot". This makes `RamRa` a *sparse* one-hot polynomial, unlike `InstructionRa` and `BytecodeRa` which always have exactly one hot entry per column.

**Role in the protocol:** These are the Ra (= Wa) polynomials for the Twist read-write memory checking protocol on RAM. Their product reconstructs the full RAM address indicator, used in the RAM Ra virtual sumcheck at [`ram/ra_virtual.rs`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/ram/ra_virtual.rs) and the RAM read-write checking sumcheck at [`ram/read_write_checking.rs`](https://github.com/a16z/jolt/blob/main/jolt-core/src/zkvm/ram/read_write_checking.rs).

### Summary Table

| Polynomial | Count | Entry type | Size | Variables | Sparse? |
|---|---|---|---|---|---|
| `RdInc` | $1$ | `i128` (signed diff) | $T$ | $\log T$ | No |
| `RamInc` | $1$ | `i128` (signed diff) | $T$ | $\log T$ | No ($0$ for non-writes) |
| `InstructionRa(i)` | $d_{\text{instr}}$ ($16$ or $32$) | one-hot over $K_{\text{chunk}}$ | $T \times K_{\text{chunk}}$ | $\log K_{\text{chunk}} + \log T$ | No (always `Some`) |
| `BytecodeRa(i)` | $d_{\text{bc}}$ (program-dep.) | one-hot over $K_{\text{chunk}}$ | $T \times K_{\text{chunk}}$ | $\log K_{\text{chunk}} + \log T$ | No (always `Some`) |
| `RamRa(i)` | $d_{\text{ram}}$ (program-dep.) | one-hot over $K_{\text{chunk}}$ | $T \times K_{\text{chunk}}$ | $\log K_{\text{chunk}} + \log T$ | **Yes** (`None` when no RAM access) |

All polynomials are committed via Dory (either streaming tier-1/tier-2 or direct) before any sumcheck rounds begin. The commitments are sent to the verifier, and the polynomials are later opened at random points derived from the Fiat-Shamir transcript during claim reductions.

## THIS OLD AND I WILL Re-work this work into a blog.

Ignore everything from here on. 

So far we have not discussed any details of what constitutes a proof besides stating in the overview that we will get a system of polynomial equations. 
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
