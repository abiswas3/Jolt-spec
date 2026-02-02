+++
title = "Overview"
weight = 1
[extra]
katex = true
+++

## TLDR - What is Jolt anyway

A user[^1] wishes to delegate some computation to Jolt, in return for a promise that Jolt will perform said computation as prescribed.
By computation, in this document we will always refer to a program written in a high-level programming language (such as Rust, C++, etc.), and by guarantee, we mean that Jolt will certify that the program was executed correctly.
Throughout this document we will use the Rust program described below, which computes the sum of the first $n$ elements in the Fibonacci sequence, as the working example for delegated computation.
$n$ here will denote the user input to the program.
It is alright if the procedural macros below do not make sense immediately. 
We will discuss them later.

```rust
#![cfg_attr(feature = "guest", no_std)]
use jolt::{end_cycle_tracking, start_cycle_tracking};

#[jolt::provable(memory_size = 32768, max_trace_length = 65536)]
fn fib(n: u32) -> u128 {
    let mut a: u128 = 0;
    let mut b: u128 = 1;
    let mut sum: u128;

    start_cycle_tracking("fib_loop"); // Use `start_cycle_tracking("{name}")` to start a cycle span

    for _ in 1..n {
        sum = a + b;
        a = b;
        b = sum;
    }
    end_cycle_tracking("fib_loop"); // Use `end_cycle_tracking("{name}")` to end a cycle span
    b
}

}
```

From the user's perspective, the interaction looks something like this.
It hands a program to Jolt along with program inputs.
Jolt in return performs the computation described by the program and hands over a proof $\pi$ that it did things correctly.
The user checks this proof using the verifying algorithm.
If the verifying algorithm says the proof is okay, then the user just accepts the prover's claimed output as the true answer (as if they had done the computation themselves).
Essentially what we have done from the users perspective, is that we have reduced the users task of executing a program to that of checking a proof.

{% mermaid() %}
sequenceDiagram
    participant User
    participant Prover 
    User->>Prover: Run fibonacci program with n=5, provide proof 
    Prover->>User: The answer is 5, and here's a proof π  
    User->>Prover: I accept your proof, so 5 is the correct answer
{% end %}

That is all there is to Jolt. Nothing more, nothing less. 
Of course, we have intentionally been abstract about what constitutes a "proof" and how one validates such a proof. 
Our job for the remainder of this document is to demystify this process.
As a first step, we take this massive entity we call the Jolt zk-VM and split it into many logical components that do very specific tasks.
These components then talk to each other to create the final Jolt experience.


## The Moving Pieces

At the highest level -- Jolt has two components - the front end, and the back end. 
We will properly define what the words in the diagram mean soon. 

{% mermaid() %}

%%{init:{'themeCSS':'g:nth-child(1) rect.actor { stroke:blue;fill: pink;}; g:nth-child(4) rect.actor { stroke:blue;fill: pink;}; g:nth-child(6) rect.actor { stroke:blue;fill: #F8DE7E; }; g:nth-child(3) rect.actor { stroke:blue;fill: #F8DE7E; }'}}%%
sequenceDiagram
    participant User as User Program + Inputs
    participant FE as Front End   
    participant BE as Back End 
    User->>FE: Send program and inputs
    Note over FE: 1. Convert to bytecode.<br/>2. Execute program by emulating CPU to generate trace.<br/>3. Transform trace to polynomials constraints.
    FE->>BE: Forward polynomial constraints
    Note over BE: 1. Commit to polynomials <br/> 2. Perform sequence of sum-checks to prove constraint satisfaction. <br/> 3. Open Commitments <br/> 4. Verifying Algorithm checks
{% end %}

For now, the mental model to have is that the front end is responsible for taking the high-level program description and converting it into a mathematical object that proof systems can understand.
The mathematical object we have here is polynomial equations as constraint satisfaction problems.
The back end proves that these polynomial equations are indeed satisfied. 

### Front End 

The following mermaid sequence diagram gives an overview of the important front-end components. 
The [Compilation](@/jolt-walkthrough/1_compilation.md) chapter will cover how we go from the Rust program described above to a binary written in Jolt assembly (an extended version of [RISCV](https://riscv.org/specifications/ratified/)).
At the end of this step, we get an assembly program in the Jolt-ISA that the Jolt CPU can actually execute. 
One can find a complete specification of the [Jolt ISA here](@/references/jolt-isa.md).

{% mermaid() %}
%%{init:{'themeCSS':'g:nth-child(1) rect.actor { stroke:blue;fill: pink; }; g:nth-of-type(6) rect.actor { stroke:blue;fill: pink; };'}}%%
sequenceDiagram
    participant User
    participant RISCV as RISCV Compiler
    participant Jolt as Jolt Compiler
    participant CPU as Jolt CPU
    participant Backend as Jolt Backend
    User->>RISCV: Rust program + User Input
    Note over RISCV: Compile to RISCV-IMAC
    RISCV->>Jolt: RISCV Assembly Instructions
    Note over Jolt: Transform to Jolt Bytecode
    Jolt->>CPU: Jolt Bytecode + User Input
    Note over CPU: Run the program with user inputs 
    CPU->>Backend: Execution trace + User Inputs
 
{% end %}

The Jolt CPU emulates a VM (this is where the VM in the zk-VM nomenclature comes from) - fetches, decodes and executes instructions.
The execution process is detailed in the chapter on [Emulation](@/jolt-walkthrough/2_emulation.md).
At the end of execution, we obtain a trace. 
A trace is just a fancy word for bookkeeping.
It is a record of the program state (the registers, memory, program counter, flags etc) before and after each instruction.


> **Thing To Ponder**: This Jolt assembly program that we execute, how do we know is actually even the original program the user wrote? 
Such skepticism is well-founded. 
The `rustc` compiler and `LLVM` framework is audited and worked on consistently, by experienced developers. 
Although we are not 100% guaranteed it is entirely free of bugs, we can be fairly confident in its correctness (at least this is the world we currently live in). 
Jolt assembly on the other hand is something we just made up.
Why should you trust this? 
You shouldn't! But this is our **first formal verification task**. 
We will show, by modelling correctness as a theorem in Lean4, that this Jolt assembly will not change program behaviour at all.
As part of this tutorial, we will prove this theorem on pen and paper. 
When the formal verification engine is ready, we will provide a link to formally verified bytecode on this website,
>
>If we were to successfully formally verify this step, then we have the following guarantee. If you trusted the original assembly file, then you can trust the new Jolt assembly file.

We know that Jolt assembly accurately describes the high level rust program, but how do we know that this Jolt CPU ran things properly? 
That is the trace is as expected.
Well, this is the Jolt problem after all. 
Jolt is meant to give us a "proof" that it runs all instructions according to the ISA.
But proofs are found in maths textbooks. 
All we have is an assembly file and a record of its execution.
How does one even define a theorem statement that the program was run correctly?
What Jolt does is take the trace described above, and define a system of constraints as polynomial equations in terms of the trace. 
Constraints look like the following:
$$\sum_{\vec{X} \in \\{0,1\\}^k} q_1(X_1, \dots, X_k) = 3$$ 
$$ \dots $$
$$\sum_{\vec{X} \in \\{0,1\\}^k} q_m(X_1, \ldots, X_k) = 0$$ 

for  multi-variate polynomial $q_1, \dots, q_m \in \mathbb{F}[X_1, \dots, X_k]$.
We will describe in great detail exactly how these polynomials are defined, and why that implies program correctness.
The Jolt back-end will receive these equations, and will prove that these equations are indeed satisfied. 

>This is where the `zk` in the zk-VM comes from. 
The nomenclature is rather unfortunate, as zk stands for zero-knowledge - a type of proof with special properties that Jolt will eventually satisfy.
Zero knowledge, however, has little to do with the main technical concepts that illuminate the magic of Jolt.
What we really want to say is that the Jolt prover outputs a proof, such that verifying this proof should take less time than it should for the user to run the program themselves.
That's the real goal. Such proofs are often be referred to as SNARKs[^2] in the literature.

Okay, even if the polynomial constraints are satisfied, how do we know that means that the program is correct?
This is our **second formal verification** task. 
We must show that if we these constraints were satisfied, then we can rest safe and know the Jolt CPU did the right thing.

### The Back End 

From the trace, we get a system of polynomial equations. 
The full list can be found in [constraints](@/references/constraints.md) section of the references chapter. 
The main question here is how does one prove these constraints are satisfied, without actually solving the left- and right-hand sides of the equations themselves.
This is where the [sumcheck](@/references/sumchecks.md) algorithm comes into the picture.
We will first describe these sum-checks in an idealised setting, and then finally in the chapter on [commitments](TODO:), we will unravel the practical mysteries of instantiating sum-checks.
We leave the overview of the back-end short, as without seeing the details we feel it is only more confusing.


We are now ready for our first deep dive - [compilation](@/jolt-walkthrough/1_compilation.md).

## Footnotes

[^1]: We make the following distinction between the terms "user" and "verifier". Throughout this document, when we say "user", we mean an application user that uses Jolt to delegate computation. When we say "verifier", we mean the specific Jolt verifier algorithm that the aforementioned user will use to certify a Jolt proof.

[^2]: It's usually not as simple. SNARKs refer to *Succinct Non-Interactive Arguments Of Knowledge*. That is indeed a mouthful, and if needed we will define all those of terms formally. For now such formalism will be a mere distraction.


