#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 

= Overview<overview>

#figure(
  image("../assets/Jolt-overview.svg", width: 90%),
  caption: [
    A step in the molecular testing
    pipeline of our lab.
  ],
)
Before diving into the inner details of the Jolt zk-VM, in this section, we provide a high level of overview of the end goal.
The entry point for Jolt is a guest program that the verifier wants to run. 
Here by guest program, we mean a program written a high level programming language (like `rust`), as shown below.  
In this toy example, the verifier wishes to know the value of `b` but does not wish to run the program themselves.
 The idea is that the Jolt prover will do the work of running the program for the verifier, and give them the answer to `b`,

// Does this live change, indeed it does
// What a life this is what we need to do.
// #cite(<cardoso2023mcgdiff>)
//
// Can i cite @here_is_chap1
//


#codebox()[
  ```rust
  #[jolt::provable(memory_size = 10240, max_trace_length = 65536)]
  fn fib(n: u32) -> u128 {
    let a: u128 = 0;
    let mut b: u128 = 1;

    start_cycle_tracking("fib_loop"); // Use `start_cycle_tracking("{name}")` to start a cycle span
    b = a + b;
    end_cycle_tracking("fib_loop"); // Use `end_cycle_tracking("{name}")` to end a cycle span
    b
  }
  ```
]
#oxdraw("
graph 
     A[Rust Program] 
     B[Elf File]
     C[ByteCode]
     D[Trace]

   A -->|Step 1| B ",
 
background: "#f0f8ff"
 )

#context bib_state.get()

