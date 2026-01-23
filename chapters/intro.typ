#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *

= Overview<overview>

== Problem Summary<problem-summary>

#figure(
  image("../assets/Jolt-overview.svg", width: 91%),
  caption: [
    A high level overview of what the Jolt prover does. 
    The verifying program wishes to compute the answer from executing some program. 
    The prover...
    ],
)
Before diving into the inner workings of Jolt, we provide a high level overview of the problem the Jolt zk-VM attempts to solve. 
A user#footnote[We make the following distinction between the term "user" and the term "verifier". 
Throughout, this document, when we say "user", we mean an application user that uses Jolt to delegate the computation of a computer program. 
When we say "verifier", we mean the specific Jolt verifier algorithm, that aforementioned user will use to certify a Jolt proof.]<fn> wishes to delegate some computation to Jolt, in return for the guarantee that Jolt will perform said computation as prescribed.
By computation, we mean some program written in a high level programming language, and by guarantee, we mean that Jolt will provide the user with checkable proof to ensure that the program was executed correctly.
For example, the user might want to execute the rust program described in @guest-program, which computes the sum of the first $n$ Fibonacci numbers.


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


The user asks Jolt for the output of the program described in @guest-program along with a proof establishing that Jolt computed the answer correctly.
So now instead of executing the program themselves, the task of computing the first $n$ Fibonacci numbers reduces to checking if Jolt output a valid proof. 
If the proof is deemed valid, the user could just accept Jolt's claimed answer as the correct answer.
Alternatively, if Jolt tried to deviate from the prescribed computation in a completely arbitrary manner, the user should not accept Jolts claim.
This is the premise of the Jolt zk-VM.
Our job in this document will be to formally prove that the above conditions hold i.e. the proof system is sound and complete.

== Overview Of Jolt Components 

The Jolt zk-VM can be logically partitioned into the components described in the following subsections. 
Overall the architecture involves 

- Compiling high level guest programs into executables, and further pre-processing these executables to support _virtual_ instructions.

- Performing the role of a VM i.e. emulating a CPU that is able fetch, decode and execute the above executables. This gives us program trace - snapshot of registers and memory after the execution of each instruction.

- We then go from a trace, to a set of polynomials. Some of the polynomials the Jolt needs to commit to using a polynomial commitment scheme, while other polynomials are referred as to as virtual polynomials -- ones which we can evaluate from the committed polynomials, and publicly available information.

- Once we have polynomials that describe the operations in the trace, we use these polynomials to come up with a set of constraints. Satisfying these constraints would indicate that we ran the program correctly.

#todo[This section needs a good bit of wiritng later on.]

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

