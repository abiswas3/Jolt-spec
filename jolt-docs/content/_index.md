+++
title = "Jolt Documentation"
sort_by = "weight"
template = "section.html"
+++

This page contains links to documentation created to aid efforts at formally verifying the [Jolt zk-VM](https://github.com/a16z/jolt).

The [Jolt Walkthrough](@/jolt-walkthrough/_index.md) assumes no SNARK or zk-VM background, and guides the reader through the steps of verifying the execution of a real guest program.
The [Jolt Specifications](@/references/_index.md) aim to act as a complete reference to specific components within Jolt.
See the [Overview](@/jolt-walkthrough/0_overview/index.md) section for a brief description of the logical components of Jolt.
The specifications are often programmatically extracted from the actual code base in a deterministic manner, with minor human supervision.
Sometimes agentic tools are further used to decorate the extracted specs, and find potential inconsistencies with other documentation. 
Human supervision is always advised when using AI tools. 
In the [Blog](@/blog/_index.md) section, we describe implementation details and optimisations to speed up the Jolt prover. 
Finally, the [Architecture](@/architecture/_index.md) chapter is currently empty, and will be optimistically filled out original orchestrators of Jolt. 

---

## References & Further Reading

FIXME: FIX THESE LINKS 

- [Lasso + Jolt paper (ePrint)](https://eprint.iacr.org/2023/1217)
- [Jolt source code (GitHub)](https://github.com/a16z/jolt)
- [Sumcheck protocol primer](https://people.cs.georgetown.edu/jthaler/ProofsArgsAndZK.html)
