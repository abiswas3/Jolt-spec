#import "../preamble.typ": *
#import "@preview/oxdraw:0.1.0": * // For mermaid diagrams 
#import "../commands.typ": *

#pagebreak()

RISC-V descriptions are taken from #link("https://msyksphinz-self.github.io/riscv-isadoc/")

== SUBW

```asm
subw rd,rs1,rs2
```
*Description*: Subtract the 32-bit of registers rs1 and 32-bit of register rs2 and stores the result in rd. Arithmetic overflow is ignored and the low 32-bits of the result is sign-extended to 64-bits and written to the destination register

=== Virtual Sequence

```rust
asm.emit_r::<SUB>(self.operands.rd, self.operands.rs1, self.operands.rs2);
asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
```
where the instructions `SUB` and `VirtualSignExtendWord` are defined as follows:

`SUB`: 
Subs the register rs2 from rs1 and stores the result in rd. Arithmetic overflow is ignored and the result is simply the low XLEN bits of the result.

```rust
//Implementation
x[rd] = x[rs1] - x[rs2]
```

`VirtualSignExtendWord`: Sign-extends the lower 32 bits of a register to 64 bits:\

```rust
//Implementation
(cpu.x[self.operands.rs1 as usize] << 32) >> 32
```

#theorem[
Let the triple `(rd, rs1, rs2)` denote the machine state. Then machine state before and after execution of `subw` and the virtual sequence is identical.
]
#proof[
`rs1, rs2` remain unchanged before and after the instruction. All there is to show is that the value in `rd` is the same. 

As defined earlier let $x,y,z$ denote the `w` bit values in `rs1, rs2, rd` represented in unsigned form. 
Similarly, $x', y', z'$ are the same but in signed representation. 

The first instruction gives us :
$
z &= x - y " " (mod 2^(64)) \
$
By construction, the lower 32 bits of z are exactly with arithmetic overflow ignored.
$
z[31:0]=(x[31:0]−y[31:0]) mod 2^(32) 
$

Finally we sign extend the lower 32 bits of $z$ to get the desired answer. 
]

== SLLI 

```asm
slli rd,rs1,shamt
```

Performs logical left shift on the value in register `rs1` by the shift amount held in the lower 5 bits of the immediate.
In RV64, bit-25 is used to shamt[5].

=== Virtual Sequence 

```rust
shift = immm & 0x3f; // Lower 6 bits 
asm.emit_i::<VirtualMULI>(self.operands.rd, self.operands.rs1, 1 << shift);
```

#theorem[States mactch
]
#proof[

Let variable $s$ denote the `shift` amount stored in `Imm[0:5]` and $x$ denote the value in `rs1`.
It's a mathematical fact that 
$
z = x times 2^s =  x << s
$
where $times$ denotes wrapping multiplication i.e we drop the overflow. 
Therefore, the final value in `rd` is correct. 
]

== SRLI 
Performs logical right shift on the value in register rs1 by the shift amount held in the lower 5 bits of the immediate In RV64, bit-25 is used to shamt[5].
=== Virtual Sequence 

```rust
shift = imm & 0x3f // shift \in [0, 63]
len = 64
ones = (1u128 << (len - shift)) - 1;
bitmask = (ones << shift) as u64
// Virtual SRLI right shifts contents of rs1 by the number 
// of trailing zeros in the bitmask
asm.emit_vshift_i::<VirtualSRLI>(self.operands.rd, self.operands.rs1, bitmask);
```

#theorem[
Match
]
#proof[
Let $i$ denote the immediate value in the instruction. 
Define $w=64$ and $s = i and "0x3F"$ be the number of bits to shift. 

From the definition of `srli` we have that the destination register will contain
$
z =x >> s
$

Define $o := 2^(w-s) - 1$. We claim $o$ has $s$ 0's in it's higher order bits. 
If this claim were to be true, then the bitmask $b$ created by loggically shifting $o$ by $s$
$b = o << s$ would have exactly $s$ trailing 0's.
We know that `VirtualSRLI` right shifts contents of `rs1` by number of trailing 0's of `bitmask`.
This gives us that $z = x >> s$.

All that's left to show is that $b$ has $s$ 0's in its higher order bits. 
For any $k >= 0$, $2^k$ has bit $k$ set to 1, and $k$ trailing 0's, and $w-s-1$ prefix bits are 0.
This gives us $2^k-1$, clears the $k$'th bit, and sets all trailing $0$'s to ones, giving us $w-k$ prefix bit 0's.
Now set $k = w-s$, we get our result.

]

== LW 

*Description*: 
Loads a 32-bit value from memory and sign-extends this to XLEN bits before storing it in register rd.

=== Virtual Sequence 

```rust 
asm.emit_halign::<VirtualAssertWordAlignment>(self.operands.rs1, self.operands.imm);
asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
asm.emit_i::<SLLI>(*v_shift, *v_address, 3);
asm.emit_r::<SRL>(self.operands.rd, *v_dword, *v_shift);
asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
```


== SRLIW

```asm
srliw rd,rs1,shamt
```
*Description*

Performs logical right shift on the 32-bit of value in register rs1 by the shift amount held in the lower 5 bits of the immediate. Encodings with `imm[5]` $eq.not$ `0` are reserved.

Implementation:
```asm
x[rd] = sext(x[rs1][31:0] >>u shamt)
```

=== Virtual Instructions 

```rust
asm.emit_i::<SLLI>(*v_rs1, self.operands.rs1, 32);
(shift, len) = ((self.operands.imm & 0x1f) + 32, 64)
let ones = (1u128 << (len - shift)) - 1;
let bitmask = (ones << shift) as u64;
asm.emit_vshift_i::<VirtualSRLI>(self.operands.rd, *v_rs1, bitmask);
asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
```

#proof[

The first instrction does Arithmetic right shift on the 32-bit of value in register rs1  and stores 
it into virtual register `v-rs1`
$
v_(r 1) = x[0:31] >>
$
]


== SRA

```asm
sra rd,rs1,rs2
```
Description
Performs arithmetic right shift on the value in register rs1 by the shift amount held in the lower 5 bits of register rs2

Implementaion:
```rust
x[rd] = x[rs1] >>s x[rs2]
```
== AMONEXW
```asm
amomaxu.w rd,rs2,(rs1)
```
*Description*
Atomically load a 32-bit unsigned data value from the address in rs1, place the value into register rd, apply unsigned max the loaded value and the original 32-bit unsigned value in rs2, then store the result back to the address in rs1.


```rust
x[rd] = AMO32(M[x[rs1]] MAXU x[rs2])
```

=== Virtual Instructions 

```rust

asm.emit_halign::<VirtualAssertWordAlignment>(rs1, 0);
// Use v_shift temporarily to hold aligned address
asm.emit_i::<ANDI>(v_shift, rs1, -8i64 as u64);
asm.emit_ld::<LD>(v_dword, v_shift, 0);
// Now compute the actual shift value
asm.emit_i::<SLLI>(v_shift, rs1, 3);
asm.emit_r::<SRL>(v_rd, v_dword, v_shift);


asm.emit_i::<VirtualZeroExtendWord>(*v_rs2, self.operands.rs2, 0);
// Zero-extend v_rd in place into v_sel_rd (temporarily)
asm.emit_i::<VirtualZeroExtendWord>(*v_sel_rd, *v_rd, 0);
// Compare: v_sel_rd (zero-extended v_rd) < v_rs2
asm.emit_r::<SLTU>(*v_sel_rs2, *v_sel_rd, *v_rs2);
// Invert selector to get selector for v_rd
asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
// Select maximum using multiplication
asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);


asm.emit_i::<ORI>(v_mask, 0, -1i64 as u64);
asm.emit_i::<SRLI>(v_mask, v_mask, 32);
asm.emit_r::<SLL>(v_mask, v_mask, v_shift);
// Use v_shift as temporary after it's been used for shifting
asm.emit_r::<SLL>(v_shift, rs2, v_shift);
asm.emit_r::<XOR>(v_shift, v_dword, v_shift);
asm.emit_r::<AND>(v_shift, v_shift, v_mask);
asm.emit_r::<XOR>(v_dword, v_dword, v_shift);
// Recompute aligned address for store
asm.emit_i::<ANDI>(v_mask, rs1, -8i64 as u64);
asm.emit_s::<SD>(v_mask, v_dword, 0);
asm.emit_i::<VirtualSignExtendWord>(rd, v_rd, 0);
```
