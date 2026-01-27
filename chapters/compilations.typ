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
Under the hood -- Jolt does the following: 
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


#codebox()[
```rust
pub fn decode(&mut self) -> (Vec<Instruction>, Vec<(u64, u8)>, u64) {
        self.build(DEFAULT_TARGET_DIR); // Compiles to regular RISC-V
        let elf = self.elf.as_ref().unwrap();
        let mut elf_file =
            File::open(elf).unwrap_or_else(|_| panic!("could not open elf file: {elf:?}"));
        let mut elf_contents = Vec::new();
        // Reads the bytes of regular RISC-V elf file
        elf_file.read_to_end(&mut elf_contents).unwrap(); 
        // See below about Jolt Bytecode
        guest::program::decode(&elf_contents)
    }
```
]




== Jolt Bytecode
Now we want an extended RISC-V binary.

#figure(
oxdraw("
graph LR
     byte[Jolt Bytecode]
     elf -->|Jolt Pre-processing| byte
   ",
 
background: "#f0f8ff",
),
caption: []
)<fig:compile-2>


The block of code responsible for adding virtual instructions can be found in `jolt/jolt-core/src/guest/program.rs`

#codebox()[
```rust
pub fn decode(elf: &[u8]) -> (Vec<Instruction>, Vec<(u64, u8)>, u64) {
    let (mut instructions, raw_bytes, program_end, xlen) = tracer::decode(elf);
    let program_size = program_end - RAM_START_ADDRESS;
    let allocator = VirtualRegisterAllocator::default();

    // Expand virtual sequences
    instructions = instructions
        .into_iter()
        .flat_map(|instr| instr.inline_sequence(&allocator, xlen))
        .collect();

    (instructions, raw_bytes, program_size)
}

```
]

// #block(width: 100%, fill: blue.transparentize(30%),   
//     inset: 8pt,
//     radius: 3pt,
//     // stroke: 1pt
//     )[
//       We start with Rust source code (as shown in @guest-program), and we end with a file in `/path/to/things` full of bytes that a extended RISC-V CPU (or VM pretending to be a RISC-V CPU) can execute.
//       Everything in between is just machinery to make that translation correct -- that we discuss in this section.
//
//       Note that we say extended because, we need to also support the _virtual instructions_ that the base RISC-V ISA does not support.
//     ]
//


#context bib_state.get()
