#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *

// #show raw.where(block: false): set text(font: "PT Mono", fill: red)
#pagebreak()
= Compilation<sec:compilation>

If we had to summarise what the end goal of this phase of Jolt is, it is the following:

#block(width: 100%, fill: blue.transparentize(80%),   
    inset: 8pt,
    radius: 3pt,
    // stroke: 1pt
    )[
      We start with Rust source code (as shown in @guest-program), and we end with a file in `/path/to/things` full of bytes that a extended RISC-V CPU (or VM pretending to be a RISC-V CPU) can execute.
      Everything in between is just machinery to make that translation correct -- that we discuss in this section.

      Note that we say extended because, we need to also support the _virtual instructions_ that the base RISC-V ISA does not support.
    ]

Execution begins with the following instruction. 

```bash
    cargo run --release -p jolt-core profile --name fibonacci
```

The user is telling Jolt that it wishes to run a guest program described `/path/to/things`

#codebox()[
```rust
let _a = "hello";
```
]

#context bib_state.get()
