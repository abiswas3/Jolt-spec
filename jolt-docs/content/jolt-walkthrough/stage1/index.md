+++
title = "Stage 1"
weight = 5

[extra]
katex = true
math = true
+++

This is the first sumcheck in the Jolt proving pipeline.

We refer the reader to [this blog post](TODO: sumcheck-blog-link) for a detailed explanation of how the basic sumcheck algorithm works.

## Recap

In the [Constraints](@/jolt-walkthrough/constraints/index.md) chapter we established that a correct execution must satisfy:

{% theorem(type="box") %}

**Spartan Outer Sumcheck:** The prover demonstrates the following by running a sumcheck:

{% math() %}
$$
\sum_{\substack{\X{X} = (\X{X_t}, \X{X_b}, \X{X_c}) \\\\ \X{X_t} \in \hypercube{T}, \X{X_b} \in \bit, \X{X_c} \in \{-5,\ldots,4\}}} \eqpoly{\tau}{\X{X}} \cdot \mle{A}(\X{X}) \cdot \mle{B}(\X{X}) = 0
$$

{% end %}

{% end %}

## After the Sumcheck

After the Spartan outer sumcheck completes, the verifier obtains random challenges $r = (\rr{cycle}, \rr{b}, \rr{c}) \in \FF^{\log_2 T + 2}$ for the $\log_2 T$ timestep variables, the group variable, and the constraint index variable respectively. The challenges $\rr{b}$ and $\rr{c}$ are absorbed internally and do not appear further. The prover computes evaluations of every R1CS input polynomial at $\rr{cycle} \in \FF^{\log_2 T}$ and stores them in an internal **openings table**. We will track this table from now on — each subsequent sumcheck will add its own entries.

| Sumcheck ID | Polynomial ID | Opening Point |
|-------------|--------------|---------------|
| SpartanOuter | LeftInstructionInput | $\rr{cycle}$ |
| SpartanOuter | RightInstructionInput | $\rr{cycle}$ |
| SpartanOuter | Product | $\rr{cycle}$ |
| SpartanOuter | LeftLookupOperand | $\rr{cycle}$ |
| SpartanOuter | RightLookupOperand | $\rr{cycle}$ |
| SpartanOuter | LookupOutput | $\rr{cycle}$ |
| SpartanOuter | Rs1Value | $\rr{cycle}$ |
| SpartanOuter | Rs2Value | $\rr{cycle}$ |
| SpartanOuter | RdWriteValue | $\rr{cycle}$ |
| SpartanOuter | RamAddress | $\rr{cycle}$ |
| SpartanOuter | RamReadValue | $\rr{cycle}$ |
| SpartanOuter | RamWriteValue | $\rr{cycle}$ |
| SpartanOuter | PC | $\rr{cycle}$ |
| SpartanOuter | NextPC | $\rr{cycle}$ |
| SpartanOuter | UnexpandedPC | $\rr{cycle}$ |
| SpartanOuter | NextUnexpandedPC | $\rr{cycle}$ |
| SpartanOuter | Imm | $\rr{cycle}$ |
| SpartanOuter | CircuitFlags (14 flags) | $\rr{cycle}$ |
| SpartanOuter | NextIsNoop | $\rr{cycle}$ |
| SpartanOuter | ShouldJump | $\rr{cycle}$ |
| SpartanOuter | ShouldBranch | $\rr{cycle}$ |
| SpartanOuter | WriteLookupOutputToRD | $\rr{cycle}$ |
| SpartanOuter | WritePCtoRD | $\rr{cycle}$ |
| SpartanOuter | NextIsVirtual | $\rr{cycle}$ |
| SpartanOuter | NextIsFirstInSequence | $\rr{cycle}$ |
