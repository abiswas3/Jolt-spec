+++
title = "Hello World: Introducing the Jolt Blog"
weight = 1

+++




## Why a Blog?

The walkthrough and specifications provide structured reference material.
The blog captures the narrative — the *why* behind decisions, open questions,
and explorations that don't fit neatly into reference docs.[^2]

## Math Support

We use MathJax with full macro support. For example, here is the sumcheck protocol's
core equation:

$$
\tilde{f}(r_1, \ldots, r_n) = \sum_{x_2 \in \{0,1\}} \cdots \sum_{x_n \in \{0,1\}} \tilde{f}(r_1, x_2, \ldots, x_n)
$$

Custom macros are defined in **`static/mathjax-config.js`**. To add a new macro
like `\FF` for the finite field, add it to the `macros` object in that file:

```javascript
macros: {
  FF: "\\mathbb{F}",
  poly: ["\\mathrm{poly}(#1)", 1],
}
```

Then use it in any page: `$\FF_p$` renders as the finite field $\FF_p$.

## Inline Math

Inline math works with single dollar signs: the prover sends $g_i(X)$
to the verifier, who checks that $g_i(0) + g_i(1) = C_i$ before sampling
a random challenge $r_i \in \mathbb{F}$.[^3]

[^2]: The blog complements the formal specification by providing motivation
      and context that a reference document typically omits.

[^3]: This is the core check in each round of the sumcheck protocol,
      ensuring the univariate polynomial is consistent with the claimed sum.
