#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *

= Overview<overview>

== Problem Summary<problem-summary>

Before diving into the inner workings of Jolt, we provide a high level overview of the problem the Jolt zk-VM attempts to solve. 
A user#footnote[We make the following distinction between the term "user" and the term "verifier". 
Throughout, this document, when we say "user", we mean an application user that uses Jolt to delegate the computation of a computer program. 
When we say "verifier", we mean the specific Jolt verifier algorithm, that aforementioned user will use to certify a Jolt proof.]<fn> wishes to delegate some computation to Jolt, in return for the guarantee that Jolt will perform said computation as prescribed.
By computation, we mean some program written in a high level programming language, and by guarantee, we mean that Jolt will provide the user with checkable proof to ensure that the program was executed correctly.
For example, the user might want to execute the rust program described in @guest-program, which computes the sum of the first $n$ Fibonacci numbers.


#todo[TODO: Change the code to the correct snippet.]
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
Our job in this document will be to formally prove that the above conditions hold i.e. the proof system is sound and complete.
== Overview Of Jolt Components 

The Jolt code can be partitioned in a few separate logical components as described below. 

=== Compilation And Preprocessing 

Although the user describes computation in a high level programming language, as described in @guest-program; the Jolt zk-VM currently only accepts as input computational descriptions written in _extended_ RISC-V assembly.
We will shortly qualify what we mean by _extended_, but now it suffices to think of the input to Jolt as an `elf` executable that a RISC-V CPU (or RISC-V emulator) can run.
Therefore, the first step is to compile the high level description to an executable. 
Following this, we pre-process this `.elf` file to generate what we refer to the *Jolt Bytecode*.  
The mental model for the Jolt bytecode is that it's an executable that's described using real and _virtual_ RISC-V instructions. 
@fig:birds-overview summarises this first logical phase of the Jolt VM.
In @sec:compilation we describes the above processes in full detail. 


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

In the emulation phase, given the *Jolt Bytecode* and program inputs, the `tracer` crate inside of Jolt executes the program to compute program outputs. 
Additionally it stores a log, called the `trace` of the all the state transitions during the execution  of the executable. 

The `tracer` originated as a fork of the `riscv-rust`#footnote[#link("https://github.com/takahirox/riscv-rust")]<riscv-rust> repository.

It executes the program by emulating a CPU that knows how to follow RISC-V instructions.
In addition, the Jolt CPU also knows how to handle a special class of instructions described as _virtual instructions_. 
Virtual instructions (and virtual sequences), are introduced in Section 6 of the original manuscript by #citet(<arun2024jolt>).
Virtual instructions are extra instructions that are not defined in the official RISC-V ISA #todo[CITE] but are specifically created to facilitate proving.
in the original paper by @arun2024jolt.  

#todo[FIRST SOURCE OF REAL ERROR]
#danger[One must formally verify that the sequence of virtual instructions actually simulate the corresponding complex instruction. ]
In @sec:emulation, we list every virtual instruction used in Jolt, and list formal statements for correctness.

FIXME: #todo[BEGIN: FROM JOLT BOOK]
Reasons for Using Virtual Instructions:
Complex operations (e.g. division)

Some instructions, like division, don't neatly adhere to the lookup table structure required by prefix-suffix Shout. To handle these cases, the problematic instruction is expanded into a virtual sequence, a series of instructions (some potentially virtual).

For instance, division involves a sequence described in detail in section 6.3 of the Jolt paper, utilizing virtual untrusted "advice" instructions. In the context of division, the advice instructions store the quotient and remainder in virtual registers, which are additional registers used exclusively within virtual sequences as scratch space. The rest of the division sequence verifies the correctness of the computed quotient and remainder, finally storing the quotient in the destination register specified by the original instruction.
Performance optimization (inlines)

Virtual sequences can also be employed to optimize prover performance on specific operations, e.g. hash functions. For details, refer to Inlines.
Implementation details

Virtual instructions reside alongside regular instructions within the instructions subdirectory of the tracer crate. Instructions employing virtual sequences implement the VirtualInstructionSequence trait, explicitly defining the sequence for emulation purposes. The execute method executes the instruction as a single operation, while the trace method executes each instruction in the virtual sequence.
Performance considerations

A first-order approximation of Jolt's prover cost profile is "pay-per-cycle": each cycle in the trace costs roughly the same to prove, regardless of which instruction is being proven or whether the given cycle is part of a virtual sequence. This means that instructions that must be expanded to virtual sequences are more expensive than their unexpanded counterparts. An instruction emulated by an eight-instruction virtual sequence is approximately eight times more expensive to prove than a single, standard instruction.

On the other hand, virtual sequences can be used to improve prover performance on key operations (e.g. hash functions). This is discussed in the Inlines section.

FIXME: #todo[END: FROM JOLT BOOK]

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


== The Jolt PIOPs

=== Jolt Prover

#figure(
oxdraw("
graph TD

     inputs[Program Inputs]
     trace[Jolt Dynamic Trace]
     output[Program Output]
     prover[Jolt Prover]
     pre[Prover Preprocess]
     proof[Proof]

     inputs -->|Input| prover  
    pre-->|Input| prover  
     trace -->|Input| prover  
     output -->|Input| prover 
    prover -->|Output| proof


   ",
 
background: "#f0f8ff",
),
caption: []
)<fig:piop>

=== The Jolt Verifier


#figure(
oxdraw("
graph TD
     inputs[Program Inputs]
     proof[Jolt Proof]
     output[Program Output]
     pre[Prover Preprocess]
     decision[Decision]

     inputs -->|Input|  decision 
     pre-->|Input| decision  
     proof -->|Input| decision
     output -->|Input| decision


   ",
 
background: "#f0f8ff",
),
caption: []
)<fig:vfr>


== Commitment schemes - Materialising the PIOPS

#context bib_state.get()

