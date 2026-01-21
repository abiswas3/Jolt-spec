#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 

= Overview<overview>

== Problem Summary<problem-summary>

Before diving into the inner workings of Jolt, we provide a high level overview of the problem the Jolt zk-VM attempts to solve. 
A user#footnote[We make the following distinction between the term "user" and the term "verifier". 
Throughout, this document, when we say "user", we mean an application user that uses Jolt to delegate the computation of a computer program. 
When we say "verifier", we mean the specific Jolt verifier algorithm, that aforementioned user will use to certify a Jolt proof.]<fn> wishes to delegate some computation to the Jolt application, in return for the guarantee that Jolt will perform said computation as prescribed.
By computation, we mean some program written in a high level programming language.
For example, the user might want to execute the rust program described in @guest-program, which computes the sum of the first $n$ Fibonacci numbers.


TODO: Change the code to the correct snippet.
// #figure(
//   image("../assets/Jolt-overview.svg", width: 90%),
//   caption: [
//     A high level overview of what the Jolt prover does. 
//     The verifying program wishes to compute the answer from executing some program. 
//     The prover...
//     ],
// )
#figure(
codebox()[
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
],
caption: []
)<guest-program>


The user asks Jolt for the output of the program described in @guest-program along with a proof establishing that Jolt computed the answer correctly.
So now instead of executing the program themselves, the task of computing the first $n$ Fibonacci numbers reduces to checking if Jolt output a valid proof. 
If the proof is deemed valid, the user could just accept Jolt's claimed answer as the correct answer.
Alternatively, if Jolt tried to deviate from the prescribed computation in a completely arbitrary manner, the user should not accept Jolts claim.
This is the premise of the Jolt zk-VM.

== Overview Of Jolt Components 

@fig:birds-overview describes the user interface to Jolt.

=== Compilation And Preprocessing 

Although the user describes computation in a high level programming language, such as rust, the Jolt zk-VM currently only accepts descriptions written in RISC-V assembly.
Throughout this document we refer to the users high level computation description as the guest program.
Thus, the first step is to compile the given guest program into the appropriate `.elf` file.
@sec:compilation describes this process in detail. 


// Does this live change, indeed it does
// What a life this is what we need to do.
// #cite(<cardoso2023mcgdiff>)
//
// Can i cite @here_is_chap1
//

#figure(
oxdraw("
graph LR
     prog[Rust Program]
     elf[Elf File]

     prog -->|Compilation| elf

prv-pre[Prover Prepocess]
     vfr-pre[Verifier Prepocess]
     elf -->|Jolt Prover Pre-processing| prv-pre
     elf -->|Jolt Verifier Pre-processing| vfr-pre

   ",
 
background: "#f0f8ff",
),
caption: []
)<fig:birds-overview>


=== RISC-V Emulation 

#figure(
oxdraw("
graph TD

     elf[Elf File]
     emulator[Risc V Emulator]
     inputs[Program Inputs]
     trace[Jolt Dynamic Trace]
     output[Program Output]

     elf -->|Input| emulator
     inputs -->|Input| emulator
     emulator -->|Output| trace
     emulator -->|Output| output

   ",
 
background: "#f0f8ff",
),
caption: []
)<fig:emulaton>


=== Polynomial Represenations 

=== The Jolt PIOPs

=== Commitment schemes - Materialising the PIOPS

#context bib_state.get()

