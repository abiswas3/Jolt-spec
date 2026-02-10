+++
title = "Why Lasso over Plookup"
weight = 1
description = "The architectural rationale for choosing Lasso-style lookups over Plookup in Jolt."

+++

Jolt relies heavily on lookup arguments to verify instruction execution.
The choice of lookup scheme has deep consequences for prover performance,
proof size, and the overall constraint architecture.[^1]

## Background

Traditional lookup arguments like Plookup[^2] require the prover to sort
the combined lookup and table vectors. For a table of size $N$ and $m$ lookups,
this sorting step dominates prover cost at $O((N + m) \log(N + m))$.

Lasso takes a fundamentally different approach. Instead of sorting, it uses
a *sparse* polynomial commitment scheme. The prover only touches table entries
that are actually accessed, giving cost proportional to $m$ rather than $N$.[^3]

## Implications for Jolt

In Jolt, the lookup table encodes the entire instruction set — every possible
input-output pair for every opcode. This table is enormous: for 32-bit operands,
a naive table would have $2^{64}$ entries per instruction.

Lasso's decomposition technique breaks each large lookup into smaller sub-lookups
over tables of size $2^{16}$ or $2^8$. The subtable results are recombined via
a "collation" sumcheck[^4], which verifies that the decomposed lookups are
consistent with the original instruction semantics.

$$
T[x, y] = g\bigl(T_1[x_1], T_2[x_2], \ldots, T_c[x_c]\bigr)
$$

where each $x_i$ is a chunk of the original input and $g$ is an
instruction-specific combining function.

## Trade-offs

The Lasso approach introduces additional sumcheck rounds compared to Plookup,
increasing proof size and verifier cost slightly. However, the prover speedup
is substantial — often orders of magnitude for large tables.[^5]

[^1]: This decision affects nearly every downstream component: the constraint
      system, the polynomial commitment scheme, and the recursion strategy.

[^2]: Gabizon and Williamson, "plookup: A simplified polynomial protocol for
      lookup tables," 2020.

[^3]: Setty, "Lasso: Unlocking the lookup singularity," 2023. The key insight
      is that sparse commitments avoid paying for table entries never accessed.

[^4]: The collation sumcheck is where Jolt's decomposition is verified. It is
      the most complex part of the lookup argument and has the most constraints.

[^5]: For 32-bit RISC-V instructions, Lasso's prover is roughly 100x faster
      than a Plookup-based approach on the same table.
