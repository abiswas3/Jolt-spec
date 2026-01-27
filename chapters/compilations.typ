#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *

// #show raw.where(block: false): set text(font: "PT Mono", fill: red)
#pagebreak()
= Compilation<sec:compilation>
#todo[Put some instructions on clonin, and where to start. ]
In this section we provide full details of the compilation phase of Jolt. 
The entry point to Jolt is the command 

```bash
cargo run --release -p jolt-core profile --name fibonacci
```

which tells Jolt execute and prove the high level fibonacci found at `jolt/examples/fibonacci/guest/src/lib.rs` defined in @guest-program.
The next step is to compile the high level program into an executable.

The block of code responsible for this logical phase can be found in `jolt/jolt-core/src/host/program.rs` at the following funcution.

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

We draw the readers attention to the line `self.build(DEFAULT_TARGET_DIR);` as this is where the bulk of the work happens.
#figure(
oxdraw("
graph LR
     prog[Rust Program]
     elf[Elf File]
     prog -->|Compilation| elf
   ",
 
background: "#f0f8ff",
),
caption: []
)<fig:compile-1>

Under the hood -- Jolt does the following: 

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
== The Jolt Tracer


=== Instructions
=== Cycles 
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
