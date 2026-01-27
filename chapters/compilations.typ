#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *

// #show raw.where(block: false): set text(font: "PT Mono", fill: red)
#pagebreak()
= Compilation<sec:compilation>


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


In this section we provide full details of the compilation phase of Jolt. 
@fig:compile-1 provides an overview of the logical phases we discuss here. 
// Although the aim is to be formal, and describe process as generally as feasible, we ground our descriptions with the running example from @guest-program.
The entry point to Jolt is the command 

```bash
cargo run --release -p jolt-core profile --name fibonacci
```

which tells Jolt execute and prove program described in @guest-program found at `jolt/examples/fibonacci/guest/src/lib.rs`.

== RISC-V-IMAC 

As decribed before, Jolt only accepts inputs written Jolt assembly. 
So the first step is to compile the program down to an elf file in the `risc-v-imac` format.
We draw the readers attention to the line `self.build(DEFAULT_TARGET_DIR);`found in `jolt/jolt-core/src/host/program.rs`. 
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

where 

```bash
cargo build \
    --release \
    --features guest \
    -p fibonacci-guest \
    --target-dir /tmp/jolt-guest-targets/fibonacci-guest- \
    --target riscv64imac-unknown-none-elf
```

Simply says build the program in package `fibonacci-guest` in the current workspace with the `guest` feature turned on. 
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

The next step is to convert this elf file into a new executable called the `Bytecode` for Jolt-Assembly.
The `Bytecode` will a vector of `Instruction` enums defined in #todo()[TODO enums]
The block of code to focus on can be found in `jolt/jolt-core/src/guest/program.rs` and is described in @fig:bytecode.
Logically this block has two phases. 
In the first phase, we simply translate the native RISCV elf file into an appropriate memory representation. 
In the next phase, we replace some native instructions as a sequence of simpler instructions. 
More details follow.

#figure(
codebox()[
```rust
pub fn decode(elf: &[u8]) -> (Vec<Instruction>, Vec<(u64, u8)>, u64) {

    // Take a stream of bytes which represent the native elf file
    // and store the information in Jolt specific data structures.
    let (mut instructions, raw_bytes, program_end, xlen) = tracer::decode(elf);
    let program_size = program_end - RAM_START_ADDRESS;
    let allocator = VirtualRegisterAllocator::default();

    // Expand virtual sequences
    // Expand complex native instructions into a sequence of many
    // instructions 
    instructions = instructions
        .into_iter()
        .flat_map(|instr| instr.inline_sequence(&allocator, xlen))
        .collect();

    (instructions, raw_bytes, program_size)
}
```
],
caption: []
)<fig:bytecode>
 
We will investigate the above process in great detail next. 
This is important as the second phase where we expand instructions, we might be introducing bugs, and its important for us to formally verify that we are not. 
Thus, a detailed explanation of the above steps is important. 
We first

 
=== RISC-V Instruction

The first object of  study will be the enum `Instruction` which will implement the `RISCVInstruction` trait. 
`Instruction` is simply the enumeration of all the assembly instructions we need to handle -- for us this will be anything specified by the RISC-IMAC architecture and _virtual instructions_ which we have mentioned, but have yet to define.
The `NormalisedInstruction` type can be viewed as an `Instruction` with the formatting#footnote[Risc-v has many formats. #todo()[put link here TODO]] removed. 

```rust

pub trait RISCVInstruction:
    std::fmt::Debug
    + Sized
    + Copy
    + Into<Instruction>
    + From<NormalizedInstruction>
    + Into<NormalizedInstruction>
{
    const MASK: u32;
    const MATCH: u32;

    type Format: InstructionFormat;
    type RAMAccess: Default + Into<RAMAccess> + Copy + std::fmt::Debug;

    fn operands(&self) -> &Self::Format;
    fn new(word: u32, address: u64, validate: bool, compressed: bool) -> Self;
    #[cfg(any(feature = "test-utils", test))]
    fn random(rng: &mut rand::rngs::StdRng) -> Self {
        use rand::RngCore;
        Self::new(rng.next_u32(), rng.next_u64(), false, false)
    }
    fn execute(&self, cpu: &mut Cpu, ram_access: &mut Self::RAMAccess);
}
```

It is relatively simple.  Once it reads 32 bits from the elf file, it needs to decode the assembly instruction. 
To do this it must differentiate between `R` types and `B` type instructions (see worked out example below). 
Then it also stores whether executing the instruction requires any kind of memory access. For example, the `addi` instruction does not require memory access 

```asm
addi    a5,a5,-1
```

but the following load instruction  does. 

```asm 
lbu     a7,0(a5)
```

=== Instruction 

Appendix #todo()[todo] lists all types of Instructions jolt can parse. 
Each enumeration of the `Instruction` enum is then defined using the declarative macro:

```rust
macro_rules! declare_riscv_instr {
    (
      name    = $name:ident,
      mask    = $mask:expr,
      match   = $match_:expr,
      format  = $format:ty,
      ram     = $ram:ty
  ) 
```

This macro rule will create a struct of the form 

```rust
pub struct $name {
    pub address: u64,
    pub operands: $format,
    pub virtual_sequence_remaining: Option<u16>,
    pub is_first_in_sequence: bool,
    /// Set if instruction is C-Type
    pub is_compressed: bool,
}
```

As an example call the `add` instruction is defined as follows:

```rust
declare_riscv_instr!(
    name   = ADD,
    mask   = 0xfe00707f,
    match  = 0x00000033,
    format = FormatR,
    ram    = ()
);
```
so this becomes the following concrete type. 

```rust
pub struct ADD {
    pub address: u64,
    pub operands: FormatR,
    pub virtual_sequence_remaining: Option<u16>,
    pub is_first_in_sequence: bool,
    /// Set if instruction is C-Type
    pub is_compressed: bool,
}

pub struct FormatR {
    pub rd: u8,
    pub rs1: u8,
    pub rs2: u8,
}
```

It also implements the following implemenations 

```rust
impl crate::instruction::RISCVInstruction for ADD {
  const MASK: u32 = 0xfe00707f;
  const MATCH: u32 = 0x00000033;

  type Format = FormatR;
  type RAMAccess = ();

  fn operands(&self) -> &Self::Format {
    &self.operands
  }

  fn new(word: u32, address: u64, validate: bool, compressed: bool) -> Self {
    if validate {
      debug_assert_eq!(
          word & Self::MASK,
          Self::MATCH,
          "word: {:x}, mask: {:x}, word & mask: {:x}, match: {:x}",
          word,
          Self::MASK,
          word & Self::MASK,
          Self::MATCH
          );
    }
    Self {
      address,
        operands: <FormatR as crate::instruction::format::InstructionFormat>::parse(
            word,
            ),
        virtual_sequence_remaining: None,
        is_first_in_sequence: false,
        is_compressed: compressed,
    }
  }

  // Separately defined outside the macro
  fn execute(&self, cpu: &mut crate::emulator::cpu::Cpu, ram: &mut Self::RAMAccess) {
    self.exec(cpu, ram)
  }
}

```


To get a clear picture of our internal representation of an assembly instruction, we work through a complete example. 
Consider an RISC-V instruction specified in `R` format as shown below. 

The `match` field is `0x33` which if expanded to 7 bits is just `0b0110011`.
So this tells use the opcode. 
The mask helps us figure out `func3` and `func7` along with the opt code. 

From the spec:
#figure(
  image("../assets/r-types.png", width: 80%),
  caption: [
  `FormatR` type instructions 
     ],
)

we have 
```bash
opcode = 0110011   (bits 6–0)
funct3 = 000       (bits 14–12)
funct7 = 0000000   (bits 31–25)
```

`rd, rs1, rs2` are variables.

So the mask must cover:
```md 
funct7 (bits 31–25) → 0b1111111 << 25 = 0xFE000000
funct3 (bits 14–12) → 0b111 << 12 = 0x00007000
opcode (bits 6–0) → 0b1111111 = 0x0000007F
```

Add them together we get the mask above 
```rust
0xFE000000 | 0x00007000 | 0x0000007F = 0xFE00707F
```

The full expansion of the `ADD` macro is given in #todo()[TODO:]

= Virtual Expansions

#context bib_state.get()
