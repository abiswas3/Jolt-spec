#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *


#pagebreak()
= Compilation<sec:compilation>


Our starting point was  the command :

`cargo run --release -p jolt-core profile --name fibonacci`

After some command line parsing and instrumentation setup Line 143 in `jolt/jolt-core/src/bin/jolt_core.rs` calls the `bench()` function which eventually leads us to 

```rust 
fn fibonacci() -> Vec<(tracing::Span, Box<dyn FnOnce()>)> {
    prove_example("fibonacci-guest", postcard::to_stdvec(&400000u32).unwrap())
}
```

This `prove_example` #link("https://github.com/abiswas3/jolt/blob/aa8de466125930710ef8fea5d5ea29ec1b501676/jolt-core/benches/e2e_profiling.rs#L46")[sfaf] will be the main object of study in our lecture series. 
Today, we focus on the following code snippet. 

```rust 
    let mut tasks = Vec::new();
    let mut program = host::Program::new(example_name);
    let (bytecode, init_memory_state, _) = program.decode();

```

All `Program::new` does is initialise a `Program` struct with a guest name, and some [defaults](https://github.com/abiswas3/jolt/blob/experiments/advent-of-jolt/common/src/constants.rs). 

```rust
    Self {
            guest: guest.to_string(),
            func: None,
            memory_size: DEFAULT_MEMORY_SIZE,
            stack_size: DEFAULT_STACK_SIZE,
            max_input_size: DEFAULT_MAX_INPUT_SIZE,
            max_untrusted_advice_size: DEFAULT_MAX_UNTRUSTED_ADVICE_SIZE,
            max_trusted_advice_size: DEFAULT_MAX_TRUSTED_ADVICE_SIZE,
            max_output_size: DEFAULT_MAX_OUTPUT_SIZE,
            std: false,
            elf: None,
    }

```

The interesting work happens in the `decode` function

```rust
pub fn decode(&mut self) -> (Vec<Instruction>, Vec<(u64, u8)>, u64) {
        self.build(DEFAULT_TARGET_DIR); // Line 1 : THIS IS WHERE WE COMPILE THE GUEST RUST PROGRAM
        let elf = self.elf.as_ref().unwrap();
        let mut elf_file =
            File::open(elf).unwrap_or_else(|_| panic!("could not open elf file: {elf:?}"));
        let mut elf_contents = Vec::new();
        elf_file.read_to_end(&mut elf_contents).unwrap(); // LINE 2
        guest::program::decode(&elf_contents) // LINE 3
}
```

`LINE 1`: Calls the [following function](https://github.com/abiswas3/jolt/blob/0017138804dc69240b0d4f4aaf4f40dbd4101f4a/jolt-core/src/guest/program.rs#L72) -- which essentially just calls builds and runs the guest program and dumps an elf file in `tmp/jolt-guest-targets/sha3-guest-/riscv64imac-unknown-none-elf/release/fibonacci-guest`. This file is the RISC V Binary in the figure above (not yet disassembled). 

=== The Emulation - Bytecode

`LINE 2`: Does data formatting to structure the elf file to make it suitable for reading, and hands the elf file contents over to `guest::program::decode`

`LINE 3` decodes binary, which again is the most interesting function of this section

```rust
pub fn decode(elf: &[u8]) -> (Vec<Instruction>, Vec<(u64, u8)>, u64) {
    let (mut instructions, raw_bytes, program_end, xlen) = tracer::decode(elf); // <- Heavy Lifiting Done here
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
Roughly here is it what it does : 
**Input:**

- `elf: &[u8]` - Raw bytes of a RISC-V ELF (Executable and Linkable Format) binary

**Output:**

1. `Vec<Instruction>` - Decoded program instructions. [The Instruction](https://github.com/abiswas3/jolt/blob/main/tracer/src/utils/instruction_macros.rs) struct is built using macros. The basic template is linked above. 
In Jolt, `Instruction` is an enum

```rust
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

[^a]: If this does not make a lot of sense immediately, that is fine. We will go over these instructions in detail. 

The remaining things that it returns are the following : 

2. `Vec<(u64, u8)>` - Memory initialization data (address, byte pairs)
3. `u64` - Program end address (highest address used)
4. `Xlen` - Architecture width (32-bit or 64-bit)

Additionally, some instructions like division are broken down into many simpler instructions. 
These instructions are called virtual instructions, and they will read/write to virtual registers. 


=== 2. The Emulation - Trace



Now we focus on the following lines of `prove_example`
```rust
let (trace, _, program_io) = program.trace(&serialized_input, &[], &[]);
```

This gives us trace or what is often denoted with the variable $z$ in [Twist/Shout](https://eprint.iacr.org/2025/105) or the [Jolt](https://eprint.iacr.org/2023/1217) paper. 

The trace function does the following: 

1. Builds the binary if it does not exist. 
2. Once again reads the binary file with the right structure and formatting. 
3. Computes the program size, by decoding the instructions again (NOTE: CODE DUPLICATION here and the Decode function above).
4. We then initialise Jolts representation of RAM via the `MemoryConfig` struct. 
5. Finally we invoke another auxiliary tracer function, which proceeds to call the actual tracer. 

```rust
   #[tracing::instrument(skip_all, name = "Program::trace")]
    pub fn trace(
        &mut self,
        inputs: &[u8],
        untrusted_advice: &[u8],
        trusted_advice: &[u8],
    ) -> (Vec<Cycle>, Memory, JoltDevice) {
        self.build(DEFAULT_TARGET_DIR);
        let elf = self.elf.as_ref().unwrap();
        let mut elf_file =
            File::open(elf).unwrap_or_else(|_| panic!("could not open elf file: {elf:?}"));
        let mut elf_contents = Vec::new();
        elf_file.read_to_end(&mut elf_contents).unwrap();
        let (_, _, program_end, _) = tracer::decode(&elf_contents);
        let program_size = program_end - RAM_START_ADDRESS;

        let memory_config = MemoryConfig {
            memory_size: self.memory_size,
            stack_size: self.stack_size,
            max_input_size: self.max_input_size,
            max_untrusted_advice_size: self.max_untrusted_advice_size,
            max_trusted_advice_size: self.max_trusted_advice_size,
            max_output_size: self.max_output_size,
            program_size: Some(program_size),
        };

        guest::program::trace(
            &elf_contents,
            self.elf.as_ref(),
            inputs,
            untrusted_advice,
            trusted_advice,
            &memory_config,
        )
    }
```

The guest tracer calls another helper which gives us our `trace` and final `memory` state

```rust
let (trace, memory, io_device) = tracer::trace(
        elf_contents,
        elf_path,
        inputs,
        untrusted_advice,
        trusted_advice,
        memory_config,
    );
    (trace, memory, io_device)

```

