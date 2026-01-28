#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *

// #show raw.where(block: false): set text(font: "PT Mono", fill: red)
#pagebreak()
= Compilation<sec:compilation>

In this section we provide full details of the compilation phase of Jolt. 
@fig:compile-1 provides an overview of the logical phases we discuss here.
At the end of this stage, we should have an executable stored in memory called the `Bytecode` which fully describes the user program in Jolt assembly.
We will also articulate how we go from RISC-V to Jolt assembly. 

#figure(
oxdraw("
graph LR
     prog[Rust Program]
     elf[RISC-V elf]
     bytecode[Jolt Bytecode]
     prog -->|Compilation| elf
     elf -->|Extend| bytecode
   ",
 
background: "#f0f8ff",
),
caption: []
)<fig:compile-1>


== RISC-V-IMAC 

The entry point for the user the following command

```bash
cargo run --release -p jolt-core profile --name fibonacci
```

which tells Jolt execute the program described in @guest-program found at `jolt/examples/fibonacci/guest/src/lib.rs` and send me a proof that Jolt correctly executed said program.
As mentioned earlier, Jolt only accepts inputs written Jolt assembly, which is constructed by extending the instruction set with inlines and virtual instructions.
Before we get to virtual instructions, the first step is to compile the program down to an elf file with `risc-v-imac` instructions.
To do this, we draw the readers attention to the line `self.build(DEFAULT_TARGET_DIR);`found in `jolt/jolt-core/src/host/program.rs`. 
Under the hood - Jolt runs the following command

#codebox()[
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
]

The `cargo build...` part says build the program in package `fibonacci-guest` in the current workspace with the `guest` feature turned on. 
Rust (via LLVM) uses the standard target triple format:
```md
<arch>-<vendor>-<sys>-<abi>
```

+ Architecture: `riscv64` says use the base instruction set with 64 bit registers. `imac` says uses the `i`, `m`, `a`, `c` extensions. See #todo()[CITE DETAILS]
+ Vendor: We are not targeting CPU's made by a specific vendor here. 
+ Operating System: All our guest programs are run with `#![no_std]`, so when we say `none` here, we mean the assembly should run on bare-metal or embedded systems.
+ Output format: we choose the `elf` format to output the file and we ask the compiler to put the executable in the following directory `/tmp/jolt-guest-targets/fibonacci-guest-` 

The output of this command is "An ELF executable for RISC-V RV64IMAC: 
Details here: #link("https://docs.rs/target-lexicon/latest/target_lexicon/struct.Triple.html")
We also tell the `rustc` compiler to use our linker script located at `/tmp/jolt-guest-linkers/fibonacci-guest.ld`, which allows to define the memory layout of our assembly code.
The other flags -- tell the compiler that it should simply abort if it encounters a panic, instead of recursively trying to find the source of the error, we do not want debug information or symbols in the final binary, and to perform all optimisations as needed.

#aretefacts()[
1. The actual elf file that gets generated. 
2. The linker script. 
3. The mapper tool that i plan on writing myself. 
]


== Jolt Bytecode


The next step is to convert this elf file into Jolt bytecode.
The bytecode will a vector of `Instruction` enumerations defined in #todo()[TODO enums]
For every instruction defined in the RISCV-IMAC isa, there is a corresponding `Instruction` enumeration.
For example shown below is a partial enumeration for instructions `ADD, ADDI`
```rust
pub enum Instruction {
        /// No-operation instruction (address)
        NoOp,
        UNIMPL,
        ADD(ADD),
        ADDI(ADDI),
        // so on ...
``` 

`Instruction` is the Jolt data structure that represents a RISCV (and virtual) instruction.
This is best illustrated with a concrete example. 
From the specification, there are 6 core instruction formats in which an instruction from the core RISCV instruction set maybe specified, as shown in @fig:spec,

#figure(
  image("../assets/r-types.png", width: 95%),
  caption: [
  `formatr` type instructions 
     ],
)<fig:spec>

#warning()[
Consider the `ADD` instruction at some location in memory. 
It is a single word (32 bits) instruction written in the `R` format.

```asm
add    a5,a5,a4
```
Adds the registers `rs1` (`a5` in our case) and `rs2` (`a4` in our case) and stores the result in `rd` (`a5` in our case). Arithmetic overflow is ignored and the result is simply the low XLEN bits of the result.

This instruction in the Jolt specific data-structure becomes the following concrete enumeration `Instruction::ADD(ADD)` where the enclosed type `ADD` is as follows
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

#todo()[picture]

=== Virtual Instructions 

Nominally, what is going on in this phase is relatively simple. 
We go through the `.text` section of the bytecode, look up the instructions at given memory locations, and store the information in data structures written in rust as shown in the example above.
For every RISCV instruction we store a corresponding Jolt instruction. 
However, we mentioned that the input to the Jolt emulator is not RISCV instructions, but an extended version we call Jolt Assembly or the Jolt Bytecode.
The following block of code is where this extension takes place.

#figure(
codebox()[
```rust
pub fn decode(elf: &[u8]) -> (Vec<Instruction>, Vec<(u64, u8)>, u64) {
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
],
caption: []
)<fig:bytecode>
 
Understanding these extensions are important, as our first formal verification task will involve verifying we apply extensions correctly.
Before formally defining all these expansions, we once again work through a concrete example to aid our understanding.

Consider the `MULH` instruction described in @code:mul-h
#figure(
codebox()[
```asm
mulh rd, rs1, rs2
```
]
,
caption: [The `MULH` instruction which performs an `XLEN`-bit $ times$  `XLEN`-bit multiplication of signed `rs1` by signed `rs2` and places the upper `XLEN` bits in the destination register.
]
)<code:mul-h>

In Jolt assembly we do not have a corresponding `MULH` instruction#footnote()[In the list of enumerations we do have a listing for `MULH`, but in the `fn inline_sequence` method of the implementation, we replace the single occurrence of `MULH` with a sequence of virtual instructions.]. 
Instead, we replace every occurrence of the `MULH` instruction with the following sequence of Jolt assembly instructions. 
We do this to make the life of the prover easier (we will get to that). 

#figure(
codebox()[
```rust
asm.emit_i::<VirtualMovsign>(*v_sx, self.operands.rs1, 0);
asm.emit_i::<VirtualMovsign>(*v_sy, self.operands.rs2, 0);
asm.emit_r::<MULHU>(*v_0, self.operands.rs1, self.operands.rs2);
asm.emit_r::<MUL>(*v_sx, *v_sx, self.operands.rs2);
asm.emit_r::<MUL>(*v_sy, *v_sy, self.operands.rs1);
asm.emit_r::<ADD>(*v_0, *v_0, *v_sx);
asm.emit_r::<ADD>(self.operands.rd, *v_0, *v_sy);
```]
,
caption: []
)<code:v-mulh>

*The Key Thing To Show*: Note that by doing this, we have fundamentally changed the delegated program that user specified.
Assuming we trust the `rustc` compiler, the user input to the program described the `.elf` file which only contained native `RISCV-IMAC` instructions.
Now we have gone, and changed some of these instructions. 
Our claim is that although we have changed the source code, we have not changed the program.
In other words, the program state (memory, registers, flags etc) will be the exact same before and after, whether we executed the original instruction, or the block above.
We will treat the entire block of instructions in @code:v-mulh as a single instruction.
If the machine state is the same before and after execution, as it would be if we had executed the original instruction, we are fine.
*This is our first formal verification task*.
Below we show equivalence with proof written on paper, but eventually we will formalise this idea using the `Lean4` proving assistant.

#theorem[
Define machine state to be the triple of values in registers (`rd, rs1`,`rs2`).
The machine state before and after executing instructions in @code:mul-h and @code:v-mulh is identical.
]<thm2>
#proof[

Define variables $z, x, y$ to denote the values in `rd`, `rs1` and `rs2` respectively.
We are told that $x$ and $y$ have width $w=$`XLEN`=64 bits i.e. $x, y in [-2^(w-1), 2^(w-1)-1]$.
At the end of the `MULH` instruction, we have $z = floor( (x  y)/2^w)$ i.e the higher $w$ bits of the product.

We want to show that after the sequence of virtual instructions, the value in $z$ is the exact same.
We never update $x$ and $y$ so the source registers remain unchanged in both executions.

Define variable $s_x := s(x)$ and $s_y:= s(y)$ where $s: [-2^(w-1), 2^(w-1)-1] -> {0,-1}$ such that 

$ s(Z) := cases(
  0 "if" Z >= 0,
  -1 "otherwise",
) $

Remember $x$ and $y$ just denote the values in `rs1` and `rs2` respectively.
Let $x'$ and $y'$ denote the values in in `rs1` and `rs2` respectively but interpreted as unsigned integers.
That is $x', y' in [0, 2^w -1]$.
It is a well known fact that $x = x' - s_x  2^w$ and $y = y' - s_y  2^w$.
Therefore, 

$
x  y = x' y' + s_x y' 2^w + s_y 2^w x' - s_x s_y 2^(2w) \
$

Dividing and applying the floor operation 

$
floor((x  y)/2^w) = floor((x'  y')/2^w) + s_x y' + s_y x' - s_x s_y 2^(w) \
$
 
Note that as registers are `w` bits in width, we are essentially doing all calculations modulo $2^w$. 
This means that  $s_x s_y 2^(w) equiv 0 mod 2^w$.
Thus, we can safely drop the last term.

$
floor((x  y)/2^w) = floor((x'  y')/2^w) + s_x y' + s_y x' $
 
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

Sets virtual register $v_0$ to $v_0 = floor((x'  y')/2^w)$ 

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

Sets virtual register `v_0` to $floor((x'  y')/2^w) + s_x y'$ 
```rust
asm.emit_r::<ADD>(self.operands.rd, *v_0, *v_sy);
```
Set the value in destination register $z$ to $z=floor((x'  y')/2^w) + s_x y' + s_y x'$  which concludes the proof. 
]

= Remaining 

```bash
> cd tracer/src/instruction/
> rg "fn\s+inline_sequence" --files-with-matches --glob "*.rs" | wc -l
56
```
So there are 55 more instructions need to be virtualised. 
#context bib_state.get()
