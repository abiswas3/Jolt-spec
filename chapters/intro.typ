#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *

= Overview<overview>

== Problem Summary<problem-summary>
//
// #figure(
//   image("../assets/Jolt-overview.svg", width: 91%),
//   caption: [
//     A high level overview of what the Jolt prover does. 
//     The verifying program wishes to compute the answer from executing some program. 
//     The prover...
//     ],
// )
Before diving into its inner workings, we provide a high level overview of the problem the Jolt zk-VM attempts to solve. 
A user#footnote[We make the following distinction between the terms "user" and "verifier". 
Throughout, this document, when we say "user", we mean an application user that uses Jolt to delegate  computation.
When we say "verifier", we mean the specific Jolt verifier algorithm, that aforementioned user will use to certify a Jolt proof.]<fn> wishes to delegate some computation to Jolt, in return for the guarantee that Jolt  performed said computation as prescribed.
By computation, in this document we will always refer to a program written in a high level programming language (such as Rust, C++, ...), and by guarantee, we mean that Jolt will certify that the program was executed correctly.
Throughout this document we will use the rust program described in @guest-program, which computes the sum of the first $n$ elements in Fibonacci sequence, as the working example for delegated computation.
$n$ will be an example of program input, and the user is responsible for specifying it.
#todo[TODO: Change the code to the correct snippet.]


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

A broad description of the sequence of events.

1. The user hands over the program described in @guest-program to the prover, and says "Run this program with $n=5$ and give me a proof that this is the correct answer".

Next we show two alternate paths that the prover could take. It could be honest, or it could lie arbitrarily. 

2a. The prover claims, "the answer is 5, and here is a proof $pi$ that I computed everything correctly".   

2b. The prover claims, "the answer is 10, and here is a proof $pi'$ that I computed everything correctly".

3a. The verifier accepts $pi$ as valid and uses 5 as the answer. 
3b. The verifier rejects $pi'$, and declares the prover to be a cheat. 

This is the premise of the Jolt zk-VM.

Of course we have intentionally been abstract about what constitutes a "proof", and how does one validate such a proof. 
Our job, for the remainder of this document will be to formally define these statements, and show that the above guarantees do indeed hold. 
We begin this work by peeling back one layer of abstraction, and decomposing Jolt into a sequence of logical components.

== Overview Of Jolt Components 

The Jolt zk-VM can be logically partitioned into the components described in the following subsections. 
Each component is later described in detail in a subsequent chapter. 

- *Compilation*: Although the user specifies computation by writing a program in rust, the Jolt prover can only interface with programs written in special Jolt assembly. This special Jolt assembly, referred to as the `Bytecode` in the code base is a small extension of the `riscv-imac` ISA. Thus, our first step is to take the rust program and compile to `Bytecode`. Here we will encounter our first formal verification problem. We want to show that by extending `riscv` ISA, we are not changing the program behaviour in any meaningful way. The is meant to just facilitate proving.

- *Execution*: With the `Bytecode` at hand, the next step is to actually do the computation. Towards this, Jolt emulates a CPU capable of fetching, decoding and executing the jolt assembly program with the specified user inputs. The emulation leads to an object referred to as the `trace`, which can be viewed as a compact representation of the machine state before and after the execution of each instruction in the bytecode.

- *Information-Theoretic Proofs*: Now with execution complete, and jolt defines a sequence of constraints as a function of the trace. Then it makes the claim that if these constraints were to be satisfied, it would imply that the program was correctly executed. Note that this will be the crux of our formal verification efforts, as there is yet no formal proof (even on paper) that these constraints are sufficient, and or necessary. Assuming these constraints hold, and we can formally verify this statement, the next step is to actually convince the user that these constraints do indeed hold. This is done by describing the constraints as a sequence of polynomial equality constraints, and invoking the sum-check algorithm. Note that the textbook description of sum-check requires a polynomial oracle, and interaction. Interaction will be removed using the Fiat-Shamir transform, and the oracle will be simulated using polynomial commitments. This brings us to cryptography. 

- *Crypto Malarkey*: Assuming all the above steps went through, we need to still show that the polynomial commitment scheme used to simulate a sum-check oracle is complete and sound. 

=== Compilation And Preprocessing 

Although the user describes computation in a high level programming language, as described in @guest-program; the Jolt zk-VM currently only accepts delegated computation described in _extended_ RISC-V assembly.
By _extended_ RISC-V assembly, we mean the `elf` executable that a RISC-V CPU (or RISC-V emulator) can run, plus some extra instructions which we refer to as _virtual_ instructions. 
Virtual instructions (and virtual sequences), are introduced in Section 6 of the original Jolt manuscript by #citet(<arun2024jolt>).
Virtual instructions can be thought of as extra instructions that are not defined in the official RISC-V ISA #todo[CITE] but are specifically created to facilitate proving.

In @sec:compilation, we describes the above processes in full detail. 
Therefore, the first step is to compile the high level description to an executable. 
Following this, we pre-process this `.elf` file to generate what we refer to the *Jolt Bytecode* (which is the original executable + virtual instructions).  
@fig:birds-overview summarises this first logical phase of the Jolt VM.

#figure(
oxdraw("
graph LR
     prog[Rust Program]
     elf[Elf File]
     byte[ Jolt Byte Code]
     prog -->|Compilation| elf
     elf -->|Jolt tracer| byte 
   ",
 
background: "#f0f8ff",
),
caption: []
)<fig:birds-overview>


=== RISC-V Emulation 

Given the *Jolt Bytecode* and program inputs, the `tracer` crate inside of Jolt executes the program to compute program outputs. 
Additionally it stores a log, called the `trace` of the all the state transitions during the execution  of the executable. 
The `tracer` originated as a fork of the `riscv-rust`#footnote[#link("https://github.com/takahirox/riscv-rust")]<riscv-rust> repository.
It executes the program by emulating a CPU that knows how to fetch, decode and execute _extended_ RISC-V instructions.
In @sec:emulation, we list every virtual instruction used in Jolt, and describe the emulation process in detail, setting us up for our first formal verification task.
#pagebreak()

#danger[Here we encounter our first potential source of bugs -- at least one that Jolt causes#footnote[The compiler that compiles high-level Rust code into an elf file could also have bugs, but this is considered outside the scope of Jolt. Although, Jolt would absorb such errors into its system causing the final proof system to not be complete and sound, the source of the error is not attributed to the Jolt code base.].
We have essentially altered the compilation process. 
The input to Jolt is not the elf file generated by well maintained `rustc` + `llvm` stack, but the augmented *Jolt bytecode*.
One must formally verify that this alteration does not change the expected behaviour of the original program.
Otherwise, what we  end up with is a proof that is potentially sound and complete for a program that is different from the guest program.
]

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

