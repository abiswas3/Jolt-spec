+++
title = "Stage 2"
weight = 6

[extra]
katex = true
math = true
+++

## Recap

Openings table after [Stage 1](@/jolt-walkthrough/stage1/index.md):

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

## Product Constraints

Among the openings above, five are claimed to be *products* of two other polynomials. R1CS is linear — it can only express $A \cdot B = C$ where $A$, $B$, $C$ are each linear combinations of the inputs. It cannot verify that a claimed product witness is correct inline. So these product relationships are proved via a dedicated sumcheck in this stage.

| # | Output | Left Factor | Right Factor |
|---|--------|-------------|--------------|
| 0 | Product | LeftInstructionInput | RightInstructionInput |
| 1 | WriteLookupOutputToRD | IsRdNotZero | OpFlags(WriteLookupOutputToRD) |
| 2 | WritePCtoRD | IsRdNotZero | OpFlags(Jump) |
| 3 | ShouldBranch | LookupOutput | InstructionFlags(Branch) |
| 4 | ShouldJump | OpFlags(Jump) | 1 - NextIsNoop |

Each row says: the prover claims that Output$(t)$ = Left$(t) \cdot$ Right$(t)$ for all $t \in \hypercube{T}$.

{% theorem(type="box") %}

**SpartanProductVirtualization**

{% math() %}
\begin{aligned}
& \sum_{\X{T} \in \hypercube{T}} \eqpoly{\rr{cycle}}{\X{T}} \cdot \Big( \\\\[8pt]
& \quad \gamma^0 \cdot \mle{\text{LeftInstructionInput}}(\X{T}) \cdot \mle{\text{RightInstructionInput}}(\X{T}) \\\\[8pt]
& \quad + \gamma^1 \cdot \mle{\text{IsRdNotZero}}(\X{T}) \cdot \mle{\text{OpFlags(WriteLookupOutputToRD)}}(\X{T}) \\\\[8pt]
& \quad + \gamma^2 \cdot \mle{\text{IsRdNotZero}}(\X{T}) \cdot \mle{\text{OpFlags(Jump)}}(\X{T}) \\\\[8pt]
& \quad + \gamma^3 \cdot \mle{\text{LookupOutput}}(\X{T}) \cdot \mle{\text{InstructionFlags(Branch)}}(\X{T}) \\\\[8pt]
& \quad + \gamma^4 \cdot \mle{\text{OpFlags(Jump)}}(\X{T}) \cdot (1 - \mle{\text{NextIsNoop}}(\X{T})) \Big) \\\\[10pt]
& = \gamma^0 \cdot \mle{\text{Product}}(\rr{cycle}) + \gamma^1 \cdot \mle{\text{WriteLookupOutputToRD}}(\rr{cycle}) \\\\[8pt]
& \quad + \gamma^2 \cdot \mle{\text{WritePCtoRD}}(\rr{cycle}) + \gamma^3 \cdot \mle{\text{ShouldBranch}}(\rr{cycle}) \\\\[8pt]
& \quad + \gamma^4 \cdot \mle{\text{ShouldJump}}(\rr{cycle})
\end{aligned}
{% end %}


{% end %}


The right-hand side is known — these are exactly the openings of the Output polynomials at $\rr{cycle}$ already stored in the openings table from Stage 1.

## RAM Read/Write Checking

## Instruction Claim Reduction

## RAM RAF Evaluation

## RAM Output Check
