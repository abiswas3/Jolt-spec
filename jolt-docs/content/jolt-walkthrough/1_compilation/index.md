+++
title = "Compilation"
weight = 2
+++

In this section, we provide full details of the compilation phase of Jolt. 
At the end of this stage, we should have a data structure in memory called the `bytecode` which fully describes the user program in Jolt assembly.
That is we will cover all the parts shown in green in this section.

{% mermaid() %}
%%{init:{'themeCSS':'g:nth-child(1) rect.actor { stroke:blue;fill: pink; }; g:nth-of-type(5) rect.actor { stroke:blue;fill: pink; };'}}%%
sequenceDiagram
    participant User
    participant RISCV as RISCV Compiler
    participant Jolt as Jolt Compiler
    participant CPU as Jolt CPU
    User->>RISCV: Rust program + User Input
    Note over RISCV: Compile to RISCV-IMAC
    RISCV->>Jolt: RISCV Assembly Instructions
    Note over Jolt: Transform to Jolt Bytecode
    Jolt->>CPU: Jolt Bytecode + User Input
 
{% end %}



**NOTE**: This section of the Jolt code base is public knowledge. 
The user can inspect the binary that runs the compilation phase. 
In fact they can run this this phase themselves.
Later we will discuss parts of Jolt, the user does not get to see.

## RISC-V-IMAC 

The entry point for the user the following command

```bash
cargo run --release -p jolt-core profile --name fibonacci
```

which tells Jolt execute the program described in `jolt/examples/fibonacci/guest/src/lib.rs` (the same as one described in the [overview](@/jolt-walkthrough/0_overview/index.md)), and send me a proof that Jolt correctly executed said program.

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
The bytecode will a vector of `Instruction` defined in `jolt/tracer/src/instruction/mod.rs` under 

```rust
macro_rules! define_rv32im_enums {
    (
        instructions: [$($instr:ident),* $(,)?]
    ) => {
        #[derive(Debug, IntoStaticStr, From, Clone, Serialize, Deserialize, EnumIter)]
        pub enum Instruction {
            /// No-operation instruction (address)
            NoOp,
            UNIMPL,
            $(
                $instr($instr),
            )*
            /// Inline instruction from external crates
            INLINE(INLINE),
        }

```
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
So as discussed in the original [Jolt paper](https://eprint.iacr.org/2023/1217), what we do is we take these instructions which are hard to write as "nice" polynomial constraints, and re-write them as a sequence of RISCV and made up instructions which we call virtual instructions.
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

[See this incomplete draft](byte-code-equiv.pdf) for a full list of proofs. 

### Glimpses Of A Lean Proof 

In lean we pretty much do the same thing as we did on paper, and we heavily leverage the [Bit Vector Module](https://lean-lang.org/doc/reference/latest/Basic-Types/Bitvectors/) 

```lean
#eval (BitVec.ofNat 8 4) * (BitVec.ofNat 8 5)

def mulh (r1 : BitVec 64) (r2 : BitVec 64) : BitVec 64 := (BitVec.sshiftRight (BitVec.mul (r1.signExtend 128) (r2.signExtend 128)) 64).truncate 64

def ADD (r1 r2 : BitVec 64) : BitVec 64 := r1+r2

def MUL (r1 r2 : BitVec 64) : BitVec 64 := r1*r2

def VirtualMovsign (r1 : BitVec 64) : BitVec 64 := if (BitVec.extractLsb' 63 1 r1) == 1#1 then -1#64 else 0#64

def MULHU (r1 r2 : BitVec 64) : BitVec 64 := 
  let product : BitVec 128 := r1.zeroExtend 128 * r2.zeroExtend 128
  product.extractLsb 127 64

theorem extractLsb_eq_shift (x : BitVec 128) : BitVec.extractLsb 127 64 x = BitVec.setWidth 64 (BitVec.sshiftRight x 64) := by sorry

def jolt_mulh (r1 r2 : BitVec 64) : BitVec 64 := 
  let v_sx : BitVec 64 := VirtualMovsign r1
  let v_sy : BitVec 64 := VirtualMovsign r2
  let v_0 : BitVec 64 := MULHU r1 r2
  let v_sx_2 : BitVec 64 := MUL v_sx r2
  let v_sy_2 : BitVec 64 := MUL v_sy r1
  let v_0_2 : BitVec 64 := ADD v_0 v_sx_2
  ADD v_0_2 v_sy_2


theorem jolt_correct (r1 r2 : BitVec 64) : jolt_mulh r1 r2 = mulh r1 r2 := by 
  unfold jolt_mulh mulh VirtualMovsign MUL ADD MULHU
  by_cases h1 : (BitVec.extractLsb' 63 1 r1) == 1#1
  . by_cases h2 : (BitVec.extractLsb' 63 1 r2) == 1#1
    . simp_all
      sorry
    . simp_all
      sorry
  . by_cases h2 : (BitVec.extractLsb' 63 1 r2) == 1#1
    . simp_all
      sorry
    . simp_all
      rw [extractLsb_eq_shift (BitVec.setWidth 128 r1 * BitVec.setWidth 128 r2)]
      congr 1
      sorry




#eval (VirtualMovsign 0x8000000000000000#64)
#eval (mulh (BitVec.ofNat 64 0x8000000000000000) (BitVec.ofNat 64 2))
#eval (jolt_mulh (BitVec.ofNat 64 0x8000000000000000) (BitVec.ofNat 64 2))
#eval 3#8 + 2#8
```

## A Side By Side Comparison Of Real Outputs

Now that we have seen an example of instruction expansion, let's look at one in the wild. 
Remember the rust fibonacci program discussed in the [overview](@/jolt-walkthrough/0_overview/index.md).
`rustc` and `llvm` compile that into the `.elf` file describd in [Appendix B](#appendix-b-the-riscv-elf).
Then in [Appendix C](#appendix-c-the-jolt-bytecode) we how that code is morphed into the final Jolt byte code. 
It will be useful to stare at the two files for a minute to see equivalences, at least certain sections of the codde.
This exercise dmystifies the compilation process proving there really is no magic to this.

The riscv elf file starts with 
```asm
80000000:	00001117          	auipc	sp,0x1 ; rd = pc + imm << 12
``` 

and the Jolt bytecode starts at 

```rust
AUIPC(AUIPC { address: 2147483648, operands: FormatU { rd: 2, imm: 4096 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
```
where `rd2` is linked to the stack pointer and `2147483648` in decimal is `0x80000000` in hexadecimal. 
This instruction in not expanded by Jolt, and there is a 1:1 mapping between riscv and Jolt.
Finally, our immediate in decimal is `4096` which quite literally is `0x1 << 12`.  

The second instruction also aligns

```asm
80000004:	62810113          	addi	sp,sp,1576 # 0x80001628
```
```rust
ADDI(ADDI { address: 2147483652, operands: FormatI { rd: 2, rs1: 2, imm: 1576 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
```

Now we will not go line by line but jump to an interesting instruction. 
Before we do, you might notice that the memory starts at `0x80000000`.
This is not a co-incidence, as during compilation, if you go back to the command -- we pass a linker script described in [Appendix D](#appendix-d-linker-script).
There we say:

```
MEMORY {
  program (rwx) : ORIGIN = 0x80000000, LENGTH = 0xA00000  /* 10MB of memory (DEFAULT_MEMORY_SIZE) */
}
```

So there you have it -- everything we see is as expected.
Now we look at an instruction that expands.

```asm
80000044:	00050583          	lb	a1,0(a0) # 0x7fffa000
```

If we look at the [Jolt-ISA](@/references/jolt-isa.md) we should see the following expansion on 64 bit architectures.

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 7);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_dword, *v_shift);
    asm.emit_i::<SRAI>(self.operands.rd, self.operands.rd, 56);
    asm.finalize()
}
```

We start at `2147483716`, which is the same address as `0x80000044`. 
On inspection of the actual bytecode printed, we see more instructions than expected, but that's because the expanded instructions further expand as shown below.
You can check this with the ISA.

```rust
ADDI(ADDI { address: 2147483716, operands: FormatI { rd: 32, rs1: 10, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483716, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483716, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147483716, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
// SLLI expansion
VirtualMULI(VirtualMULI { address: 2147483716, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
// SLL expansion
VirtualPow2(VirtualPow2 { address: 2147483716, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483716, operands: FormatR { rd: 11, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
// SRAI expansion
VirtualSRAI(VirtualSRAI { address: 2147483716, operands: FormatVirtualRightShiftI { rd: 11, rs1: 11, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
```

> **NOTE**: The program counter (i.e address) never updates in virtual instructions. 

So there we have it. We now how to get Jolt-bytecode.


## What's Next

At this point we have the high level rust program compiled to a format the Jolt CPU understand. 
We've added instructions to the riscv architecture, and will have verified formally, that it is okay to do so. 
Now we describe how we emulate an actual CPU, and run the code in the [emulation](@/jolt-walkthrough/2_emulation/index.md) chapter

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

The actual [elf file](./riscv-fib-guest) generated by `rustc` and `llvm` is linked here. 
One could inspect its type with the following command.

```bash
> file /tmp/jolt-guest-targets/fibonacci-guest-/riscv64imac-unknown-none-elf/release/fibonacci-guest
/tmp/jolt-guest-targets/fibonacci-guest-/riscv64imac-unknown-none-elf/release/fibonacci-guest: ELF 64-bit LSB executable, UCB RISC-V, RVC, soft-float ABI, version 1 (SYSV), statically linked, stripped
```
Finally the disassembled code is shown below.

```bash
> riscv64-unknown-elf-objdump -d /tmp/jolt-guest-targets/fibonacci-guest-/riscv64imac-unknown-none-elf/release/fibonacci-guest
```

```bash

/tmp/jolt-guest-targets/fibonacci-guest-/riscv64imac-unknown-none-elf/release/fibonacci-guest:     file format elf64-littleriscv


Disassembly of section .text.boot:

0000000080000000 <.text.boot>:
    80000000:	00001117          	auipc	sp,0x1
    80000004:	62810113          	addi	sp,sp,1576 # 0x80001628
    80000008:	00000097          	auipc	ra,0x0
    8000000c:	02e080e7          	jalr	46(ra) # 0x80000036
    80000010:	a001                	j	0x80000010

Disassembly of section .text.unlikely._ZN4core9panicking9panic_fmt17h6b34329394ab4351E:

0000000080000012 <.text.unlikely._ZN4core9panicking9panic_fmt17h6b34329394ab4351E>:
    80000012:	1141                	addi	sp,sp,-16
    80000014:	e406                	sd	ra,8(sp)
    80000016:	e022                	sd	s0,0(sp)
    80000018:	0800                	addi	s0,sp,16
    8000001a:	7fffc537          	lui	a0,0x7fffc
    8000001e:	4585                	li	a1,1
    80000020:	00b50023          	sb	a1,0(a0) # 0x7fffc000
    80000024:	a001                	j	0x80000024

Disassembly of section .text.unlikely._ZN4core6result13unwrap_failed17hb6ec8cc04f3e1c3aE:

0000000080000026 <.text.unlikely._ZN4core6result13unwrap_failed17hb6ec8cc04f3e1c3aE>:
    80000026:	1141                	addi	sp,sp,-16
    80000028:	e406                	sd	ra,8(sp)
    8000002a:	e022                	sd	s0,0(sp)
    8000002c:	0800                	addi	s0,sp,16
    8000002e:	00000097          	auipc	ra,0x0
    80000032:	fe4080e7          	jalr	-28(ra) # 0x80000012

Disassembly of section .text.main:

0000000080000036 <.text.main>:
    80000036:	7139                	addi	sp,sp,-64
    80000038:	fc06                	sd	ra,56(sp)
    8000003a:	f822                	sd	s0,48(sp)
    8000003c:	f426                	sd	s1,40(sp)
    8000003e:	f04a                	sd	s2,32(sp)
    80000040:	7fffa537          	lui	a0,0x7fffa
    80000044:	00050583          	lb	a1,0(a0) # 0x7fffa000
    80000048:	07f5f713          	andi	a4,a1,127
    8000004c:	0405d763          	bgez	a1,0x8000009a
    80000050:	00150583          	lb	a1,1(a0)
    80000054:	07f5f613          	andi	a2,a1,127
    80000058:	061e                	slli	a2,a2,0x7
    8000005a:	8f51                	or	a4,a4,a2
    8000005c:	0205df63          	bgez	a1,0x8000009a
    80000060:	2505                	addiw	a0,a0,1
    80000062:	00150583          	lb	a1,1(a0)
    80000066:	07f5f613          	andi	a2,a1,127
    8000006a:	063a                	slli	a2,a2,0xe
    8000006c:	8f51                	or	a4,a4,a2
    8000006e:	0205d663          	bgez	a1,0x8000009a
    80000072:	00250583          	lb	a1,2(a0)
    80000076:	07f5f613          	andi	a2,a1,127
    8000007a:	0656                	slli	a2,a2,0x15
    8000007c:	8f51                	or	a4,a4,a2
    8000007e:	0005de63          	bgez	a1,0x8000009a
    80000082:	00350503          	lb	a0,3(a0)
    80000086:	2a054263          	bltz	a0,0x8000032a
    8000008a:	0ff57513          	zext.b	a0,a0
    8000008e:	45c1                	li	a1,16
    80000090:	28b57d63          	bgeu	a0,a1,0x8000032a
    80000094:	01c5151b          	slliw	a0,a0,0x1c
    80000098:	8f49                	or	a4,a4,a0
    8000009a:	00000517          	auipc	a0,0x0
    8000009e:	000c86b7          	lui	a3,0xc8
    800000a2:	4905                	li	s2,1
    800000a4:	4621                	li	a2,8
    800000a6:	50650593          	addi	a1,a0,1286 # 0x800005a0
    800000aa:	c1e6851b          	addiw	a0,a3,-994 # 0xc7c1e
    800000ae:	4685                	li	a3,1
    800000b0:	00000073          	ecall
    800000b4:	02e97463          	bgeu	s2,a4,0x800000dc
    800000b8:	4601                	li	a2,0
    800000ba:	4681                	li	a3,0
    800000bc:	4581                	li	a1,0
    800000be:	177d                	addi	a4,a4,-1
    800000c0:	4785                	li	a5,1
    800000c2:	00c78433          	add	s0,a5,a2
    800000c6:	96ae                	add	a3,a3,a1
    800000c8:	00f434b3          	sltu	s1,s0,a5
    800000cc:	94b6                	add	s1,s1,a3
    800000ce:	377d                	addiw	a4,a4,-1
    800000d0:	863e                	mv	a2,a5
    800000d2:	86ae                	mv	a3,a1
    800000d4:	87a2                	mv	a5,s0
    800000d6:	85a6                	mv	a1,s1
    800000d8:	f76d                	bnez	a4,0x800000c2
    800000da:	a019                	j	0x800000e0
    800000dc:	4481                	li	s1,0
    800000de:	4405                	li	s0,1
    800000e0:	00000597          	auipc	a1,0x0
    800000e4:	4621                	li	a2,8
    800000e6:	4c058593          	addi	a1,a1,1216 # 0x800005a0
    800000ea:	4689                	li	a3,2
    800000ec:	00000073          	ecall
    800000f0:	00e10513          	addi	a0,sp,14
    800000f4:	4649                	li	a2,18
    800000f6:	4581                	li	a1,0
    800000f8:	00000097          	auipc	ra,0x0
    800000fc:	420080e7          	jalr	1056(ra) # 0x80000518
    80000100:	00745513          	srli	a0,s0,0x7
    80000104:	03949593          	slli	a1,s1,0x39
    80000108:	8d4d                	or	a0,a0,a1
    8000010a:	0074d593          	srli	a1,s1,0x7
    8000010e:	8dc9                	or	a1,a1,a0
    80000110:	008106a3          	sb	s0,13(sp)
    80000114:	1e058763          	beqz	a1,0x80000302
    80000118:	08046593          	ori	a1,s0,128
    8000011c:	00e45613          	srli	a2,s0,0xe
    80000120:	03249693          	slli	a3,s1,0x32
    80000124:	00b106a3          	sb	a1,13(sp)
    80000128:	00a10723          	sb	a0,14(sp)
    8000012c:	00d665b3          	or	a1,a2,a3
    80000130:	00e4d613          	srli	a2,s1,0xe
    80000134:	8e4d                	or	a2,a2,a1
    80000136:	4909                	li	s2,2
    80000138:	1c060563          	beqz	a2,0x80000302
    8000013c:	08056613          	ori	a2,a0,128
    80000140:	01545513          	srli	a0,s0,0x15
    80000144:	02b49693          	slli	a3,s1,0x2b
    80000148:	8d55                	or	a0,a0,a3
    8000014a:	0154d693          	srli	a3,s1,0x15
    8000014e:	8ec9                	or	a3,a3,a0
    80000150:	00c10723          	sb	a2,14(sp)
    80000154:	00b107a3          	sb	a1,15(sp)
    80000158:	16068663          	beqz	a3,0x800002c4
    8000015c:	0805e613          	ori	a2,a1,128
    80000160:	01c45593          	srli	a1,s0,0x1c
    80000164:	02449693          	slli	a3,s1,0x24
    80000168:	8dd5                	or	a1,a1,a3
    8000016a:	01c4d693          	srli	a3,s1,0x1c
    8000016e:	8ecd                	or	a3,a3,a1
    80000170:	00c107a3          	sb	a2,15(sp)
    80000174:	00a10823          	sb	a0,16(sp)
    80000178:	14068863          	beqz	a3,0x800002c8
    8000017c:	08056613          	ori	a2,a0,128
    80000180:	02345513          	srli	a0,s0,0x23
    80000184:	01d49693          	slli	a3,s1,0x1d
    80000188:	8d55                	or	a0,a0,a3
    8000018a:	0234d693          	srli	a3,s1,0x23
    8000018e:	8ec9                	or	a3,a3,a0
    80000190:	00c10823          	sb	a2,16(sp)
    80000194:	00b108a3          	sb	a1,17(sp)
    80000198:	12068a63          	beqz	a3,0x800002cc
    8000019c:	0805e613          	ori	a2,a1,128
    800001a0:	02a45593          	srli	a1,s0,0x2a
    800001a4:	01649693          	slli	a3,s1,0x16
    800001a8:	8dd5                	or	a1,a1,a3
    800001aa:	02a4d693          	srli	a3,s1,0x2a
    800001ae:	8ecd                	or	a3,a3,a1
    800001b0:	00c108a3          	sb	a2,17(sp)
    800001b4:	00a10923          	sb	a0,18(sp)
    800001b8:	10068c63          	beqz	a3,0x800002d0
    800001bc:	08056613          	ori	a2,a0,128
    800001c0:	03145513          	srli	a0,s0,0x31
    800001c4:	00f49693          	slli	a3,s1,0xf
    800001c8:	8d55                	or	a0,a0,a3
    800001ca:	0314d693          	srli	a3,s1,0x31
    800001ce:	8ec9                	or	a3,a3,a0
    800001d0:	00c10923          	sb	a2,18(sp)
    800001d4:	00b109a3          	sb	a1,19(sp)
    800001d8:	cef5                	beqz	a3,0x800002d4
    800001da:	0805e613          	ori	a2,a1,128
    800001de:	03845593          	srli	a1,s0,0x38
    800001e2:	00849693          	slli	a3,s1,0x8
    800001e6:	8dd5                	or	a1,a1,a3
    800001e8:	0384d693          	srli	a3,s1,0x38
    800001ec:	8ecd                	or	a3,a3,a1
    800001ee:	00c109a3          	sb	a2,19(sp)
    800001f2:	00a10a23          	sb	a0,20(sp)
    800001f6:	c2ed                	beqz	a3,0x800002d8
    800001f8:	08056613          	ori	a2,a0,128
    800001fc:	907d                	srli	s0,s0,0x3f
    800001fe:	00149513          	slli	a0,s1,0x1
    80000202:	8d41                	or	a0,a0,s0
    80000204:	03f4d693          	srli	a3,s1,0x3f
    80000208:	8ec9                	or	a3,a3,a0
    8000020a:	00c10a23          	sb	a2,20(sp)
    8000020e:	00b10aa3          	sb	a1,21(sp)
    80000212:	c6e9                	beqz	a3,0x800002dc
    80000214:	0805e613          	ori	a2,a1,128
    80000218:	0064d593          	srli	a1,s1,0x6
    8000021c:	00c10aa3          	sb	a2,21(sp)
    80000220:	00a10b23          	sb	a0,22(sp)
    80000224:	cdd5                	beqz	a1,0x800002e0
    80000226:	08056613          	ori	a2,a0,128
    8000022a:	00d4d513          	srli	a0,s1,0xd
    8000022e:	00c10b23          	sb	a2,22(sp)
    80000232:	00b10ba3          	sb	a1,23(sp)
    80000236:	c55d                	beqz	a0,0x800002e4
    80000238:	0805e613          	ori	a2,a1,128
    8000023c:	0144d593          	srli	a1,s1,0x14
    80000240:	00c10ba3          	sb	a2,23(sp)
    80000244:	00a10c23          	sb	a0,24(sp)
    80000248:	c1c5                	beqz	a1,0x800002e8
    8000024a:	08056613          	ori	a2,a0,128
    8000024e:	01b4d513          	srli	a0,s1,0x1b
    80000252:	00c10c23          	sb	a2,24(sp)
    80000256:	00b10ca3          	sb	a1,25(sp)
    8000025a:	c949                	beqz	a0,0x800002ec
    8000025c:	0805e613          	ori	a2,a1,128
    80000260:	0224d593          	srli	a1,s1,0x22
    80000264:	00c10ca3          	sb	a2,25(sp)
    80000268:	00a10d23          	sb	a0,26(sp)
    8000026c:	c1d1                	beqz	a1,0x800002f0
    8000026e:	08056613          	ori	a2,a0,128
    80000272:	0294d513          	srli	a0,s1,0x29
    80000276:	00c10d23          	sb	a2,26(sp)
    8000027a:	00b10da3          	sb	a1,27(sp)
    8000027e:	c93d                	beqz	a0,0x800002f4
    80000280:	0805e613          	ori	a2,a1,128
    80000284:	0304d593          	srli	a1,s1,0x30
    80000288:	00c10da3          	sb	a2,27(sp)
    8000028c:	00a10e23          	sb	a0,28(sp)
    80000290:	c5a5                	beqz	a1,0x800002f8
    80000292:	08056613          	ori	a2,a0,128
    80000296:	0374d513          	srli	a0,s1,0x37
    8000029a:	00c10e23          	sb	a2,28(sp)
    8000029e:	00b10ea3          	sb	a1,29(sp)
    800002a2:	cd29                	beqz	a0,0x800002fc
    800002a4:	0805e593          	ori	a1,a1,128
    800002a8:	90f9                	srli	s1,s1,0x3e
    800002aa:	00b10ea3          	sb	a1,29(sp)
    800002ae:	00a10f23          	sb	a0,30(sp)
    800002b2:	c4b9                	beqz	s1,0x80000300
    800002b4:	08056513          	ori	a0,a0,128
    800002b8:	00a10f23          	sb	a0,30(sp)
    800002bc:	00910fa3          	sb	s1,31(sp)
    800002c0:	494d                	li	s2,19
    800002c2:	a081                	j	0x80000302
    800002c4:	490d                	li	s2,3
    800002c6:	a835                	j	0x80000302
    800002c8:	4911                	li	s2,4
    800002ca:	a825                	j	0x80000302
    800002cc:	4915                	li	s2,5
    800002ce:	a815                	j	0x80000302
    800002d0:	4919                	li	s2,6
    800002d2:	a805                	j	0x80000302
    800002d4:	491d                	li	s2,7
    800002d6:	a035                	j	0x80000302
    800002d8:	4921                	li	s2,8
    800002da:	a025                	j	0x80000302
    800002dc:	4925                	li	s2,9
    800002de:	a015                	j	0x80000302
    800002e0:	4929                	li	s2,10
    800002e2:	a005                	j	0x80000302
    800002e4:	492d                	li	s2,11
    800002e6:	a831                	j	0x80000302
    800002e8:	4931                	li	s2,12
    800002ea:	a821                	j	0x80000302
    800002ec:	4935                	li	s2,13
    800002ee:	a811                	j	0x80000302
    800002f0:	4939                	li	s2,14
    800002f2:	a801                	j	0x80000302
    800002f4:	493d                	li	s2,15
    800002f6:	a031                	j	0x80000302
    800002f8:	4941                	li	s2,16
    800002fa:	a021                	j	0x80000302
    800002fc:	4945                	li	s2,17
    800002fe:	a011                	j	0x80000302
    80000300:	4949                	li	s2,18
    80000302:	7fffb537          	lui	a0,0x7fffb
    80000306:	00d10593          	addi	a1,sp,13
    8000030a:	864a                	mv	a2,s2
    8000030c:	00000097          	auipc	ra,0x0
    80000310:	026080e7          	jalr	38(ra) # 0x80000332
    80000314:	7fffc537          	lui	a0,0x7fffc
    80000318:	4585                	li	a1,1
    8000031a:	00b50423          	sb	a1,8(a0) # 0x7fffc008
    8000031e:	70e2                	ld	ra,56(sp)
    80000320:	7442                	ld	s0,48(sp)
    80000322:	74a2                	ld	s1,40(sp)
    80000324:	7902                	ld	s2,32(sp)
    80000326:	6121                	addi	sp,sp,64
    80000328:	8082                	ret
    8000032a:	00000097          	auipc	ra,0x0
    8000032e:	cfc080e7          	jalr	-772(ra) # 0x80000026

Disassembly of section .text.memcpy:

0000000080000332 <.text.memcpy>:
    80000332:	1141                	addi	sp,sp,-16
    80000334:	e406                	sd	ra,8(sp)
    80000336:	e022                	sd	s0,0(sp)
    80000338:	0800                	addi	s0,sp,16
    8000033a:	60a2                	ld	ra,8(sp)
    8000033c:	6402                	ld	s0,0(sp)
    8000033e:	0141                	addi	sp,sp,16
    80000340:	00000317          	auipc	t1,0x0
    80000344:	00830067          	jr	8(t1) # 0x80000348

Disassembly of section .text._ZN17compiler_builtins3mem6memcpy17hb9476cf9b0fe9797E:

0000000080000348 <.text._ZN17compiler_builtins3mem6memcpy17hb9476cf9b0fe9797E>:
    80000348:	1101                	addi	sp,sp,-32
    8000034a:	ec06                	sd	ra,24(sp)
    8000034c:	e822                	sd	s0,16(sp)
    8000034e:	e426                	sd	s1,8(sp)
    80000350:	1000                	addi	s0,sp,32
    80000352:	46c1                	li	a3,16
    80000354:	06d66263          	bltu	a2,a3,0x800003b8
    80000358:	40a006bb          	negw	a3,a0
    8000035c:	0076f813          	andi	a6,a3,7
    80000360:	01050fb3          	add	t6,a0,a6
    80000364:	01f57d63          	bgeu	a0,t6,0x8000037e
    80000368:	8742                	mv	a4,a6
    8000036a:	86aa                	mv	a3,a0
    8000036c:	87ae                	mv	a5,a1
    8000036e:	0007c883          	lbu	a7,0(a5)
    80000372:	177d                	addi	a4,a4,-1
    80000374:	01168023          	sb	a7,0(a3)
    80000378:	0685                	addi	a3,a3,1
    8000037a:	0785                	addi	a5,a5,1
    8000037c:	fb6d                	bnez	a4,0x8000036e
    8000037e:	95c2                	add	a1,a1,a6
    80000380:	410604b3          	sub	s1,a2,a6
    80000384:	ff84f713          	andi	a4,s1,-8
    80000388:	0075f813          	andi	a6,a1,7
    8000038c:	00ef86b3          	add	a3,t6,a4
    80000390:	04081663          	bnez	a6,0x800003dc
    80000394:	00dffa63          	bgeu	t6,a3,0x800003a8
    80000398:	87ae                	mv	a5,a1
    8000039a:	6390                	ld	a2,0(a5)
    8000039c:	00cfb023          	sd	a2,0(t6)
    800003a0:	0fa1                	addi	t6,t6,8
    800003a2:	07a1                	addi	a5,a5,8
    800003a4:	fedfebe3          	bltu	t6,a3,0x8000039a
    800003a8:	95ba                	add	a1,a1,a4
    800003aa:	0074f613          	andi	a2,s1,7
    800003ae:	00c68733          	add	a4,a3,a2
    800003b2:	00e6e863          	bltu	a3,a4,0x800003c2
    800003b6:	a831                	j	0x800003d2
    800003b8:	86aa                	mv	a3,a0
    800003ba:	00c50733          	add	a4,a0,a2
    800003be:	00e57a63          	bgeu	a0,a4,0x800003d2
    800003c2:	0005c703          	lbu	a4,0(a1)
    800003c6:	167d                	addi	a2,a2,-1
    800003c8:	00e68023          	sb	a4,0(a3)
    800003cc:	0685                	addi	a3,a3,1
    800003ce:	0585                	addi	a1,a1,1
    800003d0:	fa6d                	bnez	a2,0x800003c2
    800003d2:	60e2                	ld	ra,24(sp)
    800003d4:	6442                	ld	s0,16(sp)
    800003d6:	64a2                	ld	s1,8(sp)
    800003d8:	6105                	addi	sp,sp,32
    800003da:	8082                	ret
    800003dc:	4881                	li	a7,0
    800003de:	4621                	li	a2,8
    800003e0:	fe043023          	sd	zero,-32(s0)
    800003e4:	41060333          	sub	t1,a2,a6
    800003e8:	fe040613          	addi	a2,s0,-32
    800003ec:	00137793          	andi	a5,t1,1
    800003f0:	010662b3          	or	t0,a2,a6
    800003f4:	ebb1                	bnez	a5,0x80000448
    800003f6:	00237613          	andi	a2,t1,2
    800003fa:	ee39                	bnez	a2,0x80000458
    800003fc:	00437613          	andi	a2,t1,4
    80000400:	ea25                	bnez	a2,0x80000470
    80000402:	fe043e83          	ld	t4,-32(s0)
    80000406:	00381893          	slli	a7,a6,0x3
    8000040a:	008f8613          	addi	a2,t6,8
    8000040e:	41058f33          	sub	t5,a1,a6
    80000412:	06d67f63          	bgeu	a2,a3,0x80000490
    80000416:	4110063b          	negw	a2,a7
    8000041a:	03867393          	andi	t2,a2,56
    8000041e:	008f3283          	ld	t0,8(t5)
    80000422:	008f0e13          	addi	t3,t5,8
    80000426:	011ed633          	srl	a2,t4,a7
    8000042a:	008f8313          	addi	t1,t6,8
    8000042e:	007297b3          	sll	a5,t0,t2
    80000432:	8e5d                	or	a2,a2,a5
    80000434:	010f8793          	addi	a5,t6,16
    80000438:	00cfb023          	sd	a2,0(t6)
    8000043c:	8f9a                	mv	t6,t1
    8000043e:	8f72                	mv	t5,t3
    80000440:	8e96                	mv	t4,t0
    80000442:	fcd7eee3          	bltu	a5,a3,0x8000041e
    80000446:	a881                	j	0x80000496
    80000448:	0005c603          	lbu	a2,0(a1)
    8000044c:	00c28023          	sb	a2,0(t0)
    80000450:	4885                	li	a7,1
    80000452:	00237613          	andi	a2,t1,2
    80000456:	d25d                	beqz	a2,0x800003fc
    80000458:	01158633          	add	a2,a1,a7
    8000045c:	00061603          	lh	a2,0(a2)
    80000460:	011287b3          	add	a5,t0,a7
    80000464:	00c79023          	sh	a2,0(a5)
    80000468:	0889                	addi	a7,a7,2
    8000046a:	00437613          	andi	a2,t1,4
    8000046e:	da51                	beqz	a2,0x80000402
    80000470:	01158633          	add	a2,a1,a7
    80000474:	4210                	lw	a2,0(a2)
    80000476:	9896                	add	a7,a7,t0
    80000478:	00c8a023          	sw	a2,0(a7)
    8000047c:	fe043e83          	ld	t4,-32(s0)
    80000480:	00381893          	slli	a7,a6,0x3
    80000484:	008f8613          	addi	a2,t6,8
    80000488:	41058f33          	sub	t5,a1,a6
    8000048c:	f8d665e3          	bltu	a2,a3,0x80000416
    80000490:	82f6                	mv	t0,t4
    80000492:	8e7a                	mv	t3,t5
    80000494:	837e                	mv	t1,t6
    80000496:	4781                	li	a5,0
    80000498:	008e0393          	addi	t2,t3,8
    8000049c:	4611                	li	a2,4
    8000049e:	fe043023          	sd	zero,-32(s0)
    800004a2:	04c87563          	bgeu	a6,a2,0x800004ec
    800004a6:	0025f613          	andi	a2,a1,2
    800004aa:	ea29                	bnez	a2,0x800004fc
    800004ac:	0015f613          	andi	a2,a1,1
    800004b0:	ca09                	beqz	a2,0x800004c2
    800004b2:	93be                	add	t2,t2,a5
    800004b4:	0003c803          	lbu	a6,0(t2)
    800004b8:	fe040613          	addi	a2,s0,-32
    800004bc:	8e5d                	or	a2,a2,a5
    800004be:	01060023          	sb	a6,0(a2)
    800004c2:	fe043803          	ld	a6,-32(s0)
    800004c6:	0112d7b3          	srl	a5,t0,a7
    800004ca:	4110063b          	negw	a2,a7
    800004ce:	03867613          	andi	a2,a2,56
    800004d2:	00c81633          	sll	a2,a6,a2
    800004d6:	8e5d                	or	a2,a2,a5
    800004d8:	00c33023          	sd	a2,0(t1)
    800004dc:	95ba                	add	a1,a1,a4
    800004de:	0074f613          	andi	a2,s1,7
    800004e2:	00c68733          	add	a4,a3,a2
    800004e6:	ece6eee3          	bltu	a3,a4,0x800003c2
    800004ea:	b5e5                	j	0x800003d2
    800004ec:	0003a603          	lw	a2,0(t2)
    800004f0:	fec42023          	sw	a2,-32(s0)
    800004f4:	4791                	li	a5,4
    800004f6:	0025f613          	andi	a2,a1,2
    800004fa:	da4d                	beqz	a2,0x800004ac
    800004fc:	00f38633          	add	a2,t2,a5
    80000500:	00061803          	lh	a6,0(a2)
    80000504:	fe040613          	addi	a2,s0,-32
    80000508:	8e5d                	or	a2,a2,a5
    8000050a:	01061023          	sh	a6,0(a2)
    8000050e:	0789                	addi	a5,a5,2
    80000510:	0015f613          	andi	a2,a1,1
    80000514:	fe59                	bnez	a2,0x800004b2
    80000516:	b775                	j	0x800004c2

Disassembly of section .text.memset:

0000000080000518 <.text.memset>:
    80000518:	1141                	addi	sp,sp,-16
    8000051a:	e406                	sd	ra,8(sp)
    8000051c:	e022                	sd	s0,0(sp)
    8000051e:	0800                	addi	s0,sp,16
    80000520:	46c1                	li	a3,16
    80000522:	06d66763          	bltu	a2,a3,0x80000590
    80000526:	40a006bb          	negw	a3,a0
    8000052a:	0076f813          	andi	a6,a3,7
    8000052e:	01050733          	add	a4,a0,a6
    80000532:	00e57963          	bgeu	a0,a4,0x80000544
    80000536:	87c2                	mv	a5,a6
    80000538:	86aa                	mv	a3,a0
    8000053a:	00b68023          	sb	a1,0(a3)
    8000053e:	17fd                	addi	a5,a5,-1
    80000540:	0685                	addi	a3,a3,1
    80000542:	ffe5                	bnez	a5,0x8000053a
    80000544:	41060633          	sub	a2,a2,a6
    80000548:	ff867693          	andi	a3,a2,-8
    8000054c:	96ba                	add	a3,a3,a4
    8000054e:	02d77363          	bgeu	a4,a3,0x80000574
    80000552:	03859813          	slli	a6,a1,0x38
    80000556:	101017b7          	lui	a5,0x10101
    8000055a:	0792                	slli	a5,a5,0x4
    8000055c:	10078793          	addi	a5,a5,256 # 0x10101100
    80000560:	02f83833          	mulhu	a6,a6,a5
    80000564:	02081793          	slli	a5,a6,0x20
    80000568:	0107e7b3          	or	a5,a5,a6
    8000056c:	e31c                	sd	a5,0(a4)
    8000056e:	0721                	addi	a4,a4,8
    80000570:	fed76ee3          	bltu	a4,a3,0x8000056c
    80000574:	8a1d                	andi	a2,a2,7
    80000576:	00c68733          	add	a4,a3,a2
    8000057a:	00e6f763          	bgeu	a3,a4,0x80000588
    8000057e:	00b68023          	sb	a1,0(a3)
    80000582:	167d                	addi	a2,a2,-1
    80000584:	0685                	addi	a3,a3,1
    80000586:	fe65                	bnez	a2,0x8000057e
    80000588:	60a2                	ld	ra,8(sp)
    8000058a:	6402                	ld	s0,0(sp)
    8000058c:	0141                	addi	sp,sp,16
    8000058e:	8082                	ret
    80000590:	86aa                	mv	a3,a0
    80000592:	00c50733          	add	a4,a0,a2
    80000596:	fee564e3          	bltu	a0,a4,0x8000057e
    8000059a:	b7fd                	j	0x80000588
```

### Appendix C: The Jolt Bytecode 

To see the actual Jolt bytecode for the same program, we inject this code in `/Users/francis/Work-With-A16z/jolt/jolt-core/benches/e2e_profiling.rs` in the `prove_example` function.
There are cleverer ways to do this, but this quick n dirty trick does everything we needed for pedagogy.

```rust
let (bytecode, init_memory_state, _) = program.decode();
//Just print each instruction
    for inst in &bytecode {
        println!("{:?}", inst);
    }
    panic!("Artifically exitting");
    // Exit program
    // Of course we delete this immediately after we've extracted the bytecode.
```

We link the [file](./fib-byte.jolt.asm) and display the full code in all its glory.

```rust
AUIPC(AUIPC { address: 2147483648, operands: FormatU { rd: 2, imm: 4096 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483652, operands: FormatI { rd: 2, rs1: 2, imm: 1576 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
AUIPC(AUIPC { address: 2147483656, operands: FormatU { rd: 1, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JALR(JALR { address: 2147483660, operands: FormatI { rd: 1, rs1: 1, imm: 46 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JAL(JAL { address: 2147483664, operands: FormatJ { rd: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483666, operands: FormatI { rd: 2, rs1: 2, imm: 18446744073709551600 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147483668, operands: FormatS { rs1: 2, rs2: 1, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147483670, operands: FormatS { rs1: 2, rs2: 8, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483672, operands: FormatI { rd: 8, rs1: 2, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LUI(LUI { address: 2147483674, operands: FormatU { rd: 10, imm: 2147467264 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483678, operands: FormatI { rd: 11, rs1: 0, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483680, operands: FormatI { rd: 32, rs1: 10, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483680, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483680, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483680, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147483680, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483680, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483680, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483680, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483680, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483680, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147483680, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483680, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147483680, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
JAL(JAL { address: 2147483684, operands: FormatJ { rd: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483686, operands: FormatI { rd: 2, rs1: 2, imm: 18446744073709551600 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147483688, operands: FormatS { rs1: 2, rs2: 1, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147483690, operands: FormatS { rs1: 2, rs2: 8, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483692, operands: FormatI { rd: 8, rs1: 2, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
AUIPC(AUIPC { address: 2147483694, operands: FormatU { rd: 1, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JALR(JALR { address: 2147483698, operands: FormatI { rd: 1, rs1: 1, imm: 18446744073709551588 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483702, operands: FormatI { rd: 2, rs1: 2, imm: 18446744073709551552 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147483704, operands: FormatS { rs1: 2, rs2: 1, imm: 56 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147483706, operands: FormatS { rs1: 2, rs2: 8, imm: 48 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147483708, operands: FormatS { rs1: 2, rs2: 9, imm: 40 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147483710, operands: FormatS { rs1: 2, rs2: 18, imm: 32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LUI(LUI { address: 2147483712, operands: FormatU { rd: 10, imm: 2147459072 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483716, operands: FormatI { rd: 32, rs1: 10, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483716, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483716, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147483716, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483716, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483716, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483716, operands: FormatR { rd: 11, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRAI(VirtualSRAI { address: 2147483716, operands: FormatVirtualRightShiftI { rd: 11, rs1: 11, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147483720, operands: FormatI { rd: 14, rs1: 11, imm: 127 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGE(BGE { address: 2147483724, operands: FormatB { rs1: 11, rs2: 0, imm: 78 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483728, operands: FormatI { rd: 32, rs1: 10, imm: 1 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483728, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483728, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147483728, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483728, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483728, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483728, operands: FormatR { rd: 11, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRAI(VirtualSRAI { address: 2147483728, operands: FormatVirtualRightShiftI { rd: 11, rs1: 11, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147483732, operands: FormatI { rd: 12, rs1: 11, imm: 127 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483736, operands: FormatI { rd: 12, rs1: 12, imm: 128 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: true })
OR(OR { address: 2147483738, operands: FormatR { rd: 14, rs1: 14, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BGE(BGE { address: 2147483740, operands: FormatB { rs1: 11, rs2: 0, imm: 62 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483744, operands: FormatI { rd: 10, rs1: 10, imm: 1 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147483744, operands: FormatI { rd: 10, rs1: 10, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483746, operands: FormatI { rd: 32, rs1: 10, imm: 1 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483746, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483746, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147483746, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483746, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483746, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483746, operands: FormatR { rd: 11, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRAI(VirtualSRAI { address: 2147483746, operands: FormatVirtualRightShiftI { rd: 11, rs1: 11, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147483750, operands: FormatI { rd: 12, rs1: 11, imm: 127 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483754, operands: FormatI { rd: 12, rs1: 12, imm: 16384 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: true })
OR(OR { address: 2147483756, operands: FormatR { rd: 14, rs1: 14, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BGE(BGE { address: 2147483758, operands: FormatB { rs1: 11, rs2: 0, imm: 44 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483762, operands: FormatI { rd: 32, rs1: 10, imm: 2 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483762, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483762, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147483762, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483762, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483762, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483762, operands: FormatR { rd: 11, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRAI(VirtualSRAI { address: 2147483762, operands: FormatVirtualRightShiftI { rd: 11, rs1: 11, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147483766, operands: FormatI { rd: 12, rs1: 11, imm: 127 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483770, operands: FormatI { rd: 12, rs1: 12, imm: 2097152 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: true })
OR(OR { address: 2147483772, operands: FormatR { rd: 14, rs1: 14, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BGE(BGE { address: 2147483774, operands: FormatB { rs1: 11, rs2: 0, imm: 28 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483778, operands: FormatI { rd: 32, rs1: 10, imm: 3 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483778, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483778, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147483778, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483778, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483778, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483778, operands: FormatR { rd: 10, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRAI(VirtualSRAI { address: 2147483778, operands: FormatVirtualRightShiftI { rd: 10, rs1: 10, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BLT(BLT { address: 2147483782, operands: FormatB { rs1: 10, rs2: 0, imm: 676 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147483786, operands: FormatI { rd: 10, rs1: 10, imm: 255 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483790, operands: FormatI { rd: 11, rs1: 0, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BGEU(BGEU { address: 2147483792, operands: FormatB { rs1: 10, rs2: 11, imm: 666 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483796, operands: FormatI { rd: 10, rs1: 10, imm: 268435456 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147483796, operands: FormatI { rd: 10, rs1: 10, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
OR(OR { address: 2147483800, operands: FormatR { rd: 14, rs1: 14, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
AUIPC(AUIPC { address: 2147483802, operands: FormatU { rd: 10, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147483806, operands: FormatU { rd: 13, imm: 819200 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483810, operands: FormatI { rd: 18, rs1: 0, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483812, operands: FormatI { rd: 12, rs1: 0, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483814, operands: FormatI { rd: 11, rs1: 10, imm: 1286 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483818, operands: FormatI { rd: 10, rs1: 13, imm: 18446744073709550622 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147483818, operands: FormatI { rd: 10, rs1: 10, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483822, operands: FormatI { rd: 13, rs1: 0, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ECALL(ECALL { address: 2147483824, operands: FormatI { rd: 0, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGEU(BGEU { address: 2147483828, operands: FormatB { rs1: 18, rs2: 14, imm: 40 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483832, operands: FormatI { rd: 12, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483834, operands: FormatI { rd: 13, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483836, operands: FormatI { rd: 11, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483838, operands: FormatI { rd: 14, rs1: 14, imm: 18446744073709551615 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483840, operands: FormatI { rd: 15, rs1: 0, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147483842, operands: FormatR { rd: 8, rs1: 15, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147483846, operands: FormatR { rd: 13, rs1: 13, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SLTU(SLTU { address: 2147483848, operands: FormatR { rd: 9, rs1: 8, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147483852, operands: FormatR { rd: 9, rs1: 9, rs2: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483854, operands: FormatI { rd: 14, rs1: 14, imm: 18446744073709551615 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147483854, operands: FormatI { rd: 14, rs1: 14, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147483856, operands: FormatR { rd: 12, rs1: 0, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147483858, operands: FormatR { rd: 13, rs1: 0, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147483860, operands: FormatR { rd: 15, rs1: 0, rs2: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147483862, operands: FormatR { rd: 11, rs1: 0, rs2: 9 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BNE(BNE { address: 2147483864, operands: FormatB { rs1: 0, rs2: 14, imm: -22 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147483866, operands: FormatJ { rd: 0, imm: 6 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483868, operands: FormatI { rd: 9, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483870, operands: FormatI { rd: 8, rs1: 0, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
AUIPC(AUIPC { address: 2147483872, operands: FormatU { rd: 11, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483876, operands: FormatI { rd: 12, rs1: 0, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483878, operands: FormatI { rd: 11, rs1: 11, imm: 1216 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483882, operands: FormatI { rd: 13, rs1: 0, imm: 2 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ECALL(ECALL { address: 2147483884, operands: FormatI { rd: 0, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483888, operands: FormatI { rd: 10, rs1: 2, imm: 14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483892, operands: FormatI { rd: 12, rs1: 0, imm: 18 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483894, operands: FormatI { rd: 11, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
AUIPC(AUIPC { address: 2147483896, operands: FormatU { rd: 1, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JALR(JALR { address: 2147483900, operands: FormatI { rd: 1, rs1: 1, imm: 1056 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147483904, operands: FormatVirtualRightShiftI { rd: 10, rs1: 8, imm: 18446744073709551488 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483908, operands: FormatI { rd: 11, rs1: 9, imm: 144115188075855872 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147483912, operands: FormatR { rd: 10, rs1: 10, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualSRLI(VirtualSRLI { address: 2147483914, operands: FormatVirtualRightShiftI { rd: 11, rs1: 9, imm: 18446744073709551488 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147483918, operands: FormatR { rd: 11, rs1: 11, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483920, operands: FormatI { rd: 32, rs1: 2, imm: 13 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483920, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483920, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483920, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147483920, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483920, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483920, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483920, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483920, operands: FormatR { rd: 37, rs1: 8, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483920, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147483920, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483920, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147483920, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147483924, operands: FormatB { rs1: 11, rs2: 0, imm: 494 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ORI(ORI { address: 2147483928, operands: FormatI { rd: 11, rs1: 8, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147483932, operands: FormatVirtualRightShiftI { rd: 12, rs1: 8, imm: 18446744073709535232 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483936, operands: FormatI { rd: 13, rs1: 9, imm: 1125899906842624 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147483940, operands: FormatI { rd: 32, rs1: 2, imm: 13 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483940, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483940, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483940, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147483940, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483940, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483940, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483940, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483940, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483940, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147483940, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483940, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147483940, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483944, operands: FormatI { rd: 32, rs1: 2, imm: 14 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483944, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483944, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483944, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147483944, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483944, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483944, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483944, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483944, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483944, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147483944, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483944, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147483944, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
OR(OR { address: 2147483948, operands: FormatR { rd: 11, rs1: 12, rs2: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147483952, operands: FormatVirtualRightShiftI { rd: 12, rs1: 9, imm: 18446744073709535232 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147483956, operands: FormatR { rd: 12, rs1: 12, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483958, operands: FormatI { rd: 18, rs1: 0, imm: 2 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BEQ(BEQ { address: 2147483960, operands: FormatB { rs1: 12, rs2: 0, imm: 458 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ORI(ORI { address: 2147483964, operands: FormatI { rd: 12, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147483968, operands: FormatVirtualRightShiftI { rd: 10, rs1: 8, imm: 18446744073707454464 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483972, operands: FormatI { rd: 13, rs1: 9, imm: 8796093022208 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147483976, operands: FormatR { rd: 10, rs1: 10, rs2: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualSRLI(VirtualSRLI { address: 2147483978, operands: FormatVirtualRightShiftI { rd: 13, rs1: 9, imm: 18446744073707454464 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147483982, operands: FormatR { rd: 13, rs1: 13, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147483984, operands: FormatI { rd: 32, rs1: 2, imm: 14 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483984, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483984, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483984, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147483984, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483984, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483984, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483984, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483984, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483984, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147483984, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483984, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147483984, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147483988, operands: FormatI { rd: 32, rs1: 2, imm: 15 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147483988, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147483988, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147483988, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147483988, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483988, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483988, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147483988, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147483988, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483988, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147483988, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147483988, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147483988, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147483992, operands: FormatB { rs1: 13, rs2: 0, imm: 364 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ORI(ORI { address: 2147483996, operands: FormatI { rd: 12, rs1: 11, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484000, operands: FormatVirtualRightShiftI { rd: 11, rs1: 8, imm: 18446744073441116160 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484004, operands: FormatI { rd: 13, rs1: 9, imm: 68719476736 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484008, operands: FormatR { rd: 11, rs1: 11, rs2: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualSRLI(VirtualSRLI { address: 2147484010, operands: FormatVirtualRightShiftI { rd: 13, rs1: 9, imm: 18446744073441116160 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484014, operands: FormatR { rd: 13, rs1: 13, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484016, operands: FormatI { rd: 32, rs1: 2, imm: 15 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484016, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484016, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484016, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484016, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484016, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484016, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484016, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484016, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484016, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484016, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484016, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484016, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484020, operands: FormatI { rd: 32, rs1: 2, imm: 16 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484020, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484020, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484020, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484020, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484020, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484020, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484020, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484020, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484020, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484020, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484020, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484020, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484024, operands: FormatB { rs1: 13, rs2: 0, imm: 336 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ORI(ORI { address: 2147484028, operands: FormatI { rd: 12, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484032, operands: FormatVirtualRightShiftI { rd: 10, rs1: 8, imm: 18446744039349813248 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484036, operands: FormatI { rd: 13, rs1: 9, imm: 536870912 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484040, operands: FormatR { rd: 10, rs1: 10, rs2: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualSRLI(VirtualSRLI { address: 2147484042, operands: FormatVirtualRightShiftI { rd: 13, rs1: 9, imm: 18446744039349813248 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484046, operands: FormatR { rd: 13, rs1: 13, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484048, operands: FormatI { rd: 32, rs1: 2, imm: 16 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484048, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484048, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484048, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484048, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484048, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484048, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484048, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484048, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484048, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484048, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484048, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484048, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484052, operands: FormatI { rd: 32, rs1: 2, imm: 17 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484052, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484052, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484052, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484052, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484052, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484052, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484052, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484052, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484052, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484052, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484052, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484052, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484056, operands: FormatB { rs1: 13, rs2: 0, imm: 308 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ORI(ORI { address: 2147484060, operands: FormatI { rd: 12, rs1: 11, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484064, operands: FormatVirtualRightShiftI { rd: 11, rs1: 8, imm: 18446739675663040512 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484068, operands: FormatI { rd: 13, rs1: 9, imm: 4194304 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484072, operands: FormatR { rd: 11, rs1: 11, rs2: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualSRLI(VirtualSRLI { address: 2147484074, operands: FormatVirtualRightShiftI { rd: 13, rs1: 9, imm: 18446739675663040512 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484078, operands: FormatR { rd: 13, rs1: 13, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484080, operands: FormatI { rd: 32, rs1: 2, imm: 17 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484080, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484080, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484080, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484080, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484080, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484080, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484080, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484080, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484080, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484080, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484080, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484080, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484084, operands: FormatI { rd: 32, rs1: 2, imm: 18 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484084, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484084, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484084, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484084, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484084, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484084, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484084, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484084, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484084, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484084, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484084, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484084, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484088, operands: FormatB { rs1: 13, rs2: 0, imm: 280 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ORI(ORI { address: 2147484092, operands: FormatI { rd: 12, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484096, operands: FormatVirtualRightShiftI { rd: 10, rs1: 8, imm: 18446181123756130304 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484100, operands: FormatI { rd: 13, rs1: 9, imm: 32768 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484104, operands: FormatR { rd: 10, rs1: 10, rs2: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualSRLI(VirtualSRLI { address: 2147484106, operands: FormatVirtualRightShiftI { rd: 13, rs1: 9, imm: 18446181123756130304 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484110, operands: FormatR { rd: 13, rs1: 13, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484112, operands: FormatI { rd: 32, rs1: 2, imm: 18 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484112, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484112, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484112, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484112, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484112, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484112, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484112, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484112, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484112, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484112, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484112, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484112, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484116, operands: FormatI { rd: 32, rs1: 2, imm: 19 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484116, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484116, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484116, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484116, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484116, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484116, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484116, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484116, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484116, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484116, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484116, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484116, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484120, operands: FormatB { rs1: 0, rs2: 13, imm: 252 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484122, operands: FormatI { rd: 12, rs1: 11, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484126, operands: FormatVirtualRightShiftI { rd: 11, rs1: 8, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484130, operands: FormatI { rd: 13, rs1: 9, imm: 256 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484134, operands: FormatR { rd: 11, rs1: 11, rs2: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualSRLI(VirtualSRLI { address: 2147484136, operands: FormatVirtualRightShiftI { rd: 13, rs1: 9, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484140, operands: FormatR { rd: 13, rs1: 13, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484142, operands: FormatI { rd: 32, rs1: 2, imm: 19 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484142, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484142, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484142, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484142, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484142, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484142, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484142, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484142, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484142, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484142, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484142, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484142, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484146, operands: FormatI { rd: 32, rs1: 2, imm: 20 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484146, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484146, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484146, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484146, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484146, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484146, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484146, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484146, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484146, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484146, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484146, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484146, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484150, operands: FormatB { rs1: 0, rs2: 13, imm: 226 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484152, operands: FormatI { rd: 12, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484156, operands: FormatVirtualRightShiftI { rd: 8, rs1: 8, imm: 9223372036854775808 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: true })
VirtualMULI(VirtualMULI { address: 2147484158, operands: FormatI { rd: 10, rs1: 9, imm: 2 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484162, operands: FormatR { rd: 10, rs1: 10, rs2: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualSRLI(VirtualSRLI { address: 2147484164, operands: FormatVirtualRightShiftI { rd: 13, rs1: 9, imm: 9223372036854775808 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147484168, operands: FormatR { rd: 13, rs1: 13, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484170, operands: FormatI { rd: 32, rs1: 2, imm: 20 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484170, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484170, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484170, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484170, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484170, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484170, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484170, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484170, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484170, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484170, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484170, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484170, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484174, operands: FormatI { rd: 32, rs1: 2, imm: 21 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484174, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484174, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484174, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484174, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484174, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484174, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484174, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484174, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484174, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484174, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484174, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484174, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484178, operands: FormatB { rs1: 0, rs2: 13, imm: 202 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484180, operands: FormatI { rd: 12, rs1: 11, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484184, operands: FormatVirtualRightShiftI { rd: 11, rs1: 9, imm: 18446744073709551552 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484188, operands: FormatI { rd: 32, rs1: 2, imm: 21 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484188, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484188, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484188, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484188, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484188, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484188, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484188, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484188, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484188, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484188, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484188, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484188, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484192, operands: FormatI { rd: 32, rs1: 2, imm: 22 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484192, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484192, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484192, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484192, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484192, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484192, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484192, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484192, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484192, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484192, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484192, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484192, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484196, operands: FormatB { rs1: 0, rs2: 11, imm: 188 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484198, operands: FormatI { rd: 12, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484202, operands: FormatVirtualRightShiftI { rd: 10, rs1: 9, imm: 18446744073709543424 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484206, operands: FormatI { rd: 32, rs1: 2, imm: 22 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484206, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484206, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484206, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484206, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484206, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484206, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484206, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484206, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484206, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484206, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484206, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484206, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484210, operands: FormatI { rd: 32, rs1: 2, imm: 23 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484210, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484210, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484210, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484210, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484210, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484210, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484210, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484210, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484210, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484210, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484210, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484210, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484214, operands: FormatB { rs1: 0, rs2: 10, imm: 174 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484216, operands: FormatI { rd: 12, rs1: 11, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484220, operands: FormatVirtualRightShiftI { rd: 11, rs1: 9, imm: 18446744073708503040 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484224, operands: FormatI { rd: 32, rs1: 2, imm: 23 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484224, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484224, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484224, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484224, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484224, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484224, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484224, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484224, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484224, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484224, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484224, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484224, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484228, operands: FormatI { rd: 32, rs1: 2, imm: 24 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484228, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484228, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484228, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484228, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484228, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484228, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484228, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484228, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484228, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484228, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484228, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484228, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484232, operands: FormatB { rs1: 0, rs2: 11, imm: 160 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484234, operands: FormatI { rd: 12, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484238, operands: FormatVirtualRightShiftI { rd: 10, rs1: 9, imm: 18446744073575333888 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484242, operands: FormatI { rd: 32, rs1: 2, imm: 24 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484242, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484242, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484242, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484242, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484242, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484242, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484242, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484242, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484242, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484242, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484242, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484242, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484246, operands: FormatI { rd: 32, rs1: 2, imm: 25 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484246, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484246, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484246, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484246, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484246, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484246, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484246, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484246, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484246, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484246, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484246, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484246, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484250, operands: FormatB { rs1: 0, rs2: 10, imm: 146 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484252, operands: FormatI { rd: 12, rs1: 11, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484256, operands: FormatVirtualRightShiftI { rd: 11, rs1: 9, imm: 18446744056529682432 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484260, operands: FormatI { rd: 32, rs1: 2, imm: 25 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484260, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484260, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484260, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484260, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484260, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484260, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484260, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484260, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484260, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484260, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484260, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484260, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484264, operands: FormatI { rd: 32, rs1: 2, imm: 26 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484264, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484264, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484264, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484264, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484264, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484264, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484264, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484264, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484264, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484264, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484264, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484264, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484268, operands: FormatB { rs1: 0, rs2: 11, imm: 132 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484270, operands: FormatI { rd: 12, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484274, operands: FormatVirtualRightShiftI { rd: 10, rs1: 9, imm: 18446741874686296064 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484278, operands: FormatI { rd: 32, rs1: 2, imm: 26 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484278, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484278, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484278, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484278, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484278, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484278, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484278, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484278, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484278, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484278, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484278, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484278, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484282, operands: FormatI { rd: 32, rs1: 2, imm: 27 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484282, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484282, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484282, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484282, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484282, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484282, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484282, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484282, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484282, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484282, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484282, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484282, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484286, operands: FormatB { rs1: 0, rs2: 10, imm: 118 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484288, operands: FormatI { rd: 12, rs1: 11, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484292, operands: FormatVirtualRightShiftI { rd: 11, rs1: 9, imm: 18446462598732840960 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484296, operands: FormatI { rd: 32, rs1: 2, imm: 27 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484296, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484296, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484296, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484296, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484296, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484296, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484296, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484296, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484296, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484296, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484296, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484296, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484300, operands: FormatI { rd: 32, rs1: 2, imm: 28 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484300, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484300, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484300, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484300, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484300, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484300, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484300, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484300, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484300, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484300, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484300, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484300, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484304, operands: FormatB { rs1: 0, rs2: 11, imm: 104 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484306, operands: FormatI { rd: 12, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484310, operands: FormatVirtualRightShiftI { rd: 10, rs1: 9, imm: 18410715276690587648 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484314, operands: FormatI { rd: 32, rs1: 2, imm: 28 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484314, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484314, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484314, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484314, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484314, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484314, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484314, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484314, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484314, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484314, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484314, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484314, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484318, operands: FormatI { rd: 32, rs1: 2, imm: 29 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484318, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484318, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484318, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484318, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484318, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484318, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484318, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484318, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484318, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484318, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484318, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484318, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484322, operands: FormatB { rs1: 0, rs2: 10, imm: 90 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484324, operands: FormatI { rd: 11, rs1: 11, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484328, operands: FormatVirtualRightShiftI { rd: 9, rs1: 9, imm: 13835058055282163712 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: true })
ADDI(ADDI { address: 2147484330, operands: FormatI { rd: 32, rs1: 2, imm: 29 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484330, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484330, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484330, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484330, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484330, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484330, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484330, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484330, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484330, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484330, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484330, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484330, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484334, operands: FormatI { rd: 32, rs1: 2, imm: 30 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484334, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484334, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484334, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484334, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484334, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484334, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484334, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484334, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484334, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484334, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484334, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484334, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484338, operands: FormatB { rs1: 0, rs2: 9, imm: 78 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ORI(ORI { address: 2147484340, operands: FormatI { rd: 10, rs1: 10, imm: 128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484344, operands: FormatI { rd: 32, rs1: 2, imm: 30 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484344, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484344, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484344, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484344, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484344, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484344, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484344, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484344, operands: FormatR { rd: 37, rs1: 10, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484344, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484344, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484344, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484344, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484348, operands: FormatI { rd: 32, rs1: 2, imm: 31 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484348, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484348, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484348, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484348, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484348, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484348, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484348, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484348, operands: FormatR { rd: 37, rs1: 9, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484348, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484348, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484348, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484348, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484352, operands: FormatI { rd: 18, rs1: 0, imm: 19 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484354, operands: FormatJ { rd: 0, imm: 64 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484356, operands: FormatI { rd: 18, rs1: 0, imm: 3 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484358, operands: FormatJ { rd: 0, imm: 60 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484360, operands: FormatI { rd: 18, rs1: 0, imm: 4 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484362, operands: FormatJ { rd: 0, imm: 56 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484364, operands: FormatI { rd: 18, rs1: 0, imm: 5 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484366, operands: FormatJ { rd: 0, imm: 52 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484368, operands: FormatI { rd: 18, rs1: 0, imm: 6 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484370, operands: FormatJ { rd: 0, imm: 48 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484372, operands: FormatI { rd: 18, rs1: 0, imm: 7 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484374, operands: FormatJ { rd: 0, imm: 44 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484376, operands: FormatI { rd: 18, rs1: 0, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484378, operands: FormatJ { rd: 0, imm: 40 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484380, operands: FormatI { rd: 18, rs1: 0, imm: 9 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484382, operands: FormatJ { rd: 0, imm: 36 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484384, operands: FormatI { rd: 18, rs1: 0, imm: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484386, operands: FormatJ { rd: 0, imm: 32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484388, operands: FormatI { rd: 18, rs1: 0, imm: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484390, operands: FormatJ { rd: 0, imm: 28 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484392, operands: FormatI { rd: 18, rs1: 0, imm: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484394, operands: FormatJ { rd: 0, imm: 24 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484396, operands: FormatI { rd: 18, rs1: 0, imm: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484398, operands: FormatJ { rd: 0, imm: 20 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484400, operands: FormatI { rd: 18, rs1: 0, imm: 14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484402, operands: FormatJ { rd: 0, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484404, operands: FormatI { rd: 18, rs1: 0, imm: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484406, operands: FormatJ { rd: 0, imm: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484408, operands: FormatI { rd: 18, rs1: 0, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484410, operands: FormatJ { rd: 0, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484412, operands: FormatI { rd: 18, rs1: 0, imm: 17 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484414, operands: FormatJ { rd: 0, imm: 4 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484416, operands: FormatI { rd: 18, rs1: 0, imm: 18 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LUI(LUI { address: 2147484418, operands: FormatU { rd: 10, imm: 2147463168 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484422, operands: FormatI { rd: 11, rs1: 2, imm: 13 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484426, operands: FormatR { rd: 12, rs1: 0, rs2: 18 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
AUIPC(AUIPC { address: 2147484428, operands: FormatU { rd: 1, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JALR(JALR { address: 2147484432, operands: FormatI { rd: 1, rs1: 1, imm: 38 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484436, operands: FormatU { rd: 10, imm: 2147467264 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484440, operands: FormatI { rd: 11, rs1: 0, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484442, operands: FormatI { rd: 32, rs1: 10, imm: 8 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484442, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484442, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484442, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484442, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484442, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484442, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484442, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484442, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484442, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484442, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484442, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484442, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484446, operands: FormatLoad { rd: 1, rs1: 2, imm: 56 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484448, operands: FormatLoad { rd: 8, rs1: 2, imm: 48 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484450, operands: FormatLoad { rd: 9, rs1: 2, imm: 40 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484452, operands: FormatLoad { rd: 18, rs1: 2, imm: 32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484454, operands: FormatI { rd: 2, rs1: 2, imm: 64 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JALR(JALR { address: 2147484456, operands: FormatI { rd: 0, rs1: 1, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
AUIPC(AUIPC { address: 2147484458, operands: FormatU { rd: 1, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JALR(JALR { address: 2147484462, operands: FormatI { rd: 1, rs1: 1, imm: 18446744073709550844 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484466, operands: FormatI { rd: 2, rs1: 2, imm: 18446744073709551600 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484468, operands: FormatS { rs1: 2, rs2: 1, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484470, operands: FormatS { rs1: 2, rs2: 8, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484472, operands: FormatI { rd: 8, rs1: 2, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484474, operands: FormatLoad { rd: 1, rs1: 2, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484476, operands: FormatLoad { rd: 8, rs1: 2, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484478, operands: FormatI { rd: 2, rs1: 2, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
AUIPC(AUIPC { address: 2147484480, operands: FormatU { rd: 6, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JALR(JALR { address: 2147484484, operands: FormatI { rd: 0, rs1: 6, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484488, operands: FormatI { rd: 2, rs1: 2, imm: 18446744073709551584 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484490, operands: FormatS { rs1: 2, rs2: 1, imm: 24 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484492, operands: FormatS { rs1: 2, rs2: 8, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484494, operands: FormatS { rs1: 2, rs2: 9, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484496, operands: FormatI { rd: 8, rs1: 2, imm: 32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484498, operands: FormatI { rd: 13, rs1: 0, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BLTU(BLTU { address: 2147484500, operands: FormatB { rs1: 12, rs2: 13, imm: 100 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
SUB(SUB { address: 2147484504, operands: FormatR { rd: 13, rs1: 0, rs2: 10 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147484504, operands: FormatI { rd: 13, rs1: 13, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484508, operands: FormatI { rd: 16, rs1: 13, imm: 7 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484512, operands: FormatR { rd: 31, rs1: 10, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGEU(BGEU { address: 2147484516, operands: FormatB { rs1: 10, rs2: 31, imm: 26 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484520, operands: FormatR { rd: 14, rs1: 0, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484522, operands: FormatR { rd: 13, rs1: 0, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484524, operands: FormatR { rd: 15, rs1: 0, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484526, operands: FormatI { rd: 32, rs1: 15, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484526, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484526, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147484526, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484526, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484526, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484526, operands: FormatR { rd: 17, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484526, operands: FormatVirtualRightShiftI { rd: 17, rs1: 17, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484530, operands: FormatI { rd: 14, rs1: 14, imm: 18446744073709551615 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484532, operands: FormatI { rd: 32, rs1: 13, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484532, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484532, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484532, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484532, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484532, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484532, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484532, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484532, operands: FormatR { rd: 37, rs1: 17, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484532, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484532, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484532, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484532, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484536, operands: FormatI { rd: 13, rs1: 13, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484538, operands: FormatI { rd: 15, rs1: 15, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BNE(BNE { address: 2147484540, operands: FormatB { rs1: 0, rs2: 14, imm: -14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484542, operands: FormatR { rd: 11, rs1: 11, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SUB(SUB { address: 2147484544, operands: FormatR { rd: 9, rs1: 12, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484548, operands: FormatI { rd: 14, rs1: 9, imm: 18446744073709551608 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484552, operands: FormatI { rd: 16, rs1: 11, imm: 7 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484556, operands: FormatR { rd: 13, rs1: 31, rs2: 14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BNE(BNE { address: 2147484560, operands: FormatB { rs1: 16, rs2: 0, imm: 76 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGEU(BGEU { address: 2147484564, operands: FormatB { rs1: 31, rs2: 13, imm: 20 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484568, operands: FormatR { rd: 15, rs1: 0, rs2: 11 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484570, operands: FormatLoad { rd: 12, rs1: 15, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484572, operands: FormatS { rs1: 31, rs2: 12, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484576, operands: FormatI { rd: 31, rs1: 31, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484578, operands: FormatI { rd: 15, rs1: 15, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BLTU(BLTU { address: 2147484580, operands: FormatB { rs1: 31, rs2: 13, imm: -10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484584, operands: FormatR { rd: 11, rs1: 11, rs2: 14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484586, operands: FormatI { rd: 12, rs1: 9, imm: 7 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484590, operands: FormatR { rd: 14, rs1: 13, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BLTU(BLTU { address: 2147484594, operands: FormatB { rs1: 13, rs2: 14, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JAL(JAL { address: 2147484598, operands: FormatJ { rd: 0, imm: 28 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484600, operands: FormatR { rd: 13, rs1: 0, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484602, operands: FormatR { rd: 14, rs1: 10, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGEU(BGEU { address: 2147484606, operands: FormatB { rs1: 10, rs2: 14, imm: 20 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484610, operands: FormatI { rd: 32, rs1: 11, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484610, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484610, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147484610, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484610, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484610, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484610, operands: FormatR { rd: 14, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484610, operands: FormatVirtualRightShiftI { rd: 14, rs1: 14, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484614, operands: FormatI { rd: 12, rs1: 12, imm: 18446744073709551615 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484616, operands: FormatI { rd: 32, rs1: 13, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484616, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484616, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484616, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484616, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484616, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484616, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484616, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484616, operands: FormatR { rd: 37, rs1: 14, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484616, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484616, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484616, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484616, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484620, operands: FormatI { rd: 13, rs1: 13, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484622, operands: FormatI { rd: 11, rs1: 11, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BNE(BNE { address: 2147484624, operands: FormatB { rs1: 0, rs2: 12, imm: -14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484626, operands: FormatLoad { rd: 1, rs1: 2, imm: 24 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484628, operands: FormatLoad { rd: 8, rs1: 2, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484630, operands: FormatLoad { rd: 9, rs1: 2, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484632, operands: FormatI { rd: 2, rs1: 2, imm: 32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JALR(JALR { address: 2147484634, operands: FormatI { rd: 0, rs1: 1, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484636, operands: FormatI { rd: 17, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484638, operands: FormatI { rd: 12, rs1: 0, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484640, operands: FormatS { rs1: 8, rs2: 0, imm: -32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
SUB(SUB { address: 2147484644, operands: FormatR { rd: 6, rs1: 12, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484648, operands: FormatI { rd: 12, rs1: 8, imm: 18446744073709551584 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484652, operands: FormatI { rd: 15, rs1: 6, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
OR(OR { address: 2147484656, operands: FormatR { rd: 5, rs1: 12, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BNE(BNE { address: 2147484660, operands: FormatB { rs1: 0, rs2: 15, imm: 84 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484662, operands: FormatI { rd: 12, rs1: 6, imm: 2 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BNE(BNE { address: 2147484666, operands: FormatB { rs1: 0, rs2: 12, imm: 94 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484668, operands: FormatI { rd: 12, rs1: 6, imm: 4 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BNE(BNE { address: 2147484672, operands: FormatB { rs1: 0, rs2: 12, imm: 112 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147484674, operands: FormatLoad { rd: 29, rs1: 8, imm: -32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484678, operands: FormatI { rd: 17, rs1: 16, imm: 8 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484682, operands: FormatI { rd: 12, rs1: 31, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
SUB(SUB { address: 2147484686, operands: FormatR { rd: 30, rs1: 11, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGEU(BGEU { address: 2147484690, operands: FormatB { rs1: 12, rs2: 13, imm: 126 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
SUB(SUB { address: 2147484694, operands: FormatR { rd: 12, rs1: 0, rs2: 17 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147484694, operands: FormatI { rd: 12, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484698, operands: FormatI { rd: 7, rs1: 12, imm: 56 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484702, operands: FormatLoad { rd: 5, rs1: 30, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484706, operands: FormatI { rd: 28, rs1: 30, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualShiftRightBitmask(VirtualShiftRightBitmask { address: 2147484710, operands: FormatI { rd: 32, rs1: 17, imm: 0 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSRL(VirtualSRL { address: 2147484710, operands: FormatVirtualRightShiftR { rd: 12, rs1: 29, rs2: 32 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484714, operands: FormatI { rd: 6, rs1: 31, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484718, operands: FormatI { rd: 32, rs1: 7, imm: 0 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
MUL(MUL { address: 2147484718, operands: FormatR { rd: 15, rs1: 5, rs2: 32 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
OR(OR { address: 2147484722, operands: FormatR { rd: 12, rs1: 12, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484724, operands: FormatI { rd: 15, rs1: 31, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484728, operands: FormatS { rs1: 31, rs2: 12, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484732, operands: FormatR { rd: 31, rs1: 0, rs2: 6 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484734, operands: FormatR { rd: 30, rs1: 0, rs2: 28 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484736, operands: FormatR { rd: 29, rs1: 0, rs2: 5 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BLTU(BLTU { address: 2147484738, operands: FormatB { rs1: 15, rs2: 13, imm: -36 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JAL(JAL { address: 2147484742, operands: FormatJ { rd: 0, imm: 80 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484744, operands: FormatI { rd: 32, rs1: 11, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484744, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484744, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147484744, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484744, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484744, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484744, operands: FormatR { rd: 12, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484744, operands: FormatVirtualRightShiftI { rd: 12, rs1: 12, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484748, operands: FormatI { rd: 32, rs1: 5, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484748, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484748, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484748, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484748, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484748, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484748, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484748, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484748, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484748, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484748, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484748, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484748, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484752, operands: FormatI { rd: 17, rs1: 0, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484754, operands: FormatI { rd: 12, rs1: 6, imm: 2 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484758, operands: FormatB { rs1: 0, rs2: 12, imm: -90 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484760, operands: FormatR { rd: 12, rs1: 11, rs2: 17 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualAssertHalfwordAlignment(VirtualAssertHalfwordAlignment { address: 2147484764, operands: AssertAlignFormat { rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484764, operands: FormatI { rd: 32, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484764, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484764, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147484764, operands: FormatI { rd: 35, rs1: 32, imm: 6 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484764, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484764, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484764, operands: FormatR { rd: 12, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRAI(VirtualSRAI { address: 2147484764, operands: FormatVirtualRightShiftI { rd: 12, rs1: 12, imm: 18446462598732840960 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484768, operands: FormatR { rd: 15, rs1: 5, rs2: 17 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualAssertHalfwordAlignment(VirtualAssertHalfwordAlignment { address: 2147484772, operands: AssertAlignFormat { rs1: 15, imm: 0 }, virtual_sequence_remaining: Some(13), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484772, operands: FormatI { rd: 32, rs1: 15, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484772, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484772, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484772, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484772, operands: FormatU { rd: 36, imm: 65535 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484772, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484772, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484772, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484772, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484772, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484772, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484772, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484772, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484776, operands: FormatI { rd: 17, rs1: 17, imm: 2 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484778, operands: FormatI { rd: 12, rs1: 6, imm: 4 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484782, operands: FormatB { rs1: 0, rs2: 12, imm: -108 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484784, operands: FormatR { rd: 12, rs1: 11, rs2: 17 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualAssertWordAlignment(VirtualAssertWordAlignment { address: 2147484788, operands: AssertAlignFormat { rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484788, operands: FormatI { rd: 32, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484788, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484788, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484788, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualShiftRightBitmask(VirtualShiftRightBitmask { address: 2147484788, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
VirtualSRL(VirtualSRL { address: 2147484788, operands: FormatVirtualRightShiftR { rd: 12, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147484788, operands: FormatI { rd: 12, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484790, operands: FormatR { rd: 17, rs1: 17, rs2: 5 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualAssertWordAlignment(VirtualAssertWordAlignment { address: 2147484792, operands: AssertAlignFormat { rs1: 17, imm: 0 }, virtual_sequence_remaining: Some(14), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484792, operands: FormatI { rd: 32, rs1: 17, imm: 0 }, virtual_sequence_remaining: Some(13), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484792, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484792, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484792, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
ORI(ORI { address: 2147484792, operands: FormatI { rd: 36, rs1: 0, imm: 18446744073709551615 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484792, operands: FormatVirtualRightShiftI { rd: 36, rs1: 36, imm: 18446744069414584320 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484792, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484792, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484792, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484792, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484792, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484792, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484792, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484792, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484796, operands: FormatLoad { rd: 29, rs1: 8, imm: -32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484800, operands: FormatI { rd: 17, rs1: 16, imm: 8 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484804, operands: FormatI { rd: 12, rs1: 31, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
SUB(SUB { address: 2147484808, operands: FormatR { rd: 30, rs1: 11, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BLTU(BLTU { address: 2147484812, operands: FormatB { rs1: 12, rs2: 13, imm: -118 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484816, operands: FormatR { rd: 5, rs1: 0, rs2: 29 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484818, operands: FormatR { rd: 28, rs1: 0, rs2: 30 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484820, operands: FormatR { rd: 6, rs1: 0, rs2: 31 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484822, operands: FormatI { rd: 15, rs1: 0, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484824, operands: FormatI { rd: 7, rs1: 28, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484828, operands: FormatI { rd: 12, rs1: 0, imm: 4 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484830, operands: FormatS { rs1: 8, rs2: 0, imm: -32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGEU(BGEU { address: 2147484834, operands: FormatB { rs1: 16, rs2: 12, imm: 74 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484838, operands: FormatI { rd: 12, rs1: 11, imm: 2 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BNE(BNE { address: 2147484842, operands: FormatB { rs1: 0, rs2: 12, imm: 82 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484844, operands: FormatI { rd: 12, rs1: 11, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484848, operands: FormatB { rs1: 0, rs2: 12, imm: 18 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484850, operands: FormatR { rd: 7, rs1: 7, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484852, operands: FormatI { rd: 32, rs1: 7, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484852, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484852, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147484852, operands: FormatI { rd: 35, rs1: 32, imm: 7 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484852, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484852, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484852, operands: FormatR { rd: 16, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484852, operands: FormatVirtualRightShiftI { rd: 16, rs1: 16, imm: 18374686479671623680 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484856, operands: FormatI { rd: 12, rs1: 8, imm: 18446744073709551584 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
OR(OR { address: 2147484860, operands: FormatR { rd: 12, rs1: 12, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484862, operands: FormatI { rd: 32, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484862, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484862, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484862, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484862, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484862, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484862, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484862, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484862, operands: FormatR { rd: 37, rs1: 16, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484862, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484862, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484862, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484862, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484866, operands: FormatLoad { rd: 16, rs1: 8, imm: -32 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualShiftRightBitmask(VirtualShiftRightBitmask { address: 2147484870, operands: FormatI { rd: 32, rs1: 17, imm: 0 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSRL(VirtualSRL { address: 2147484870, operands: FormatVirtualRightShiftR { rd: 15, rs1: 5, rs2: 32 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
SUB(SUB { address: 2147484874, operands: FormatR { rd: 12, rs1: 0, rs2: 17 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147484874, operands: FormatI { rd: 12, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484878, operands: FormatI { rd: 12, rs1: 12, imm: 56 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484882, operands: FormatI { rd: 32, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
MUL(MUL { address: 2147484882, operands: FormatR { rd: 12, rs1: 16, rs2: 32 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
OR(OR { address: 2147484886, operands: FormatR { rd: 12, rs1: 12, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484888, operands: FormatS { rs1: 6, rs2: 12, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484892, operands: FormatR { rd: 11, rs1: 11, rs2: 14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484894, operands: FormatI { rd: 12, rs1: 9, imm: 7 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484898, operands: FormatR { rd: 14, rs1: 13, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BLTU(BLTU { address: 2147484902, operands: FormatB { rs1: 13, rs2: 14, imm: -292 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JAL(JAL { address: 2147484906, operands: FormatJ { rd: 0, imm: 18446744073709551336 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualAssertWordAlignment(VirtualAssertWordAlignment { address: 2147484908, operands: AssertAlignFormat { rs1: 7, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484908, operands: FormatI { rd: 32, rs1: 7, imm: 0 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484908, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484908, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484908, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualShiftRightBitmask(VirtualShiftRightBitmask { address: 2147484908, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
VirtualSRL(VirtualSRL { address: 2147484908, operands: FormatVirtualRightShiftR { rd: 12, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147484908, operands: FormatI { rd: 12, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
VirtualAssertWordAlignment(VirtualAssertWordAlignment { address: 2147484912, operands: AssertAlignFormat { rs1: 8, imm: -32 }, virtual_sequence_remaining: Some(14), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484912, operands: FormatI { rd: 32, rs1: 8, imm: 18446744073709551584 }, virtual_sequence_remaining: Some(13), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484912, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484912, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484912, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
ORI(ORI { address: 2147484912, operands: FormatI { rd: 36, rs1: 0, imm: 18446744073709551615 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
VirtualSRLI(VirtualSRLI { address: 2147484912, operands: FormatVirtualRightShiftI { rd: 36, rs1: 36, imm: 18446744069414584320 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484912, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484912, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484912, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484912, operands: FormatR { rd: 37, rs1: 12, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484912, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484912, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484912, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484912, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484916, operands: FormatI { rd: 15, rs1: 0, imm: 4 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484918, operands: FormatI { rd: 12, rs1: 11, imm: 2 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BEQ(BEQ { address: 2147484922, operands: FormatB { rs1: 0, rs2: 12, imm: -78 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484924, operands: FormatR { rd: 12, rs1: 7, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualAssertHalfwordAlignment(VirtualAssertHalfwordAlignment { address: 2147484928, operands: AssertAlignFormat { rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484928, operands: FormatI { rd: 32, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484928, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484928, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
XORI(XORI { address: 2147484928, operands: FormatI { rd: 35, rs1: 32, imm: 6 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484928, operands: FormatI { rd: 35, rs1: 35, imm: 8 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484928, operands: FormatI { rd: 36, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484928, operands: FormatR { rd: 16, rs1: 34, rs2: 36 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
VirtualSRAI(VirtualSRAI { address: 2147484928, operands: FormatVirtualRightShiftI { rd: 16, rs1: 16, imm: 18446462598732840960 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484932, operands: FormatI { rd: 12, rs1: 8, imm: 18446744073709551584 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
OR(OR { address: 2147484936, operands: FormatR { rd: 12, rs1: 12, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
VirtualAssertHalfwordAlignment(VirtualAssertHalfwordAlignment { address: 2147484938, operands: AssertAlignFormat { rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(13), is_first_in_sequence: true, is_compressed: false })
ADDI(ADDI { address: 2147484938, operands: FormatI { rd: 32, rs1: 12, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484938, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484938, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484938, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484938, operands: FormatU { rd: 36, imm: 65535 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484938, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484938, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484938, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484938, operands: FormatR { rd: 37, rs1: 16, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484938, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484938, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484938, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484938, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484942, operands: FormatI { rd: 15, rs1: 15, imm: 2 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ANDI(ANDI { address: 2147484944, operands: FormatI { rd: 12, rs1: 11, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BNE(BNE { address: 2147484948, operands: FormatB { rs1: 0, rs2: 12, imm: -98 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JAL(JAL { address: 2147484950, operands: FormatJ { rd: 0, imm: 18446744073709551532 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484952, operands: FormatI { rd: 2, rs1: 2, imm: 18446744073709551600 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484954, operands: FormatS { rs1: 2, rs2: 1, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SD(SD { address: 2147484956, operands: FormatS { rs1: 2, rs2: 8, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484958, operands: FormatI { rd: 8, rs1: 2, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484960, operands: FormatI { rd: 13, rs1: 0, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BLTU(BLTU { address: 2147484962, operands: FormatB { rs1: 12, rs2: 13, imm: 110 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
SUB(SUB { address: 2147484966, operands: FormatR { rd: 13, rs1: 0, rs2: 10 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: true, is_compressed: false })
VirtualSignExtendWord(VirtualSignExtendWord { address: 2147484966, operands: FormatI { rd: 13, rs1: 13, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147484970, operands: FormatI { rd: 16, rs1: 13, imm: 7 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484974, operands: FormatR { rd: 14, rs1: 10, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGEU(BGEU { address: 2147484978, operands: FormatB { rs1: 10, rs2: 14, imm: 18 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147484982, operands: FormatR { rd: 15, rs1: 0, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147484984, operands: FormatR { rd: 13, rs1: 0, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484986, operands: FormatI { rd: 32, rs1: 13, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147484986, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147484986, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147484986, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147484986, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484986, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484986, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147484986, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147484986, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484986, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147484986, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147484986, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147484986, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147484990, operands: FormatI { rd: 15, rs1: 15, imm: 18446744073709551615 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147484992, operands: FormatI { rd: 13, rs1: 13, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BNE(BNE { address: 2147484994, operands: FormatB { rs1: 0, rs2: 15, imm: -8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
SUB(SUB { address: 2147484996, operands: FormatR { rd: 12, rs1: 12, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147485000, operands: FormatI { rd: 13, rs1: 12, imm: 18446744073709551608 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADD(ADD { address: 2147485004, operands: FormatR { rd: 13, rs1: 13, rs2: 14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BGEU(BGEU { address: 2147485006, operands: FormatB { rs1: 14, rs2: 13, imm: 38 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147485010, operands: FormatI { rd: 16, rs1: 11, imm: 72057594037927936 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
LUI(LUI { address: 2147485014, operands: FormatU { rd: 15, imm: 269488128 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147485018, operands: FormatI { rd: 15, rs1: 15, imm: 16 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: true })
ADDI(ADDI { address: 2147485020, operands: FormatI { rd: 15, rs1: 15, imm: 256 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
MULHU(MULHU { address: 2147485024, operands: FormatR { rd: 16, rs1: 16, rs2: 15 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147485028, operands: FormatI { rd: 15, rs1: 16, imm: 4294967296 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: true, is_compressed: false })
OR(OR { address: 2147485032, operands: FormatR { rd: 15, rs1: 15, rs2: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147485036, operands: FormatS { rs1: 14, rs2: 15, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147485038, operands: FormatI { rd: 14, rs1: 14, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BLTU(BLTU { address: 2147485040, operands: FormatB { rs1: 14, rs2: 13, imm: -4 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ANDI(ANDI { address: 2147485044, operands: FormatI { rd: 12, rs1: 12, imm: 7 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147485046, operands: FormatR { rd: 14, rs1: 13, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BGEU(BGEU { address: 2147485050, operands: FormatB { rs1: 13, rs2: 14, imm: 14 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147485054, operands: FormatI { rd: 32, rs1: 13, imm: 0 }, virtual_sequence_remaining: Some(12), is_first_in_sequence: true, is_compressed: false })
ANDI(ANDI { address: 2147485054, operands: FormatI { rd: 33, rs1: 32, imm: 18446744073709551608 }, virtual_sequence_remaining: Some(11), is_first_in_sequence: false, is_compressed: false })
LD(LD { address: 2147485054, operands: FormatLoad { rd: 34, rs1: 33, imm: 0 }, virtual_sequence_remaining: Some(10), is_first_in_sequence: false, is_compressed: false })
VirtualMULI(VirtualMULI { address: 2147485054, operands: FormatI { rd: 35, rs1: 32, imm: 8 }, virtual_sequence_remaining: Some(9), is_first_in_sequence: false, is_compressed: false })
LUI(LUI { address: 2147485054, operands: FormatU { rd: 36, imm: 255 }, virtual_sequence_remaining: Some(8), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147485054, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(7), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147485054, operands: FormatR { rd: 36, rs1: 36, rs2: 38 }, virtual_sequence_remaining: Some(6), is_first_in_sequence: false, is_compressed: false })
VirtualPow2(VirtualPow2 { address: 2147485054, operands: FormatI { rd: 38, rs1: 35, imm: 0 }, virtual_sequence_remaining: Some(5), is_first_in_sequence: false, is_compressed: false })
MUL(MUL { address: 2147485054, operands: FormatR { rd: 37, rs1: 11, rs2: 38 }, virtual_sequence_remaining: Some(4), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147485054, operands: FormatR { rd: 37, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(3), is_first_in_sequence: false, is_compressed: false })
AND(AND { address: 2147485054, operands: FormatR { rd: 37, rs1: 37, rs2: 36 }, virtual_sequence_remaining: Some(2), is_first_in_sequence: false, is_compressed: false })
XOR(XOR { address: 2147485054, operands: FormatR { rd: 34, rs1: 34, rs2: 37 }, virtual_sequence_remaining: Some(1), is_first_in_sequence: false, is_compressed: false })
SD(SD { address: 2147485054, operands: FormatS { rs1: 33, rs2: 34, imm: 0 }, virtual_sequence_remaining: Some(0), is_first_in_sequence: false, is_compressed: false })
ADDI(ADDI { address: 2147485058, operands: FormatI { rd: 12, rs1: 12, imm: 18446744073709551615 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147485060, operands: FormatI { rd: 13, rs1: 13, imm: 1 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
BNE(BNE { address: 2147485062, operands: FormatB { rs1: 0, rs2: 12, imm: -8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147485064, operands: FormatLoad { rd: 1, rs1: 2, imm: 8 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
LD(LD { address: 2147485066, operands: FormatLoad { rd: 8, rs1: 2, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADDI(ADDI { address: 2147485068, operands: FormatI { rd: 2, rs1: 2, imm: 16 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
JALR(JALR { address: 2147485070, operands: FormatI { rd: 0, rs1: 1, imm: 0 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147485072, operands: FormatR { rd: 13, rs1: 0, rs2: 10 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
ADD(ADD { address: 2147485074, operands: FormatR { rd: 14, rs1: 10, rs2: 12 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
BLTU(BLTU { address: 2147485078, operands: FormatB { rs1: 10, rs2: 14, imm: -24 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: false })
JAL(JAL { address: 2147485082, operands: FormatJ { rd: 0, imm: 18446744073709551598 }, virtual_sequence_remaining: None, is_first_in_sequence: false, is_compressed: true })
```

### Appendix D: Linker Script

```
OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

MEMORY {
  program (rwx) : ORIGIN = 0x80000000, LENGTH = 0xA00000  /* 10MB of memory (DEFAULT_MEMORY_SIZE) */
}

SECTIONS {
  .text.boot : {
    *(.text.boot)
  } > program

  .text.init : {
    *(.text.init)
  } > program

  .tohost : {
    KEEP(*(.tohost))  /* Needed by RISCOF pass/fail detection */
  } > program

  .text : {
    *(.text)
  } > program

  .data : {
    *(.data)
  } > program

  .data.string : {
    *(.data.string)
  } > program

  .bss : {
    *(.bss)
  } > program

  . = ALIGN(8);
  /* Reserve 4 KiB for stack */
  . = . + 4096;
  _STACK_PTR = .;

  . = ALIGN(8);
  /* Reserve 4 KiB for heap */
  _HEAP_PTR = .;
  _end = .;
}
```



## Footnotes

[^3]: More formally, we mean as correct as the original riscv assembly file.
