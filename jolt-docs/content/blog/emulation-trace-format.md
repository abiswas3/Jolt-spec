+++
title = "Design Notes: Emulation Trace Format"
weight = 2
description = "Exploring the design decisions behind how Jolt's emulation step produces execution traces."

+++

This post discusses the trace format produced during Jolt's emulation phase
and how it connects to the constraint system.

## Trace Structure

During emulation, the VM processes each instruction and records a trace row.
Each row captures:

- The program counter value $\mathsf{pc}$
- Register reads and writes
- Memory operations
- The instruction opcode and decoded fields

## Connecting to Constraints

The trace feeds directly into the constraint system. For a trace of length $T$,
the prover commits to polynomials representing each column of the trace,
then proves that the constraint relations hold at every row:

$$
\forall\, i \in [T]: \quad C(\text{row}_i) = 0
$$

The multilinear extension $\tilde{w}$ of each column is defined over
$\{0,1\}^{\log T}$, and the sumcheck protocol is used to reduce a claim
about all $T$ rows to a single evaluation point:

$$
\sum_{x \in \{0,1\}^{\log T}} \tilde{C}(\tilde{w}_1(x), \ldots, \tilde{w}_k(x)) = 0
$$

More details in the [Emulation chapter](@/jolt-walkthrough/2_emulation/index.md).
