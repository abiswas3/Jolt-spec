+++
title = "Compilation"
weight = 2
+++

In this section, we provide full details of the compilation phase of Jolt. 
At the end of this stage, we should have a data structure in memory called the `bytecode` which fully describes the user program in Jolt assembly.

**NOTE**: This section of the Jolt code base is public knowledge. 
The user can inspect the binary that runs the compilation phase. 
In fact they can run this this phase themselves.
Later we will discuss parts of Jolt, the user does not get to see.

## RISC-V-IMAC 

The entry point for the user the following command

```bash
cargo run --release -p jolt-core profile --name fibonacci
```

which tells Jolt execute the program described in `jolt/examples/fibonacci/guest/src/lib.rs` (the same as one described in the [overview](@/jolt-walkthrough/0_overview.md)), and send me a proof that Jolt correctly executed said program.

As mentioned earlier, Jolt only accepts inputs written Jolt assembly, which is constructed by extending the instruction set with *inlines* and *virtual instructions*.
Before we get to virtual instructions, the first step is to compile the program down to an [elf](https://wiki.osdev.org/ELF) file with `risc-v-imac` instructions.
To do this, we draw the readers attention to the line `self.build(DEFAULT_TARGET_DIR);`found in `jolt/jolt-core/src/host/program.rs`. 
Under the hood - Jolt runs the following command

```bash
env CARGO_ENCODED_RUSTFLAGS=$'-C\x1flink-arg=-T/tmp/jolt-guest-linkers/fibonacci-guest.ld\
\x1f-C\x1fpasses=lower-atomic\
\x1f-C\x1fpanic=abort\
\x1f-C\x1fdebuginfo=0\
\x1f-C\x1fstrip=symbols\
\x1f-C\x1fopt-level=3\
\x1f--cfg\x1fgetrandom_backend="custom"' \
    CC_riscv64imac-unknown-none-elf='' \
    CFLAGS_riscv64imac-unknown-none-elf='' \
cargo build \
    --release \
    --features guest \
    -p fibonacci-guest \
    --target-dir /tmp/jolt-guest-targets/fibonacci-guest- \
    --target riscv64imac-unknown-none-elf
```

The `cargo build...` part says build the program in package `fibonacci-guest` in the current workspace with the `guest` feature turned on. 
Rust (via LLVM) uses the standard [target triple format](https://docs.rs/target-lexicon/latest/target_lexicon/struct.Triple.html)
```md
<arch>-<vendor>-<sys>-<abi>
```

+ Architecture: `riscv64` says use the base instruction set with 64 bit registers. `imac` says uses the `i`, `m`, `a`, `c` [(see sections 11, 12, 13, and 27 for details)](https://docs.riscv.org/reference/isa/unpriv/unpriv-index.html). 
+ Vendor: We are not targeting CPU's made by a specific vendor here. 
+ Operating System: All our guest programs are run with `#![no_std]`, so when we say `none` here, we mean the assembly should run on bare-metal or embedded systems.
+ Output format: we choose the `elf` format to output the file and we ask the compiler to put the executable in the following directory `/tmp/jolt-guest-targets/fibonacci-guest-` 

The output of this command is "An ELF executable for RISC-V RV64IMAC: 
We also tell the `rustc` compiler to use our linker script located at `/tmp/jolt-guest-linkers/fibonacci-guest.ld`, which allows to define the memory layout of our assembly code.
The other flags -- tell the compiler that it should simply abort if it encounters a panic, instead of recursively trying to find the source of the error, we do not want debug information or symbols in the final binary, and to perform all optimisations as needed.

> At this moment in time we should have an [elf file](TODO:) located in the `/tmp/jolt-guest-targets/fibonacci-guest-/` directory. Additionally, the liner script can be found [here](TODO:)

## Jolt Bytecode


The next step is to convert this elf file into Jolt bytecode.
The bytecode will a vector of `Instruction` enumerations defined [here](TODO:). 
The actual code enumerating every Jolt instruction is written using declarative macros. 
So after a bit of `cargo expand` machinery, it looks like the `enum` showing in [Appendix-A](#appendix-a).

```asm
add    a5,a5,a4
```

The internal memory representation of the `ADD` enumeration of the `Instruction::ADD(ADD)` enum looks like the following:

```rust
pub struct ADD {
    pub address: u64, // Address from which CPU fetches this instruction
    pub operands: FormatR, // format in which the instruction is specified.
    pub virtual_sequence_remaining: Option<u16>, // Explained below
    pub is_first_in_sequence: bool, // Explained below
    pub is_compressed: bool, // Is it a half word instruction or not
}

pub struct FormatR {
    pub rd: u8, // Will get the value 5 from the above example
    pub rs1: u8, // Will get the value 5
    pub rs2: u8, // Will get the value 4
}
```
]

So essentially the Jolt bytecode is a giant list of `struct`'s like the one discussed above.

Now if one were to closely examine every instruction in [Appendix A](#appendix-a), we would find instructions outside the RISC-ISA (such as `VirtualLW(VirtualLW)`).
For every instruction defined in the RISCV-IMAC isa, there is a corresponding `Instruction` enumeration.
But we also have some extra *virtual instructions*.
Remember, we said that proving boils down to representing program correctness as a set of polynomial equality constraints.
The constraints need to have some special mathematical structure to facilitate efficient proving.
Not all RISCV instructions can be easily represented with these special polynomial constraints.
So as discussed in the original [Jolt paper](TODO:), what we do is we take these instructions which are hard to write as "nice" polynomial constraints, and re-write them as a sequence of RISCV and made up instructions which we call virtual instructions.
This is okay to do. 
After all the Jolt CPU is something we made up. 
It can execute any instruction architecture we want.
What we really want is that after executing out made up sequence, we end up in the same machine state as we would have, had we executed the original RISC-V instruction.
The block of code responsible for this expansion is listed below found in `jolt-core/src/guest/program.rs`

```rust
pub fn decode(elf: &[u8]) -> (Vec<Instruction>, Vec<(u64, u8)>, u64) {

    // elf : sequence of bytes loaded from the elf file described above.
    // For every riscv instruction make corresponding Jolt instructions
    let (mut instructions, raw_bytes, program_end, xlen) = tracer::decode(elf);
    // ...
    // Expand virtual sequences
    // Expand complex native instructions into a sequence of many
    // instructions 
    instructions = instructions
        .into_iter()
        .flat_map(|instr| instr.inline_sequence(&allocator, xlen))
        .collect();
    // ...
}
```
This is best illustrated with a fully worked out example.

### A Worked Out Example Of Virtual Expansion

Consider the following RISC-V M extension instruction. 

From the ISA specifications, this instruction computes the upper half of the signed product of `rs1` and `rs2`, storing the high bits in `rd`. 

```asm
mulh rd, rs1, rs2
```

In Jolt there is no `mulh`. 
Instead we replace it with the following instructions.

```rust
asm.emit_i::<VirtualMovsign>(*v_sx, self.operands.rs1, 0);
asm.emit_i::<VirtualMovsign>(*v_sy, self.operands.rs2, 0);
asm.emit_r::<MULHU>(*v_0, self.operands.rs1, self.operands.rs2);
asm.emit_r::<MUL>(*v_sx, *v_sx, self.operands.rs2);
asm.emit_r::<MUL>(*v_sy, *v_sy, self.operands.rs1);
asm.emit_r::<ADD>(*v_0, *v_0, *v_sx);
asm.emit_r::<ADD>(self.operands.rd, *v_0, *v_sy);
```

What we want to show is that after we execute the above block, the value in `rd` will be exactly the same as it would have been had we just executed the native `mulhu` instruction. 
Furthermore, no other registers or memory location should be affected, and the program counter should go up by exactly the amount needed in the native instruction set. 

> **THEOREM**: The machine state before and after executing instructions `mulh` and the virtual-sequence shown above is identical.

Consulting the [Jolt ISA](@/references/jolt-isa.md), we have that 

1. `VirtualMovsign(rd, rs1, imm)`: Sets `rd` to -1 (or the all ones bit string) if the sign bit of the contents of `rs1` is on. Else it sets `rd` to 0. Succinctly, `x[rd] = (x[rs1] has sign bit set) ? -1 : 0` 
2. `MULHU`: Computes the upper half of the unsigned product of `rs1` and `rs2`, storing the high bits in `rd`.
3. `MUL`: Multiplies contents of `rs1` by contents of `rs2` as signed integers, and stores the lower `XLEN` bits of the product in `rd` as a signed integer. 
4. `ADD`: Adds the contents of `rs1` to the contents of `rs2` as signed integers, and stores the lower `XLEN` bits of the product in `rd` as a signed integer. 


We will now prove the theorem on paper, and then give you glimpse of what proving this formally in Lean looks like. 
Note that we must do this proof for **every** expanded RISCV instruction guarantee correctness[^3]. 

Define variables $z, x, y$ to denote the values in `rd`, `rs1` and `rs2` respectively.
We are told that $x$ and $y$ have width $w=$`XLEN` bits $x, y \in [-2^{w-1}, 2^{w-1}-1]$ (as they are interpreted as signed integers).
At the end of the `MULH` instruction, we have $z = \lfloor \frac{x y}{2^w}\rfloor$ i.e the higher $w$ bits of the product.

We want to show that after the sequence of virtual instructions, the value in $z$ is the exact same.
We never update $x$ and $y$ so the source registers remain unchanged in both executions.
`rd` is only updated with the last instruction in the sequence, the remaining operations are done on *virtual registers* (temporary registers that do not exist on RISC-V, so we do not risk overwriting any state). 
Note that as we are the CPU, it's fine for us to define virtual registers. 
We will later show that in the end we will prove things about machine state that is equivalent to running the original riscv instruction.
Note that the virtual instructions do also not touch memory, so we can rest safe that memory is unchanged.

Define variable $s_x := s(x)$ and $s_y:= s(y)$ where $s: [-2^{w-1}, 2^{w-1}-1] -> \\{0,-1\\}$, capturing the `MovSign` instruction such that 

$$ s(Z) = -1 \text{ if $Z < 0 $ otherwise, $0$}$$

Remember $x$ and $y$ just denote the values in `rs1` and `rs2` respectively, but interpreted as signed integers.:
Let $x'$ and $y'$ denote the values in in `rs1` and `rs2` respectively but interpreted as unsigned integers.
That is $x', y' \in [0, 2^{w -1}]$.

It is a well known fact that :
$$x = x' - s_x  2^w$$
$$y = y' - s_y  2^w$$

Therefore, 

$$x  y = x' y' + s_x y' 2^w + s_y 2^w x' - s_x s_y 2^{2w}$$

Dividing and applying the floor operation 

$$\lfloor \frac{xy}{2^w}\rfloor = \lfloor \frac{x'  y'}{2^w} \rfloor + s_x y' + s_y x' - s_x s_y 2^{w}$$
 
Note that as registers are $w$=`XLEN` bits in width, so we are essentially doing all calculations modulo $2^w$. 
This means that  $s_x s_y 2^{w} \equiv 0 \mod 2^w$.
Thus, we can safely drop the last term.

$$\lfloor \frac{x  y}{2^w}\rfloor = \lfloor \frac{x'  y'}{2^w}\rfloor + s_x y' + s_y x' $$
 
Now we re-examine the assembly code. 
```rust
asm.emit_i::<VirtualMovsign>(*v_sx, self.operands.rs1, 0);
asm.emit_i::<VirtualMovsign>(*v_sy, self.operands.rs2, 0);
```

It moves into virtual registers $s_x=s($`rs1`$)$ and $s_y=s($`rs2`$)$.
Then, 

```rust
asm.emit_r::<MULHU>(*v_0, self.operands.rs1, self.operands.rs2);
```

Sets virtual register $v_0$ to $v_0 = \lfloor(x'  y')/2^w\rfloor$ 

```rust
asm.emit_r::<MUL>(*v_sx, *v_sx, self.operands.rs2);
```

Set register $s_x = s_x y'$

```rust
asm.emit_r::<MUL>(*v_sy, *v_sy, self.operands.rs1);
```

Set register $s_y = s_y x'$

```rust
asm.emit_r::<ADD>(*v_0, *v_0, *v_sx);
```

Sets virtual register `v_0` to $\lfloor(x'  y')/2^w \rfloor + s_x y'$ 
```rust
asm.emit_r::<ADD>(self.operands.rd, *v_0, *v_sy);
```
Set the value in destination register $z$ to $z=\lfloor (x'  y')/2^w \rfloor + s_x y' + s_y x'$  which concludes the proof. 

### The Remaining Expansion Proofs 

[See this incomplete draft](TODO:) for a full list of proofs. 

### Glimpses Of A Lean Proof 


## A Side By Side Comparison Of Real Outputs

## What's Next

At this point we have the high level rust program compiled to a format the Jolt CPU understand. 
We've added instructions to the riscv architecture, and will have verified formally, that it is okay to do so. 
Now we describe how we emulate an actual CPU, and run the code in the [emulation](@/jolt-walkthrough/2_emulation.md) chapter

## Appendices

### Appendix A: Jolt Instruction Set {#appendix-a}

The Jolt data structure listing every instruction.


```rust
pub enum Instruction {
        /// No-operation instruction (address)
        NoOp,
        UNIMPL,
        ADD(ADD),
        ADDI(ADDI),
        AND(AND),
        ANDI(ANDI),
        ANDN(ANDN),
        AUIPC(AUIPC),
        BEQ(BEQ),
        BGE(BGE),
        BGEU(BGEU),
        BLT(BLT),
        BLTU(BLTU),
        BNE(BNE),
        DIV(DIV),
        DIVU(DIVU),
        ECALL(ECALL),
        FENCE(FENCE),
        JAL(JAL),
        JALR(JALR),
        LB(LB),
        LBU(LBU),
        LD(LD),
        LH(LH),
        LHU(LHU),
        LUI(LUI),
        LW(LW),
        MUL(MUL),
        MULH(MULH),
        MULHSU(MULHSU),
        MULHU(MULHU),
        OR(OR),
        ORI(ORI),
        REM(REM),
        REMU(REMU),
        SB(SB),
        SD(SD),
        SH(SH),
        SLL(SLL),
        SLLI(SLLI),
        SLT(SLT),
        SLTI(SLTI),
        SLTIU(SLTIU),
        SLTU(SLTU),
        SRA(SRA),
        SRAI(SRAI),
        SRL(SRL),
        SRLI(SRLI),
        SUB(SUB),
        SW(SW),
        XOR(XOR),
        XORI(XORI),
        ADDIW(ADDIW),
        SLLIW(SLLIW),
        SRLIW(SRLIW),
        SRAIW(SRAIW),
        ADDW(ADDW),
        SUBW(SUBW),
        SLLW(SLLW),
        SRLW(SRLW),
        SRAW(SRAW),
        LWU(LWU),
        DIVUW(DIVUW),
        DIVW(DIVW),
        MULW(MULW),
        REMUW(REMUW),
        REMW(REMW),
        LRW(LRW),
        SCW(SCW),
        AMOSWAPW(AMOSWAPW),
        AMOADDW(AMOADDW),
        AMOANDW(AMOANDW),
        AMOORW(AMOORW),
        AMOXORW(AMOXORW),
        AMOMINW(AMOMINW),
        AMOMAXW(AMOMAXW),
        AMOMINUW(AMOMINUW),
        AMOMAXUW(AMOMAXUW),
        LRD(LRD),
        SCD(SCD),
        AMOSWAPD(AMOSWAPD),
        AMOADDD(AMOADDD),
        AMOANDD(AMOANDD),
        AMOORD(AMOORD),
        AMOXORD(AMOXORD),
        AMOMIND(AMOMIND),
        AMOMAXD(AMOMAXD),
        AMOMINUD(AMOMINUD),
        AMOMAXUD(AMOMAXUD),
        VirtualAdvice(VirtualAdvice),
        VirtualAssertEQ(VirtualAssertEQ),
        VirtualAssertHalfwordAlignment(VirtualAssertHalfwordAlignment),
        VirtualAssertWordAlignment(VirtualAssertWordAlignment),
        VirtualAssertLTE(VirtualAssertLTE),
        VirtualAssertValidDiv0(VirtualAssertValidDiv0),
        VirtualAssertValidUnsignedRemainder(VirtualAssertValidUnsignedRemainder),
        VirtualAssertMulUNoOverflow(VirtualAssertMulUNoOverflow),
        VirtualChangeDivisor(VirtualChangeDivisor),
        VirtualChangeDivisorW(VirtualChangeDivisorW),
        VirtualLW(VirtualLW),
        VirtualSW(VirtualSW),
        VirtualZeroExtendWord(VirtualZeroExtendWord),
        VirtualSignExtendWord(VirtualSignExtendWord),
        VirtualPow2W(VirtualPow2W),
        VirtualPow2IW(VirtualPow2IW),
        VirtualMovsign(VirtualMovsign),
        VirtualMULI(VirtualMULI),
        VirtualPow2(VirtualPow2),
        VirtualPow2I(VirtualPow2I),
        VirtualRev8W(VirtualRev8W),
        VirtualROTRI(VirtualROTRI),
        VirtualROTRIW(VirtualROTRIW),
        VirtualShiftRightBitmask(VirtualShiftRightBitmask),
        VirtualShiftRightBitmaskI(VirtualShiftRightBitmaskI),
        VirtualSRA(VirtualSRA),
        VirtualSRAI(VirtualSRAI),
        VirtualSRL(VirtualSRL),
        VirtualSRLI(VirtualSRLI),
        VirtualXORROT32(VirtualXORROT32),
        VirtualXORROT24(VirtualXORROT24),
        VirtualXORROT16(VirtualXORROT16),
        VirtualXORROT63(VirtualXORROT63),
        VirtualXORROTW16(VirtualXORROTW16),
        VirtualXORROTW12(VirtualXORROTW12),
        VirtualXORROTW8(VirtualXORROTW8),
        VirtualXORROTW7(VirtualXORROTW7),
        /// Inline instruction from external crates
        INLINE(INLINE),
    }
}    
```
### Appendix B: The RISCV Elf



### Appendix C: The Jolt Bytecode 

## Footnotes

[^3]: More formally, we mean as correct as the original riscv assembly file.
