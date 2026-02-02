+++
title = "Jolt ISA"
weight = 2
+++

This document describes the JoltISA -- a combination of `riscv-imac` and _virtual_ instructions defined in the [tracer](TODO:) crate.
It also serves as the document that will guide efforts to formally prove in Lean4, that every expansion from `riscv` instructions to a sequence of _virtal instructions_ is correct.

> All descriptions are extracted from the [riscv-isadoc](https://msyksphinz-self.github.io/riscv-isadoc/).
> The implementations, and inline sequennces were programmatically extracted from the Jolt code base using the code listed [here](TODO:)


## beq.rs
> **BEQ (Branch if Equal):** Compares registers rs1 and rs2; if equal, branches to PC + immediate offset.

```rust
declare_riscv_instr!(
    name   = BEQ,
    mask   = 0x0000707f,
    match  = 0x00000063,
    format = FormatB,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <BEQ as RISCVInstruction>::RAMAccess) {
    if cpu.sign_extend(cpu.x[self.operands.rs1 as usize])
        == cpu.sign_extend(cpu.x[self.operands.rs2 as usize])
    {
        cpu.pc = (self.address as i64 + self.operands.imm as i64) as u64;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## subw.rs
> **SUBW (Subtract Word):** Subtracts rs2 from rs1, truncates the result to 32 bits, and sign-extends it into rd.

* [x]    DONE:
```rust
declare_riscv_instr!(
    name   = SUBW,
    mask   = 0xfe00707f,
    match  = 0x4000003b,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SUBW as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = (cpu
        .x[self.operands.rs1 as usize]
        .wrapping_sub(cpu.x[self.operands.rs2 as usize]) as i32) as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_r::<SUB>(self.operands.rd, self.operands.rs1, self.operands.rs2);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## virtual_rotriw.rs
> **VirtualROTRIW (Virtual Rotate Right Immediate Word):** Emulator-internal instruction that rotates the lower 32 bits of rs1 right by an immediate amount (encoded in trailing zeros of imm). Only valid in 64-bit mode.

```rust
declare_riscv_instr!(
    name = VirtualROTRIW,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualROTRIW as RISCVInstruction>::RAMAccess) {
    let shift = self.operands.imm.trailing_zeros().min(XLEN as u32 / 2);
    let rotated = match cpu.xlen {
        Xlen::Bit32 => {
            panic!("ROTRIW is not supported in 32-bit mode");
        }
        Xlen::Bit64 => {
            let val = cpu.x[self.operands.rs1 as usize] as u64 as u32;
            val.rotate_right(shift)
        }
    };
    cpu.x[self.operands.rd as usize] = rotated as i64;
}
```

*NO INLINE SEQUENCE FOUND*

## lw.rs
> **LW (Load Word):** Loads a 32-bit word from memory at rs1 + offset, sign-extending the result into rd.
* [ ] DONE: 
```rust
declare_riscv_instr!(
    name   = LW,
    mask   = 0x0000707f,
    match  = 0x00002003,
    format = FormatLoad,
    ram    = RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LW as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu
        .mmu
        .load_word(
            cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64,
        )
    {
        Ok((word, memory_read)) => {
            *ram_access = memory_read;
            word as i32 as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => self.inline_sequence_32(allocator),
        Xlen::Bit64 => self.inline_sequence_64(allocator),
    }
}
```

```rust
fn inline_sequence_32(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit32,
        allocator,
    );
    asm.emit_i::<
            VirtualLW,
        >(self.operands.rd, self.operands.rs1, self.operands.imm as u64);
    asm.finalize()
}
```

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_halign::<VirtualAssertWordAlignment>(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<SLLI>(*v_shift, *v_address, 3);
    asm.emit_r::<SRL>(self.operands.rd, *v_dword, *v_shift);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## srliw.rs
> **SRLIW (Shift Right Logical Immediate Word):** Logically shifts the lower 32 bits of rs1 right by the immediate amount (masked to 5 bits), sign-extending the 32-bit result into rd.
* [ ] DONE:
```rust
declare_riscv_instr!(
    name   = SRLIW,
    mask   = 0xfc00707f,
    match  = 0x0000501b,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SRLIW as RISCVInstruction>::RAMAccess) {
    let shamt = (self.operands.imm & 0x1f) as u32;
    cpu.x[self.operands.rd as usize] = ((cpu.x[self.operands.rs1 as usize] as u32)
        >> shamt) as i32 as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs1 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<SLLI>(*v_rs1, self.operands.rs1, 32);
    let (shift, len) = match xlen {
        Xlen::Bit32 => panic!("SRLIW is invalid in 32b mode"),
        Xlen::Bit64 => ((self.operands.imm & 0x1f) + 32, 64),
    };
    let ones = (1u128 << (len - shift)) - 1;
    let bitmask = (ones << shift) as u64;
    asm.emit_vshift_i::<VirtualSRLI>(self.operands.rd, *v_rs1, bitmask);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## scd.rs
> **SCD (Store Conditional Doubleword):** Conditionally stores a 64-bit doubleword from rs2 to the address in rs1 if a prior load-reserved reservation is still valid. Writes 0 to rd on success, 1 on failure.

```rust
declare_riscv_instr!(
    name   = SCD,
    mask   = 0xf800707f,
    match  = 0x1800302f,
    format = FormatR,
    ram    = RAMWrite
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <SCD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let value = cpu.x[self.operands.rs2 as usize] as u64;
    if cpu.has_reservation(address) {
        let result = cpu.mmu.store_doubleword(address, value);
        match result {
            Ok(memory_write) => {
                *ram_access = memory_write;
                cpu.clear_reservation();
                cpu.x[self.operands.rd as usize] = 0;
            }
            Err(_) => panic!("MMU store error"),
        }
    } else {
        cpu.x[self.operands.rd as usize] = 1;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## sra.rs
> **SRA (Shift Right Arithmetic):** Arithmetically shifts rs1 right by the shift amount in rs2 (masked to log2(XLEN) bits), sign-filling the upper bits, and stores the result in rd.
* [ ] DONE:
```rust
declare_riscv_instr!(
    name   = SRA,
    mask   = 0xfe00707f,
    match  = 0x40005033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SRA as RISCVInstruction>::RAMAccess) {
    let mask = match cpu.xlen {
        Xlen::Bit32 => 0x1f,
        Xlen::Bit64 => 0x3f,
    };
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .x[self.operands.rs1 as usize]
                .wrapping_shr(cpu.x[self.operands.rs2 as usize] as u32 & mask),
        );
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_bitmask = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualShiftRightBitmask>(*v_bitmask, self.operands.rs2, 0);
    asm.emit_vshift_r::<VirtualSRA>(self.operands.rd, self.operands.rs1, *v_bitmask);
    asm.finalize()
}
```

## virtual_xor_rot.rs
> **VirtualXorRot (XOR with Rotate):** Emulator-internal macro-generated instruction for XOR combined with rotation operations.

```rust
declare_riscv_instr!(
            name = $name,
            mask = 0,
            match = 0,
            format = FormatR,
            ram = ()
        );
```

*NO INLINE SEQUENCE FOUND*

## lrw.rs
> **LRW (Load Reserved Word):** Loads a 32-bit word from the address in rs1, sign-extending the result into rd, and sets a memory reservation for atomic store-conditional operations.

```rust
declare_riscv_instr!(
    name   = LRW,
    mask   = 0xf9f0707f,
    match  = 0x1000202f,
    format = FormatR,
    ram    = RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LRW as RISCVInstruction>::RAMAccess) {
    if cpu.is_reservation_set() {
        println!("LRW: Reservation is already set");
    }
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let value = cpu.mmu.load_word(address);
    cpu.x[self.operands.rd as usize] = match value {
        Ok((word, memory_read)) => {
            *ram_access = memory_read;
            cpu.set_reservation(address);
            word as i32 as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

*NO INLINE SEQUENCE FOUND*

## amomaxuw.rs
> **AMOMAXUW (Atomic Memory Operation MAX Unsigned Word):** Atomically loads a 32-bit word from the address in rs1, stores the unsigned maximum of it and rs2, and places the original value in rd.

**Desription**:
Atomically load a 32-bit unsigned data value from the address in rs1, place the value into register rd, apply unsigned max the loaded value and the original 32-bit unsignremarked value in rs2, then store the result back to the address in rs1.

 TODO:
```rust
declare_riscv_instr!(
    name   = AMOMAXUW,
    mask   = 0xf800707f,
    match  = 0xe000202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOMAXUW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let compare_value = cpu.x[self.operands.rs2 as usize] as u32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = if (original_value as u32) >= compare_value {
        original_value as u32
    } else {
        compare_value
    };
    cpu.mmu.store_word(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    match xlen {
        Xlen::Bit32 => {
            let v_rd = allocator.allocate();
            let v_rs2 = allocator.allocate();
            let v_sel_rs2 = allocator.allocate();
            let v_sel_rd = allocator.allocate();
            amo_pre32(&mut asm, self.operands.rs1, *v_rd);
            asm.emit_r::<SLTU>(*v_sel_rs2, *v_rd, self.operands.rs2);
            asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
            asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
            asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
            amo_post32(&mut asm, *v_rs2, self.operands.rs1, self.operands.rd, *v_rd);
        }
        Xlen::Bit64 => {
            let v_rd = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            amo_pre64(&mut asm, self.operands.rs1, *v_rd, *v_dword, *v_shift);
            // what amo_pre64 expands to 
            //asm.emit_halign::<VirtualAssertWordAlignment>(rs1, 0);
            //    asm.emit_i::<ANDI>(v_shift, rs1, -8i64 as u64);
            //    asm.emit_ld::<LD>(v_dword, v_shift, 0);
            //    asm.emit_i::<SLLI>(v_shift, rs1, 3); x[rd] = x[rs1] << shamt
            //    asm.emit_r::<SRL>(v_rd, v_dword, v_shift); x[rd] = x[rs1] >>u x[rs2]
            let v_rs2 = allocator.allocate();
            let v_sel_rs2 = allocator.allocate();
            let v_sel_rd = allocator.allocate();
            let v_mask = allocator.allocate();
            asm.emit_i::<VirtualZeroExtendWord>(*v_rs2, self.operands.rs2, 0);
            asm.emit_i::<VirtualZeroExtendWord>(*v_sel_rd, *v_rd, 0);
            asm.emit_r::<SLTU>(*v_sel_rs2, *v_sel_rd, *v_rs2);
            asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
            asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
            asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
            drop(v_sel_rd);
            drop(v_sel_rs2);
            amo_post64(
                &mut asm,
                self.operands.rs1,
                *v_rs2,
                *v_dword,
                *v_shift,
                *v_mask,
                self.operands.rd,
                *v_rd,
            );

    // post-expanded
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
        }
    }
    asm.finalize()
}
```

## ecall.rs
> **ECALL (Environment Call):** Raises an environment call trap corresponding to the current privilege mode (U-mode, S-mode, or M-mode), transferring control to the trap handler.

```rust
declare_riscv_instr!(
    name   = ECALL,
    mask   = 0xffff_ffff,
    match  = 0x0000_0073,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <ECALL as RISCVInstruction>::RAMAccess) {
    let trap_type = match cpu.privilege_mode {
        PrivilegeMode::User => TrapType::EnvironmentCallFromUMode,
        PrivilegeMode::Supervisor => TrapType::EnvironmentCallFromSMode,
        PrivilegeMode::Machine | PrivilegeMode::Reserved => {
            TrapType::EnvironmentCallFromMMode
        }
    };
    cpu.raise_trap(Trap { trap_type, value: 0 }, self.address);
}
```

*NO INLINE SEQUENCE FOUND*

## amoandw.rs
> **Description**: 
> Atomically load a 32-bit signed data value from the address in rs1, place the value into register rd, apply and the loaded value and the original 32-bit signed value in rs2, then store the result back to the address in rs1.
 TODO:
```rust
declare_riscv_instr!(
    name   = AMOANDW,
    mask   = 0xf800707f,
    match  = 0x6000202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOANDW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let and_value = cpu.x[self.operands.rs2 as usize] as u32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = (original_value as u32) & and_value;
    cpu.mmu.store_word(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rd = allocator.allocate();
    let v_rs2 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    match xlen {
        Xlen::Bit32 => {
            amo_pre32(&mut asm, self.operands.rs1, *v_rd);
            asm.emit_r::<AND>(*v_rs2, *v_rd, self.operands.rs2);
            amo_post32(&mut asm, *v_rs2, self.operands.rs1, self.operands.rd, *v_rd);
        }
        Xlen::Bit64 => {
            let v_mask = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            amo_pre64(&mut asm, self.operands.rs1, *v_rd, *v_dword, *v_shift);
            asm.emit_r::<AND>(*v_rs2, *v_rd, self.operands.rs2);
            amo_post64(
                &mut asm,
                self.operands.rs1,
                *v_rs2,
                *v_dword,
                *v_shift,
                *v_mask,
                self.operands.rd,
                *v_rd,
            );
        }
    }
    asm.finalize()
}
```

## remw.rs
> **REMW (Remainder Word):** Computes the signed remainder of the lower 32 bits of rs1 divided by rs2, sign-extending the 32-bit result into rd. Returns the dividend if the divisor is zero.

> **Description**: perform an 32 bits by 32 bits signed integer reminder of rs1 by rs2.


 TODO:
```rust
declare_riscv_instr!(
    name   = REMW,
    mask   = 0xfe00707f,
    match  = 0x200603b,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <REMW as RISCVInstruction>::RAMAccess) {
    let dividend = cpu.x[self.operands.rs1 as usize] as i32;
    let divisor = cpu.x[self.operands.rs2 as usize] as i32;
    cpu.x[self.operands.rd as usize] = (if divisor == 0 {
        dividend
    } else if dividend == i32::MIN && divisor == -1 {
        0
    } else {
        dividend.wrapping_rem(divisor)
    }) as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let a0 = self.operands.rs1;
    let a1 = self.operands.rs2;
    let a2 = allocator.allocate();
    let a3 = allocator.allocate();
    let t0 = allocator.allocate();
    let t1 = allocator.allocate();
    let t2 = allocator.allocate();
    let t3 = allocator.allocate();
    let t4 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_j::<VirtualAdvice>(*a2, 0);
    asm.emit_j::<VirtualAdvice>(*a3, 0);
    asm.emit_i::<VirtualSignExtendWord>(*t4, a0, 0);
    asm.emit_i::<VirtualSignExtendWord>(*t3, a1, 0);
    asm.emit_b::<VirtualAssertValidDiv0>(*t3, *a2, 0);
    asm.emit_r::<VirtualChangeDivisorW>(*t0, *t4, *t3);
    asm.emit_i::<VirtualSignExtendWord>(*t1, *a2, 0);
    asm.emit_b::<VirtualAssertEQ>(*t1, *a2, 0);
    asm.emit_i::<SRAI>(*t2, *a3, 31);
    asm.emit_b::<VirtualAssertEQ>(*t2, 0, 0);
    asm.emit_i::<SRAI>(*t2, *t4, 31);
    asm.emit_r::<XOR>(*t3, *a3, *t2);
    asm.emit_r::<SUB>(*t3, *t3, *t2);
    asm.emit_r::<MUL>(*t1, *a2, *t0);
    asm.emit_r::<ADD>(*t1, *t1, *t3);
    asm.emit_b::<VirtualAssertEQ>(*t1, *t4, 0);
    asm.emit_i::<SRAI>(*t2, *t0, 31);
    asm.emit_r::<XOR>(*t1, *t0, *t2);
    asm.emit_r::<SUB>(*t1, *t1, *t2);
    asm.emit_b::<VirtualAssertValidUnsignedRemainder>(*a3, *t1, 0);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, *t3, 0);
    asm.finalize()
}
```

## virtual_pow2.rs
> **VirtualPow2 (Virtual Power of 2):** Emulator-internal instruction that computes 2 raised to the power of (rs1 mod XLEN) and stores the result in rd.

```rust
declare_riscv_instr!(
    name = VirtualPow2,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualPow2 as RISCVInstruction>::RAMAccess) {
    match cpu.xlen {
        Xlen::Bit32 => {
            cpu.x[self.operands.rd as usize] = 1
                << (cpu.x[self.operands.rs1 as usize] as u64 % 32);
        }
        Xlen::Bit64 => {
            cpu.x[self.operands.rd as usize] = 1
                << (cpu.x[self.operands.rs1 as usize] as u64 % 64);
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_assert_eq.rs
> **VirtualAssertEQ (Assert Equal):** Emulator-internal assertion that verifies registers rs1 and rs2 contain equal values, panicking if they differ.

```rust
declare_riscv_instr!(
    name = VirtualAssertEQ,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualAssertEQ as RISCVInstruction>::RAMAccess) {
    assert_eq!(cpu.x[self.operands.rs1 as usize], cpu.x[self.operands.rs2 as usize]);
}
```

*NO INLINE SEQUENCE FOUND*

## bltu.rs
> **BLTU (Branch if Less Than Unsigned):** Compares rs1 and rs2 as unsigned values; if rs1 < rs2, branches to PC + immediate offset.

```rust
declare_riscv_instr!(
    name   = BLTU,
    mask   = 0x0000707f,
    match  = 0x00006063,
    format = FormatB,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <BLTU as RISCVInstruction>::RAMAccess) {
    if cpu.unsigned_data(cpu.x[self.operands.rs1 as usize])
        < cpu.unsigned_data(cpu.x[self.operands.rs2 as usize])
    {
        cpu.pc = (self.address as i64 + self.operands.imm as i64) as u64;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## amominuw.rs
> **AMOMINUW (Atomic Memory Operation MIN Unsigned Word):** Atomically loads a 32-bit word from the address in rs1, stores the unsigned minimum of it and rs2, and places the original value in rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = AMOMINUW,
    mask   = 0xf800707f,
    match  = 0xc000202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOMINUW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let compare_value = cpu.x[self.operands.rs2 as usize] as u32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = if (original_value as u32) <= compare_value {
        original_value as u32
    } else {
        compare_value
    };
    cpu.mmu.store_word(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    match xlen {
        Xlen::Bit32 => {
            let v_rd = allocator.allocate();
            let v_rs2 = allocator.allocate();
            let v_sel_rs2 = allocator.allocate();
            let v_sel_rd = allocator.allocate();
            amo_pre32(&mut asm, self.operands.rs1, *v_rd);
            asm.emit_r::<SLTU>(*v_sel_rs2, self.operands.rs2, *v_rd);
            asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
            asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
            asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
            amo_post32(&mut asm, *v_rs2, self.operands.rs1, self.operands.rd, *v_rd);
        }
        Xlen::Bit64 => {
            let v_rd = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            amo_pre64(&mut asm, self.operands.rs1, *v_rd, *v_dword, *v_shift);
            let v_rs2 = allocator.allocate();
            let v_sel_rs2 = allocator.allocate();
            let v_sel_rd = allocator.allocate();
            let v_mask = allocator.allocate();
            asm.emit_i::<VirtualZeroExtendWord>(*v_rs2, self.operands.rs2, 0);
            asm.emit_i::<VirtualZeroExtendWord>(*v_sel_rd, *v_rd, 0);
            asm.emit_r::<SLTU>(*v_sel_rs2, *v_rs2, *v_sel_rd);
            asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
            asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
            asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
            drop(v_sel_rd);
            drop(v_sel_rs2);
            amo_post64(
                &mut asm,
                self.operands.rs1,
                *v_rs2,
                *v_dword,
                *v_shift,
                *v_mask,
                self.operands.rd,
                *v_rd,
            );
        }
    }
    asm.finalize()
}
```

## amomind.rs
> **AMOMIND (Atomic Memory Operation MIN Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, stores the signed minimum of it and rs2, and places the original value in rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = AMOMIND,
    mask   = 0xf800707f,
    match  = 0x8000302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOMIND as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let compare_value = cpu.x[self.operands.rs2 as usize];
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = if original_value <= compare_value {
        original_value
    } else {
        compare_value
    };
    cpu.mmu.store_doubleword(address, new_value as u64).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs2 = allocator.allocate();
    let v_rd = allocator.allocate();
    let v_sel_rs2 = allocator.allocate();
    let v_sel_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_r::<SLT>(*v_sel_rs2, self.operands.rs2, *v_rd);
    asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
    asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
    asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
    asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
    asm.emit_s::<SD>(self.operands.rs1, *v_rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## sraiw.rs
> **SRAIW (Shift Right Arithmetic Immediate Word):** Arithmetically shifts the lower 32 bits of rs1 right by the immediate amount (masked to 5 bits), sign-extending the 32-bit result into rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = SRAIW,
    mask   = 0xfc00707f,
    match  = 0x4000501b,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SRAIW as RISCVInstruction>::RAMAccess) {
    let shamt = (self.operands.imm & 0x1f) as u32;
    cpu.x[self.operands.rd as usize] = ((cpu.x[self.operands.rs1 as usize] as i32)
        >> shamt) as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs1 = allocator.allocate();
    let shift = self.operands.imm & 0x1f;
    let len = match xlen {
        Xlen::Bit32 => panic!("SRAIW is invalid in 32b mode"),
        Xlen::Bit64 => 64,
    };
    let ones = (1u128 << (len - shift)) - 1;
    let bitmask = (ones << shift) as u64;
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualSignExtendWord>(*v_rs1, self.operands.rs1, 0);
    asm.emit_vshift_i::<VirtualSRAI>(self.operands.rd, *v_rs1, bitmask);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## amoaddd.rs
> **AMOADDD (Atomic Memory Operation ADD Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, adds rs2, stores the sum back, and places the original value in rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = AMOADDD,
    mask   = 0xf800707f,
    match  = 0x0000302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOADDD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let add_value = cpu.x[self.operands.rs2 as usize];
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = original_value.wrapping_add(add_value) as u64;
    cpu.mmu.store_doubleword(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs2 = allocator.allocate();
    let v_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_r::<ADD>(*v_rs2, *v_rd, self.operands.rs2);
    asm.emit_s::<SD>(self.operands.rs1, *v_rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## ori.rs
> **ORI (OR Immediate):** Computes the bitwise OR of rs1 and a sign-extended 12-bit immediate, storing the result in rd.

```rust
declare_riscv_instr!(
    name   = ORI,
    mask   = 0x0000707f,
    match  = 0x00006013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <ORI as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize]
                | normalize_imm(self.operands.imm, &cpu.xlen),
        );
}
```

*NO INLINE SEQUENCE FOUND*

## addw.rs
> **ADDW (Add Word):** Adds rs1 and rs2, truncates the result to 32 bits, and sign-extends it into rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = ADDW,
    mask   = 0xfe00707f,
    match  = 0x0000003b,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <ADDW as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .x[self.operands.rs1 as usize]
        .wrapping_add(cpu.x[self.operands.rs2 as usize]) as i32 as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_r::<ADD>(self.operands.rd, self.operands.rs1, self.operands.rs2);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## virtual_assert_mulu_no_overflow.rs
> **VirtualAssertMulUNoOverflow (Assert Multiply Unsigned No Overflow):** Emulator-internal assertion that verifies the unsigned multiplication of rs1 and rs2 does not overflow a 64-bit value.

```rust
declare_riscv_instr!(
    name = VirtualAssertMulUNoOverflow,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualAssertMulUNoOverflow as RISCVInstruction>::RAMAccess,
) {
    let rs1_val = cpu.x[self.operands.rs1 as usize] as u64;
    let rs2_val = cpu.x[self.operands.rs2 as usize] as u64;
    assert!(rs1_val.checked_mul(rs2_val).is_some());
}
```

*NO INLINE SEQUENCE FOUND*

## fence.rs
> **FENCE (Memory Fence):** Orders memory operations to enforce memory consistency. In this emulator, it is a no-op since execution is single-threaded and in-order.

```rust
declare_riscv_instr!(
    name   = FENCE,
    mask   = 0x0000707f,
    match  = 0x0000000f,
    format = FormatFence,
    ram    = ()
);
```

```rust
fn exec(&self, _: &mut Cpu, _: &mut <FENCE as RISCVInstruction>::RAMAccess) {}
```

*NO INLINE SEQUENCE FOUND*

## amoxorw.rs
> **AMOXORW (Atomic Memory Operation XOR Word):** Atomically loads a 32-bit word from the address in rs1, XORs it with rs2, stores the result back, and places the original value in rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = AMOXORW,
    mask   = 0xf800707f,
    match  = 0x2000202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOXORW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let xor_value = cpu.x[self.operands.rs2 as usize] as u32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = (original_value as u32) ^ xor_value;
    cpu.mmu.store_word(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rd = allocator.allocate();
    let v_rs2 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    match xlen {
        Xlen::Bit32 => {
            amo_pre32(&mut asm, self.operands.rs1, *v_rd);
            asm.emit_r::<XOR>(*v_rs2, *v_rd, self.operands.rs2);
            amo_post32(&mut asm, *v_rs2, self.operands.rs1, self.operands.rd, *v_rd);
        }
        Xlen::Bit64 => {
            let v_mask = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            amo_pre64(&mut asm, self.operands.rs1, *v_rd, *v_dword, *v_shift);
            asm.emit_r::<XOR>(*v_rs2, *v_rd, self.operands.rs2);
            amo_post64(
                &mut asm,
                self.operands.rs1,
                *v_rs2,
                *v_dword,
                *v_shift,
                *v_mask,
                self.operands.rd,
                *v_rd,
            );
        }
    }
    asm.finalize()
}
```

## lhu.rs
> **LHU (Load Halfword Unsigned):** Loads a 16-bit halfword from memory at rs1 + offset, zero-extending the result into rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = LHU,
    mask   = 0x0000707f,
    match  = 0x00005003,
    format = FormatLoad,
    ram    = RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LHU as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu
        .mmu
        .load_halfword(
            cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64,
        )
    {
        Ok((halfword, memory_read)) => {
            *ram_access = memory_read;
            halfword as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => self.inline_sequence_32(allocator),
        Xlen::Bit64 => self.inline_sequence_64(allocator),
    }
}
```

```rust
fn inline_sequence_32(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_word_address = allocator.allocate();
    let v_word = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit32,
        allocator,
    );
    asm.emit_halign::<
            VirtualAssertHalfwordAlignment,
        >(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_word_address, *v_address, -4i64 as u64);
    asm.emit_i::<VirtualLW>(*v_word, *v_word_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 2);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_word, *v_shift);
    asm.emit_i::<SRLI>(self.operands.rd, self.operands.rd, 16);
    asm.finalize()
}
```

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_halign::<
            VirtualAssertHalfwordAlignment,
        >(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 6);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_dword, *v_shift);
    asm.emit_i::<SRLI>(self.operands.rd, self.operands.rd, 48);
    asm.finalize()
}
```

## sh.rs
> **SH (Store Halfword):** Stores the lower 16 bits of rs2 as a halfword to memory at the address rs1 + offset.
 TODO:
```rust
declare_riscv_instr!(
    name   = SH,
    mask   = 0x0000707f,
    match  = 0x00001023,
    format = FormatS,
    ram    = RAMWrite
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <SH as RISCVInstruction>::RAMAccess) {
    *ram_access = cpu
        .mmu
        .store_halfword(
            cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64,
            cpu.x[self.operands.rs2 as usize] as u16,
        )
        .ok()
        .unwrap();
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => self.inline_sequence_32(allocator),
        Xlen::Bit64 => self.inline_sequence_64(allocator),
    }
}

```

```rust
fn inline_sequence_32(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_word_address = allocator.allocate();
    let v_word = allocator.allocate();
    let v_shift = allocator.allocate();
    let v_mask = allocator.allocate();
    let v_halfword = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit32,
        allocator,
    );
    asm.emit_halign::<
            VirtualAssertHalfwordAlignment,
        >(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_word_address, *v_address, -4i64 as u64);
    asm.emit_i::<VirtualLW>(*v_word, *v_word_address, 0);
    asm.emit_i::<SLLI>(*v_shift, *v_address, 3);
    asm.emit_u::<LUI>(*v_mask, 0xffff);
    asm.emit_r::<SLL>(*v_mask, *v_mask, *v_shift);
    asm.emit_r::<SLL>(*v_halfword, self.operands.rs2, *v_shift);
    asm.emit_r::<XOR>(*v_halfword, *v_word, *v_halfword);
    asm.emit_r::<AND>(*v_halfword, *v_halfword, *v_mask);
    asm.emit_r::<XOR>(*v_word, *v_word, *v_halfword);
    asm.emit_s::<VirtualSW>(*v_word_address, *v_word, 0);
    asm.finalize()
}
```

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let v_mask = allocator.allocate();
    let v_halfword = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_halign::<
            VirtualAssertHalfwordAlignment,
        >(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<SLLI>(*v_shift, *v_address, 3);
    asm.emit_u::<LUI>(*v_mask, 0xffff);
    asm.emit_r::<SLL>(*v_mask, *v_mask, *v_shift);
    asm.emit_r::<SLL>(*v_halfword, self.operands.rs2, *v_shift);
    asm.emit_r::<XOR>(*v_halfword, *v_dword, *v_halfword);
    asm.emit_r::<AND>(*v_halfword, *v_halfword, *v_mask);
    asm.emit_r::<XOR>(*v_dword, *v_dword, *v_halfword);
    asm.emit_s::<SD>(*v_dword_address, *v_dword, 0);
    asm.finalize()
}
```

## or.rs
> **OR (Bitwise OR):** Computes the bitwise OR of rs1 and rs2, storing the result in rd.

```rust
declare_riscv_instr!(
    name   = OR,
    mask   = 0xfe00707f,
    match  = 0x00006033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <OR as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize] | cpu.x[self.operands.rs2 as usize],
        );
}
```

*NO INLINE SEQUENCE FOUND*

## slli.rs
> **SLLI (Shift Left Logical Immediate):** Shifts rs1 left by the immediate shift amount (masked to log2(XLEN) bits) and stores the result in rd.
* [ ]    DONE:
```rust
declare_riscv_instr!(
    name   = SLLI,
    mask   = 0xfc00707f,
    match  = 0x00001013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SLLI as RISCVInstruction>::RAMAccess) {
    let mask = match cpu.xlen {
        Xlen::Bit32 => 0x1f,
        Xlen::Bit64 => 0x3f,
    };
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .x[self.operands.rs1 as usize]
                .wrapping_shl(self.operands.imm as u32 & mask),
        );
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mask = match xlen {
        Xlen::Bit32 => 0x1f,
        Xlen::Bit64 => 0x3f,
    };
    let shift = self.operands.imm & mask;
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualMULI>(self.operands.rd, self.operands.rs1, 1 << shift);
    asm.finalize()
}
```

## add.rs
> **ADD (Add):** Adds rs1 and rs2 and stores the result in rd.

```rust
declare_riscv_instr!(
    name   = ADD,
    mask   = 0xfe00707f,
    match  = 0x00000033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <ADD as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .x[self.operands.rs1 as usize]
                .wrapping_add(cpu.x[self.operands.rs2 as usize]),
        );
}
```

*NO INLINE SEQUENCE FOUND*

## bgeu.rs
> **BGEU (Branch if Greater or Equal Unsigned):** Compares rs1 and rs2 as unsigned values; if rs1 >= rs2, branches to PC + immediate offset.

```rust
declare_riscv_instr!(
    name   = BGEU,
    mask   = 0x0000707f,
    match  = 0x00007063,
    format = FormatB,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <BGEU as RISCVInstruction>::RAMAccess) {
    if cpu.unsigned_data(cpu.x[self.operands.rs1 as usize])
        >= cpu.unsigned_data(cpu.x[self.operands.rs2 as usize])
    {
        cpu.pc = (self.address as i64 + self.operands.imm as i64) as u64;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## srli.rs
> **SRLI (Shift Right Logical Immediate):** Logically shifts rs1 right by the immediate shift amount (masked to log2(XLEN) bits), zero-filling the upper bits, and stores the result in rd.
* [ ]    DONE:
```rust
declare_riscv_instr!(
    name   = SRLI,
    mask   = 0xfc00707f,
    match  = 0x00005013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SRLI as RISCVInstruction>::RAMAccess) {
    let mask = match cpu.xlen {
        Xlen::Bit32 => 0x1f,
        Xlen::Bit64 => 0x3f,
    };
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .unsigned_data(cpu.x[self.operands.rs1 as usize])
                .wrapping_shr(self.operands.imm as u32 & mask) as i64,
        );
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let (shift, len) = match xlen {
        Xlen::Bit32 => (self.operands.imm & 0x1f, 32),
        Xlen::Bit64 => (self.operands.imm & 0x3f, 64),
    };
    let ones = (1u128 << (len - shift)) - 1;
    let bitmask = (ones << shift) as u64;
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_vshift_i::<VirtualSRLI>(self.operands.rd, self.operands.rs1, bitmask);
    asm.finalize()
}
```

## virtual_rotri.rs
> **VirtualROTRI (Virtual Rotate Right Immediate):** Emulator-internal instruction that rotates rs1 right by an immediate amount (encoded in trailing zeros of imm), supporting both 32-bit and 64-bit modes.

```rust
declare_riscv_instr!(
    name = VirtualROTRI,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualROTRI as RISCVInstruction>::RAMAccess) {
    let shift = self.operands.imm.trailing_zeros();
    let rotated = match cpu.xlen {
        Xlen::Bit32 => {
            let val_32 = cpu.x[self.operands.rs1 as usize] as u32;
            val_32.rotate_right(shift) as i64
        }
        Xlen::Bit64 => {
            let val = cpu.x[self.operands.rs1 as usize];
            val.rotate_right(shift)
        }
    };
    cpu.x[self.operands.rd as usize] = cpu.sign_extend(rotated);
}
```

*NO INLINE SEQUENCE FOUND*

## amoxord.rs
> **AMOXORD (Atomic Memory Operation XOR Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, XORs it with rs2, stores the result back, and places the original value in rd.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = AMOXORD,
    mask   = 0xf800707f,
    match  = 0x2000302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOXORD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let xor_value = cpu.x[self.operands.rs2 as usize] as u64;
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = (original_value as u64) ^ xor_value;
    cpu.mmu.store_doubleword(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs2 = allocator.allocate();
    let v_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_r::<XOR>(*v_rs2, *v_rd, self.operands.rs2);
    asm.emit_s::<SD>(self.operands.rs1, *v_rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## virtual_rev8w.rs
> **VirtualRev8W (Virtual Reverse Bytes Word):** Emulator-internal instruction that reverses the byte order within each 32-bit word of the 64-bit value in rs1. Only valid in 64-bit mode.

```rust
declare_riscv_instr!(
    name = VirtualRev8W,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualRev8W as RISCVInstruction>::RAMAccess) {
    match cpu.xlen {
        Xlen::Bit64 => {
            let v = cpu.x[self.operands.rs1 as usize] as u64;
            cpu.x[self.operands.rd as usize] = rev8w(v) as i64;
        }
        Xlen::Bit32 => unimplemented!(),
    }
}
```

*NO INLINE SEQUENCE FOUND*

## bne.rs
> **BNE (Branch if Not Equal):** Compares registers rs1 and rs2; if not equal, branches to PC + immediate offset.

```rust
declare_riscv_instr!(
    name   = BNE,
    mask   = 0x0000707f,
    match  = 0x00001063,
    format = FormatB,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <BNE as RISCVInstruction>::RAMAccess) {
    if cpu.sign_extend(cpu.x[self.operands.rs1 as usize])
        != cpu.sign_extend(cpu.x[self.operands.rs2 as usize])
    {
        cpu.pc = (self.address as i64 + self.operands.imm as i64) as u64;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## divw.rs
> **DIVW (Divide Word):** Divides the lower 32 bits of rs1 by rs2 as signed values, sign-extending the 32-bit quotient into rd. Returns -1 on division by zero and handles signed overflow.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = DIVW,
    mask   = 0xfe00707f,
    match  = 0x200403b,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <DIVW as RISCVInstruction>::RAMAccess) {
    let dividend = cpu.x[self.operands.rs1 as usize] as i32;
    let divisor = cpu.x[self.operands.rs2 as usize] as i32;
    cpu.x[self.operands.rd as usize] = (if divisor == 0 {
        -1i32
    } else if dividend == i32::MIN && divisor == -1 {
        dividend
    } else {
        dividend.wrapping_div(divisor)
    }) as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let a0 = self.operands.rs1;
    let a1 = self.operands.rs2;
    let a2 = allocator.allocate();
    let a3 = allocator.allocate();
    let t0 = allocator.allocate();
    let t1 = allocator.allocate();
    let t2 = allocator.allocate();
    let t3 = allocator.allocate();
    let t4 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_j::<VirtualAdvice>(*a2, 0);
    asm.emit_j::<VirtualAdvice>(*a3, 0);
    asm.emit_i::<VirtualSignExtendWord>(*t4, a0, 0);
    asm.emit_i::<VirtualSignExtendWord>(*t3, a1, 0);
    asm.emit_b::<VirtualAssertValidDiv0>(*t3, *a2, 0);
    asm.emit_r::<VirtualChangeDivisorW>(*t0, *t4, *t3);
    asm.emit_i::<VirtualSignExtendWord>(*t1, *a2, 0);
    asm.emit_b::<VirtualAssertEQ>(*t1, *a2, 0);
    asm.emit_i::<SRAI>(*t2, *a3, 31);
    asm.emit_b::<VirtualAssertEQ>(*t2, 0, 0);
    asm.emit_i::<SRAI>(*t2, *t4, 31);
    asm.emit_r::<XOR>(*t3, *a3, *t2);
    asm.emit_r::<SUB>(*t3, *t3, *t2);
    asm.emit_r::<MUL>(*t1, *a2, *t0);
    asm.emit_r::<ADD>(*t1, *t1, *t3);
    asm.emit_b::<VirtualAssertEQ>(*t1, *t4, 0);
    asm.emit_i::<SRAI>(*t2, *t0, 31);
    asm.emit_r::<XOR>(*t1, *t0, *t2);
    asm.emit_r::<SUB>(*t1, *t1, *t2);
    asm.emit_b::<VirtualAssertValidUnsignedRemainder>(*a3, *t1, 0);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, *a2, 0);
    asm.finalize()
}
```

## virtual_srai.rs
> **VirtualSRAI (Virtual Shift Right Arithmetic Immediate):** Emulator-internal instruction that performs an arithmetic right shift of rs1 by the shift amount encoded in the trailing zeros of the immediate operand.

```rust
declare_riscv_instr!(
    name = VirtualSRAI,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualSRAI as RISCVInstruction>::RAMAccess) {
    let shift = self.operands.imm.trailing_zeros();
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(cpu.x[self.operands.rs1 as usize].wrapping_shr(shift));
}
```

*NO INLINE SEQUENCE FOUND*

## div.rs

- [x] DONE:  
> **DIV (Divide):** Divides rs1 by rs2 as signed values and stores the quotient in rd. Returns -1 on division by zero and handles signed overflow.

```rust
declare_riscv_instr!(
    name   = DIV,
    mask   = 0xfe00707f,
    match  = 0x02004033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <DIV as RISCVInstruction>::RAMAccess) {
    let dividend = cpu.x[self.operands.rs1 as usize];
    let divisor = cpu.x[self.operands.rs2 as usize];
    if divisor == 0 {
        cpu.x[self.operands.rd as usize] = -1;
    } else if dividend == cpu.most_negative() && divisor == -1 {
        cpu.x[self.operands.rd as usize] = dividend;
    } else {
        cpu.x[self.operands.rd as usize] = cpu
            .sign_extend(dividend.wrapping_div(divisor))
    }
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let a0 = self.operands.rs1;
    let a1 = self.operands.rs2;
    let a2 = allocator.allocate();
    let a3 = allocator.allocate();
    let t0 = allocator.allocate();
    let t1 = allocator.allocate();
    let shmat = match xlen {
        Xlen::Bit32 => 31,
        Xlen::Bit64 => 63,
    };
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_j::<VirtualAdvice>(*a2, 0);
    asm.emit_j::<VirtualAdvice>(*a3, 0);
    asm.emit_b::<VirtualAssertValidDiv0>(a1, *a2, 0);
    asm.emit_r::<VirtualChangeDivisor>(*t0, a0, a1);
    asm.emit_r::<MULH>(*t1, *a2, *t0);
    let t2 = allocator.allocate();
    let t3 = allocator.allocate();
    asm.emit_r::<MUL>(*t2, *a2, *t0);
    asm.emit_i::<SRAI>(*t3, *t2, shmat);
    asm.emit_b::<VirtualAssertEQ>(*t1, *t3, 0);
    asm.emit_i::<SRAI>(*t1, a0, shmat);
    asm.emit_r::<XOR>(*t3, *a3, *t1);
    asm.emit_r::<SUB>(*t3, *t3, *t1);
    asm.emit_r::<ADD>(*t2, *t2, *t3);
    asm.emit_b::<VirtualAssertEQ>(*t2, a0, 0);
    asm.emit_i::<SRAI>(*t1, *t0, shmat);
    asm.emit_r::<XOR>(*t3, *t0, *t1);
    asm.emit_r::<SUB>(*t3, *t3, *t1);
    asm.emit_b::<VirtualAssertValidUnsignedRemainder>(*a3, *t3, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *a2, 0);
    asm.finalize()
}
```

## amominw.rs
> **AMOMINW (Atomic Memory Operation MIN Word):** Atomically loads a 32-bit word from the address in rs1, stores the signed minimum of it and rs2, and places the original value in rd.

* [ ] TODO: 

```rust
declare_riscv_instr!(
    name   = AMOMINW,
    mask   = 0xf800707f,
    match  = 0x8000202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOMINW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let compare_value = cpu.x[self.operands.rs2 as usize] as i32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = if original_value as i32 <= compare_value {
        original_value as i32
    } else {
        compare_value
    };
    cpu.mmu.store_word(address, new_value as u32).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    match xlen {
        Xlen::Bit32 => {
            let v_rd = allocator.allocate();
            let v_rs2 = allocator.allocate();
            let v_sel_rs2 = allocator.allocate();
            let v_sel_rd = allocator.allocate();
            amo_pre32(&mut asm, self.operands.rs1, *v_rd);
            asm.emit_r::<SLT>(*v_sel_rs2, self.operands.rs2, *v_rd);
            asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
            asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
            asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
            amo_post32(&mut asm, *v_rs2, self.operands.rs1, self.operands.rd, *v_rd);
        }
        Xlen::Bit64 => {
            let v_rd = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            amo_pre64(&mut asm, self.operands.rs1, *v_rd, *v_dword, *v_shift);
            let v_rs2 = allocator.allocate();
            let v_sel_rs2 = allocator.allocate();
            let v_sel_rd = allocator.allocate();
            let v_mask = allocator.allocate();
            asm.emit_i::<VirtualSignExtendWord>(*v_rs2, self.operands.rs2, 0);
            asm.emit_i::<VirtualSignExtendWord>(*v_sel_rd, *v_rd, 0);
            asm.emit_r::<SLT>(*v_sel_rs2, *v_rs2, *v_sel_rd);
            asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
            asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
            asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
            drop(v_sel_rd);
            drop(v_sel_rs2);
            amo_post64(
                &mut asm,
                self.operands.rs1,
                *v_rs2,
                *v_dword,
                *v_shift,
                *v_mask,
                self.operands.rd,
                *v_rd,
            );
        }
    }
    asm.finalize()
}
```

## amominud.rs
> **AMOMINUD (Atomic Memory Operation MIN Unsigned Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, stores the unsigned minimum of it and rs2, and places the original value in rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = AMOMINUD,
    mask   = 0xf800707f,
    match  = 0xc000302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOMINUD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let compare_value = cpu.x[self.operands.rs2 as usize] as u64;
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = if (original_value as u64) <= compare_value {
        original_value as u64
    } else {
        compare_value
    };
    cpu.mmu.store_doubleword(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs2 = allocator.allocate();
    let v_rd = allocator.allocate();
    let v_sel_rs2 = allocator.allocate();
    let v_sel_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_r::<SLTU>(*v_sel_rs2, self.operands.rs2, *v_rd);
    asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
    asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
    asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
    asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
    asm.emit_s::<SD>(self.operands.rs1, *v_rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## andn.rs
> **ANDN (AND with NOT):** Computes the bitwise AND of rs1 and the bitwise NOT of rs2, storing the result in rd. Part of the Zbb bit-manipulation extension.

```rust
declare_riscv_instr!(
    name   = ANDN,
    mask   = 0xfe00707f,
    match  = 0x40007033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <ANDN as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize] & !cpu.x[self.operands.rs2 as usize],
        );
}
```

*NO INLINE SEQUENCE FOUND*

## amoaddw.rs
> **AMOADDW (Atomic Memory Operation ADD Word):** Atomically loads a 32-bit word from the address in rs1, adds rs2, stores the sum back, and places the original value in rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = AMOADDW,
    mask   = 0xf800707f,
    match  = 0x0000202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOADDW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let add_value = cpu.x[self.operands.rs2 as usize] as i32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = (original_value as i32).wrapping_add(add_value) as u32;
    cpu.mmu.store_word(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rd = allocator.allocate();
    let v_rs2 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    match xlen {
        Xlen::Bit32 => {
            amo_pre32(&mut asm, self.operands.rs1, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_rd, self.operands.rs2);
            amo_post32(&mut asm, *v_rs2, self.operands.rs1, self.operands.rd, *v_rd);
        }
        Xlen::Bit64 => {
            let v_mask = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            amo_pre64(&mut asm, self.operands.rs1, *v_rd, *v_dword, *v_shift);
            asm.emit_r::<ADD>(*v_rs2, *v_rd, self.operands.rs2);
            amo_post64(
                &mut asm,
                self.operands.rs1,
                *v_rs2,
                *v_dword,
                *v_shift,
                *v_mask,
                self.operands.rd,
                *v_rd,
            );
        }
    }
    asm.finalize()
}
```

## lrd.rs
> **LRD (Load Reserved Doubleword):** Loads a 64-bit doubleword from the address in rs1 into rd and sets a memory reservation for atomic operations.

```rust
declare_riscv_instr!(
    name   = LRD,
    mask   = 0xf9f0707f,
    match  = 0x1000302f,
    format = FormatR,
    ram    = RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LRD as RISCVInstruction>::RAMAccess) {
    if cpu.is_reservation_set() {
        println!("LRD: Reservation is already set");
    }
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let value = cpu.mmu.load_doubleword(address);
    cpu.x[self.operands.rd as usize] = match value {
        Ok((doubleword, memory_read)) => {
            *ram_access = memory_read;
            cpu.set_reservation(address);
            doubleword as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

*NO INLINE SEQUENCE FOUND*

## slliw.rs
> **SLLIW (Shift Left Logical Immediate Word):** Shifts the lower 32 bits of rs1 left by the immediate amount (masked to 5 bits), sign-extending the 32-bit result into rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = SLLIW,
    mask   = 0xfc00707f,
    match  = 0x0000101b,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SLLIW as RISCVInstruction>::RAMAccess) {
    let shamt = (self.operands.imm & 0x1f) as u32;
    cpu.x[self.operands.rd as usize] = ((cpu.x[self.operands.rs1 as usize] as u32)
        << shamt) as i32 as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mask = match xlen {
        Xlen::Bit32 => panic!("SLLIW is invalid in 32b mode"),
        Xlen::Bit64 => 0x1f,
    };
    let shift = self.operands.imm & mask;
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualMULI>(self.operands.rd, self.operands.rs1, 1 << shift);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## amomaxud.rs
> **AMOMAXUD (Atomic Memory Operation MAX Unsigned Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, stores the unsigned maximum of it and rs2, and places the original value in rd.
 TODO:
```rust
declare_riscv_instr!(
    name   = AMOMAXUD,
    mask   = 0xf800707f,
    match  = 0xe000302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOMAXUD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let compare_value = cpu.x[self.operands.rs2 as usize] as u64;
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = if (original_value as u64) >= compare_value {
        original_value as u64
    } else {
        compare_value
    };
    cpu.mmu.store_doubleword(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs2 = allocator.allocate();
    let v_rd = allocator.allocate();
    let v_sel_rs2 = allocator.allocate();
    let v_sel_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_r::<SLTU>(*v_sel_rs2, *v_rd, self.operands.rs2);
    asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
    asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
    asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
    asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
    asm.emit_s::<SD>(self.operands.rs1, *v_rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## amoandd.rs
> **AMOANDD (Atomic Memory Operation AND Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, ANDs it with rs2, stores the result back, and places the original value in rd.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = AMOANDD,
    mask   = 0xf800707f,
    match  = 0x6000302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOANDD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let and_value = cpu.x[self.operands.rs2 as usize] as u64;
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = (original_value as u64) & and_value;
    cpu.mmu.store_doubleword(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs2 = allocator.allocate();
    let v_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_r::<AND>(*v_rs2, *v_rd, self.operands.rs2);
    asm.emit_s::<SD>(self.operands.rs1, *v_rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## virtual_assert_valid_unsigned_remainder.rs
> **VirtualAssertValidUnsignedRemainder (Assert Valid Unsigned Remainder):** Emulator-internal assertion that verifies the unsigned remainder (rs1) is less than the unsigned divisor (rs2), or that the divisor is zero.

```rust
declare_riscv_instr!(
    name = VirtualAssertValidUnsignedRemainder,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualAssertValidUnsignedRemainder as RISCVInstruction>::RAMAccess,
) {
    match cpu.xlen {
        Xlen::Bit32 => {
            let remainder = cpu.x[self.operands.rs1 as usize] as i32 as u32;
            let divisor = cpu.x[self.operands.rs2 as usize] as i32 as u32;
            assert!(divisor == 0 || remainder < divisor);
        }
        Xlen::Bit64 => {
            let remainder = cpu.x[self.operands.rs1 as usize] as u64;
            let divisor = cpu.x[self.operands.rs2 as usize] as u64;
            assert!(divisor == 0 || remainder < divisor);
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_change_divisor.rs
> **VirtualChangeDivisor (Change Divisor):** Emulator-internal instruction that adjusts the divisor to handle the signed overflow case where dividend is the most negative value and divisor is -1, replacing the divisor with 1.

```rust
declare_riscv_instr!(
    name = VirtualChangeDivisor,
    mask = 0,
    match = 0,
    format = FormatR,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualChangeDivisor as RISCVInstruction>::RAMAccess,
) {
    match cpu.xlen {
        Xlen::Bit32 => {
            let dividend = cpu.x[self.operands.rs1 as usize] as i32;
            let divisor = cpu.x[self.operands.rs2 as usize] as i32;
            if dividend == i32::MIN && divisor == -1 {
                cpu.x[self.operands.rd as usize] = 1;
            } else {
                cpu.x[self.operands.rd as usize] = divisor as i64;
            }
        }
        Xlen::Bit64 => {
            let dividend = cpu.x[self.operands.rs1 as usize];
            let divisor = cpu.x[self.operands.rs2 as usize];
            if dividend == i64::MIN && divisor == -1 {
                cpu.x[self.operands.rd as usize] = 1;
            } else {
                cpu.x[self.operands.rd as usize] = divisor;
            }
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## ld.rs
> **LD (Load Doubleword):** Loads a 64-bit doubleword from memory at rs1 + offset into rd.

```rust
declare_riscv_instr!(
    name   = LD,
    mask   = 0x0000707f,
    match  = 0x00003003,
    format = FormatLoad,
    ram    = super::RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LD as RISCVInstruction>::RAMAccess) {
    let address = (cpu.x[self.operands.rs1 as usize] as u64)
        .wrapping_add(self.operands.imm as i32 as u64);
    let value = cpu.get_mut_mmu().load_doubleword(address);
    cpu.x[self.operands.rd as usize] = match value {
        Ok((value, memory_read)) => {
            *ram_access = memory_read;
            value as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

*NO INLINE SEQUENCE FOUND*

## scw.rs
> **SCW (Store Conditional Word):** Conditionally stores a 32-bit word from rs2 to the address in rs1 if a prior load-reserved reservation is still valid. Writes 0 to rd on success, 1 on failure.

```rust
declare_riscv_instr!(
    name   = SCW,
    mask   = 0xf800707f,
    match  = 0x1800202f,
    format = FormatR,
    ram    = RAMWrite
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <SCW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let value = cpu.x[self.operands.rs2 as usize] as u32;
    if cpu.has_reservation(address) {
        let result = cpu.mmu.store_word(address, value);
        match result {
            Ok(memory_write) => {
                *ram_access = memory_write;
                cpu.clear_reservation();
                cpu.x[self.operands.rd as usize] = 0;
            }
            Err(_) => panic!("MMU store error"),
        }
    } else {
        cpu.x[self.operands.rd as usize] = 1;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## slt.rs
> **SLT (Set Less Than):** Sets rd to 1 if the signed value in rs1 is less than the signed value in rs2, otherwise sets rd to 0.

```rust
declare_riscv_instr!(
    name   = SLT,
    mask   = 0xfe00707f,
    match  = 0x00002033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SLT as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu.x[self.operands.rs1 as usize]
        < cpu.x[self.operands.rs2 as usize]
    {
        true => 1,
        false => 0,
    };
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_movsign.rs
> **VirtualMovsign (Move Sign):** Emulator-internal instruction that extracts the sign of rs1: stores all-ones if rs1 is negative, or zero if rs1 is non-negative.

```rust
declare_riscv_instr!(
    name = VirtualMovsign,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualMovsign as RISCVInstruction>::RAMAccess) {
    let val = cpu.x[self.operands.rs1 as usize] as u64;
    cpu.x[self.operands.rd as usize] = match cpu.xlen {
        Xlen::Bit32 => if val & SIGN_BIT_32 != 0 { ALL_ONES_32 as i64 } else { 0 }
        Xlen::Bit64 => if val & SIGN_BIT_64 != 0 { ALL_ONES_64 as i64 } else { 0 }
    };
}
```

*NO INLINE SEQUENCE FOUND*

## mulh.rs
> **MULH (Multiply High Signed):** Computes the upper half of the signed product of rs1 and rs2, storing the high bits in rd.
 NEXT:
```rust
declare_riscv_instr!(
    name   = MULH,
    mask   = 0xfe00707f,
    match  = 0x02001033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <MULH as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu.xlen {
        Xlen::Bit32 => {
            cpu.sign_extend(
                (cpu.x[self.operands.rs1 as usize] * cpu.x[self.operands.rs2 as usize])
                    >> 32,
            )
        }
        Xlen::Bit64 => {
            (((cpu.x[self.operands.rs1 as usize] as i128)
                * (cpu.x[self.operands.rs2 as usize] as i128)) >> 64) as i64
        }
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_sx = allocator.allocate();
    let v_sy = allocator.allocate();
    let v_0 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualMovsign>(*v_sx, self.operands.rs1, 0);
    asm.emit_i::<VirtualMovsign>(*v_sy, self.operands.rs2, 0);
    asm.emit_r::<MULHU>(*v_0, self.operands.rs1, self.operands.rs2);
    asm.emit_r::<MUL>(*v_sx, *v_sx, self.operands.rs2);
    asm.emit_r::<MUL>(*v_sy, *v_sy, self.operands.rs1);
    asm.emit_r::<ADD>(*v_0, *v_0, *v_sx);
    asm.emit_r::<ADD>(self.operands.rd, *v_0, *v_sy);
    asm.finalize()
}
```

## sll.rs
> **SLL (Shift Left Logical):** Shifts rs1 left by the shift amount in rs2 (masked to log2(XLEN) bits) and stores the result in rd.
TODO:
```rust
declare_riscv_instr!(
    name   = SLL,
    mask   = 0xfe00707f,
    match  = 0x00001033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SLL as RISCVInstruction>::RAMAccess) {
    let mask = match cpu.xlen {
        Xlen::Bit32 => 0x1f,
        Xlen::Bit64 => 0x3f,
    };
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .x[self.operands.rs1 as usize]
                .wrapping_shl(cpu.x[self.operands.rs2 as usize] as u32 & mask),
        );
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_pow2 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualPow2>(*v_pow2, self.operands.rs2, 0);
    asm.emit_r::<MUL>(self.operands.rd, self.operands.rs1, *v_pow2);
    asm.finalize()
}
```

## sraw.rs
> **SRAW (Shift Right Arithmetic Word):** Arithmetically shifts the lower 32 bits of rs1 right by the amount in rs2 (masked to 5 bits), sign-extending the 32-bit result into rd.
TODO:
```rust
declare_riscv_instr!(
    name   = SRAW,
    mask   = 0xfe00707f,
    match  = 0x4000003b | (0b101 << 12),
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SRAW as RISCVInstruction>::RAMAccess) {
    let shamt = (cpu.x[self.operands.rs2 as usize] & 0x1f) as u32;
    cpu.x[self.operands.rd as usize] = ((cpu.x[self.operands.rs1 as usize] as i32)
        >> shamt) as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs1 = allocator.allocate();
    let v_bitmask = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualSignExtendWord>(*v_rs1, self.operands.rs1, 0);
    asm.emit_i::<ANDI>(*v_bitmask, self.operands.rs2, 0x1f);
    asm.emit_i::<VirtualShiftRightBitmask>(*v_bitmask, *v_bitmask, 0);
    asm.emit_vshift_r::<VirtualSRA>(self.operands.rd, *v_rs1, *v_bitmask);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## virtual_sw.rs
> **VirtualSW (Virtual Store Word):** Emulator-internal instruction that stores a 32-bit word from rs2 to memory at rs1 + offset. Only valid in 32-bit mode.

```rust
declare_riscv_instr!(
    name = VirtualSW,
    mask = 0,
    match = 0,
    format = FormatS,
    ram    = super::RAMWrite
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    ram_access: &mut <VirtualSW as RISCVInstruction>::RAMAccess,
) {
    assert_eq!(cpu.xlen, Xlen::Bit32);
    *ram_access = cpu
        .mmu
        .store_word(
            cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64,
            cpu.x[self.operands.rs2 as usize] as u32,
        )
        .ok()
        .unwrap();
}
```

*NO INLINE SEQUENCE FOUND*

## addiw.rs
> **ADDIW (Add Immediate Word):** Adds a sign-extended 12-bit immediate to rs1, truncates the result to 32 bits, and sign-extends it into rd.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = ADDIW,
    mask   = 0x0000707f,
    match  = 0x0000001b,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <ADDIW as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .x[self.operands.rs1 as usize]
        .wrapping_add(normalize_imm(self.operands.imm, &cpu.xlen)) as i32 as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<ADDI>(self.operands.rd, self.operands.rs1, self.operands.imm);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## sb.rs
> **SB (Store Byte):** Stores the lowest 8 bits of rs2 to memory at the address rs1 + offset.
TODO:
```rust
declare_riscv_instr!(
    name   = SB,
    mask   = 0x0000707f,
    match  = 0x00000023,
    format = FormatS,
    ram    = RAMWrite
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <SB as RISCVInstruction>::RAMAccess) {
    *ram_access = cpu
        .mmu
        .store(
            cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64,
            cpu.x[self.operands.rs2 as usize] as u8,
        )
        .ok()
        .unwrap();
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => self.inline_sequence_32(allocator),
        Xlen::Bit64 => self.inline_sequence_64(allocator),
    }
}
```

```rust
fn inline_sequence_32(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_word_address = allocator.allocate();
    let v_word = allocator.allocate();
    let v_shift = allocator.allocate();
    let v_mask = allocator.allocate();
    let v_byte = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit32,
        allocator,
    );
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_word_address, *v_address, -4i64 as u64);
    asm.emit_i::<VirtualLW>(*v_word, *v_word_address, 0);
    asm.emit_i::<SLLI>(*v_shift, *v_address, 3);
    asm.emit_u::<LUI>(*v_mask, 0xff);
    asm.emit_r::<SLL>(*v_mask, *v_mask, *v_shift);
    asm.emit_r::<SLL>(*v_byte, self.operands.rs2, *v_shift);
    asm.emit_r::<XOR>(*v_byte, *v_word, *v_byte);
    asm.emit_r::<AND>(*v_byte, *v_byte, *v_mask);
    asm.emit_r::<XOR>(*v_word, *v_word, *v_byte);
    asm.emit_s::<VirtualSW>(*v_word_address, *v_word, 0);
    asm.finalize()
}
```

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let v_mask = allocator.allocate();
    let v_byte = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<SLLI>(*v_shift, *v_address, 3);
    asm.emit_u::<LUI>(*v_mask, 0xff);
    asm.emit_r::<SLL>(*v_mask, *v_mask, *v_shift);
    asm.emit_r::<SLL>(*v_byte, self.operands.rs2, *v_shift);
    asm.emit_r::<XOR>(*v_byte, *v_dword, *v_byte);
    asm.emit_r::<AND>(*v_byte, *v_byte, *v_mask);
    asm.emit_r::<XOR>(*v_dword, *v_dword, *v_byte);
    asm.emit_s::<SD>(*v_dword_address, *v_dword, 0);
    asm.finalize()
}
```

## virtual_srl.rs
> **VirtualSRL (Virtual Shift Right Logical Register):** Emulator-internal instruction that performs a logical right shift of rs1 by the shift amount encoded in the trailing zeros of rs2.
> **Description**: Logical right shift on the value in register `rs1` by the shift amount held in the lower 5 bits of register `rs2`

```rust
declare_riscv_instr!(
    name = VirtualSRL,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftR,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualSRL as RISCVInstruction>::RAMAccess) {
    let shift = cpu.x[self.operands.rs2 as usize].trailing_zeros();
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.unsigned_data(cpu.x[self.operands.rs1 as usize]).wrapping_shr(shift)
                as i64,
        );
}
```

*NO INLINE SEQUENCE FOUND*

## mulhsu.rs
> **MULHSU (Multiply High Signed-Unsigned):** Computes the upper half of the product of rs1 (signed) and rs2 (unsigned), storing the high bits in rd.
TODO:
```rust
declare_riscv_instr!(
    name   = MULHSU,
    mask   = 0xfe00707f,
    match  = 0x02002033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <MULHSU as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu.xlen {
        Xlen::Bit32 => {
            cpu.sign_extend(
                cpu
                    .x[self.operands.rs1 as usize]
                    .wrapping_mul(cpu.x[self.operands.rs2 as usize] as u32 as i64) >> 32,
            )
        }
        Xlen::Bit64 => {
            ((cpu.x[self.operands.rs1 as usize] as u128)
                .wrapping_mul(cpu.x[self.operands.rs2 as usize] as u64 as u128) >> 64)
                as i64
        }
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_sx = allocator.allocate();
    let v_sx_0 = allocator.allocate();
    let v_rs1 = allocator.allocate();
    let v_hi = allocator.allocate();
    let v_lo = allocator.allocate();
    let v_tmp = allocator.allocate();
    let v_carry = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualMovsign>(*v_sx, self.operands.rs1, 0);
    asm.emit_i::<ANDI>(*v_sx_0, *v_sx, 1);
    asm.emit_r::<XOR>(*v_rs1, self.operands.rs1, *v_sx);
    asm.emit_r::<ADD>(*v_rs1, *v_rs1, *v_sx_0);
    asm.emit_r::<MULHU>(*v_hi, *v_rs1, self.operands.rs2);
    asm.emit_r::<MUL>(*v_lo, *v_rs1, self.operands.rs2);
    asm.emit_r::<XOR>(*v_hi, *v_hi, *v_sx);
    asm.emit_r::<XOR>(*v_lo, *v_lo, *v_sx);
    asm.emit_r::<ADD>(*v_tmp, *v_lo, *v_sx_0);
    asm.emit_r::<SLTU>(*v_carry, *v_tmp, *v_lo);
    asm.emit_r::<ADD>(self.operands.rd, *v_hi, *v_carry);
    asm.finalize()
}
```

## virtual_pow2i.rs
> **VirtualPow2I (Virtual Power of 2 Immediate):** Emulator-internal instruction that computes 2 raised to the power of (imm mod XLEN) and stores the result in rd.

```rust
declare_riscv_instr!(
    name = VirtualPow2I,
    mask = 0,
    match = 0,
    format = FormatJ,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualPow2I as RISCVInstruction>::RAMAccess) {
    match cpu.xlen {
        Xlen::Bit32 => cpu.x[self.operands.rd as usize] = 1 << (self.operands.imm % 32),
        Xlen::Bit64 => cpu.x[self.operands.rd as usize] = 1 << (self.operands.imm % 64),
    }
}
```

*NO INLINE SEQUENCE FOUND*

## divu.rs
> **DIVU (Divide Unsigned):** Divides rs1 by rs2 as unsigned values and stores the quotient in rd. Returns all-ones (-1) on division by zero.
TODO:
```rust
declare_riscv_instr!(
    name   = DIVU,
    mask   = 0xfe00707f,
    match  = 0x02005033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <DIVU as RISCVInstruction>::RAMAccess) {
    let dividend = cpu.unsigned_data(cpu.x[self.operands.rs1 as usize]);
    let divisor = cpu.unsigned_data(cpu.x[self.operands.rs2 as usize]);
    if divisor == 0 {
        cpu.x[self.operands.rd as usize] = -1;
    } else {
        cpu.x[self.operands.rd as usize] = cpu
            .sign_extend(dividend.wrapping_div(divisor) as i64)
    }
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let a0 = self.operands.rs1;
    let a1 = self.operands.rs2;
    let a2 = allocator.allocate();
    let a3 = allocator.allocate();
    let t0 = allocator.allocate();
    let t1 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_j::<VirtualAdvice>(*a2, 0);
    asm.emit_j::<VirtualAdvice>(*a3, 0);
    asm.emit_b::<VirtualAssertValidDiv0>(a1, *a2, 0);
    asm.emit_b::<VirtualAssertMulUNoOverflow>(*a2, a1, 0);
    asm.emit_r::<MUL>(*t0, *a2, a1);
    asm.emit_r::<ADD>(*t1, *t0, *a3);
    asm.emit_b::<VirtualAssertLTE>(*t0, *t1, 0);
    asm.emit_b::<VirtualAssertLTE>(*a3, *t1, 0);
    asm.emit_b::<VirtualAssertEQ>(*t1, a0, 0);
    asm.emit_b::<VirtualAssertValidUnsignedRemainder>(*a3, a1, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *a2, 0);
    asm.finalize()
}
```

## srlw.rs
> **SRLW (Shift Right Logical Word):** Logically shifts the lower 32 bits of rs1 right by the amount in rs2 (masked to 5 bits), sign-extending the 32-bit result into rd.
TODO:
```rust
declare_riscv_instr!(
    name   = SRLW,
    mask   = 0xfe00707f,
    match  = 0x0000003b | (0b101 << 12),
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SRLW as RISCVInstruction>::RAMAccess) {
    let shamt = (cpu.x[self.operands.rs2 as usize] & 0x1f) as u32;
    cpu.x[self.operands.rd as usize] = ((cpu.x[self.operands.rs1 as usize] as u32)
        >> shamt) as i32 as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_bitmask = allocator.allocate();
    let v_rs1 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<SLLI>(*v_rs1, self.operands.rs1, 32);
    asm.emit_i::<ORI>(*v_bitmask, self.operands.rs2, 32);
    asm.emit_i::<VirtualShiftRightBitmask>(*v_bitmask, *v_bitmask, 0);
    asm.emit_vshift_r::<VirtualSRL>(self.operands.rd, *v_rs1, *v_bitmask);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## mulw.rs
> **MULW (Multiply Word):** Multiplies the lower 32 bits of rs1 and rs2, sign-extending the 32-bit product into rd.
TODO:
```rust
declare_riscv_instr!(
    name   = MULW,
    mask   = 0xfe00707f,
    match  = 0x0200003b,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <MULW as RISCVInstruction>::RAMAccess) {
    let a = cpu.x[self.operands.rs1 as usize] as i32;
    let b = cpu.x[self.operands.rs2 as usize] as i32;
    cpu.x[self.operands.rd as usize] = a.wrapping_mul(b) as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_r::<MUL>(self.operands.rd, self.operands.rs1, self.operands.rs2);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## xori.rs
> **XORI (XOR Immediate):** Computes the bitwise XOR of rs1 and a sign-extended 12-bit immediate, storing the result in rd.

```rust
declare_riscv_instr!(
    name   = XORI,
    mask   = 0x0000707f,
    match  = 0x00004013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <XORI as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize]
                ^ normalize_imm(self.operands.imm, &cpu.xlen),
        );
}
```

*NO INLINE SEQUENCE FOUND*

## remuw.rs
> **REMUW (Remainder Unsigned Word):** Computes the unsigned remainder of the lower 32 bits of rs1 divided by rs2, sign-extending the 32-bit result into rd. Returns the dividend if the divisor is zero.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = REMUW,
    mask   = 0xfe00707f,
    match  = 0x200703b,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <REMUW as RISCVInstruction>::RAMAccess) {
    let dividend = cpu.x[self.operands.rs1 as usize] as u32;
    let divisor = cpu.x[self.operands.rs2 as usize] as u32;
    cpu.x[self.operands.rd as usize] = (if divisor == 0 {
        dividend
    } else {
        dividend.wrapping_rem(divisor)
    }) as i32 as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let a0 = self.operands.rs1;
    let a1 = self.operands.rs2;
    let a2 = allocator.allocate();
    let a3 = allocator.allocate();
    let t0 = allocator.allocate();
    let t1 = allocator.allocate();
    let t2 = allocator.allocate();
    let t3 = allocator.allocate();
    let t4 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_j::<VirtualAdvice>(*a2, 0);
    asm.emit_j::<VirtualAdvice>(*a3, 0);
    asm.emit_i::<VirtualZeroExtendWord>(*t3, *a2, 0);
    asm.emit_i::<VirtualZeroExtendWord>(*t1, a0, 0);
    asm.emit_i::<VirtualZeroExtendWord>(*t2, a1, 0);
    asm.emit_r::<MUL>(*t0, *t3, *t2);
    asm.emit_i::<VirtualZeroExtendWord>(*t4, *t0, 0);
    asm.emit_b::<VirtualAssertEQ>(*t4, *t0, 0);
    asm.emit_r::<ADD>(*t0, *t0, *a3);
    asm.emit_b::<VirtualAssertEQ>(*t0, *t1, 0);
    asm.emit_b::<VirtualAssertValidUnsignedRemainder>(*a3, *t2, 0);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, *a3, 0);
    asm.finalize()
}
```

## virtual_pow2i_w.rs
> **VirtualPow2IW (Virtual Power of 2 Immediate Word):** Emulator-internal instruction that computes 2 raised to the power of (imm mod 32) and stores the result in rd. Only valid in 64-bit mode.

```rust
declare_riscv_instr!(
    name = VirtualPow2IW,
    mask = 0,
    match = 0,
    format = FormatJ,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualPow2IW as RISCVInstruction>::RAMAccess) {
    match cpu.xlen {
        Xlen::Bit32 => panic!("VirtualPow2IW is invalid in 32b mode"),
        Xlen::Bit64 => cpu.x[self.operands.rd as usize] = 1 << (self.operands.imm % 32),
    }
}
```

*NO INLINE SEQUENCE FOUND*

## sltiu.rs
> **SLTIU (Set Less Than Immediate Unsigned):** Sets rd to 1 if the unsigned value in rs1 is less than the unsigned sign-extended immediate, otherwise sets rd to 0.

```rust
declare_riscv_instr!(
    name   = SLTIU,
    mask   = 0x0000707f,
    match  = 0x00003013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SLTIU as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu
        .unsigned_data(cpu.x[self.operands.rs1 as usize])
        < cpu.unsigned_data(normalize_imm(self.operands.imm, &cpu.xlen))
    {
        true => 1,
        false => 0,
    };
}
```

*NO INLINE SEQUENCE FOUND*

## and.rs
> **AND (Bitwise AND):** Computes the bitwise AND of rs1 and rs2, storing the result in rd.

```rust
declare_riscv_instr!(
    name   = AND,
    mask   = 0xfe00707f,
    match  = 0x00007033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AND as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize] & cpu.x[self.operands.rs2 as usize],
        );
}
```

*NO INLINE SEQUENCE FOUND*

## bge.rs
> **BGE (Branch if Greater or Equal):** Compares rs1 and rs2 as signed values; if rs1 >= rs2, branches to PC + immediate offset.

```rust
declare_riscv_instr!(
    name   = BGE,
    mask   = 0x0000707f,
    match  = 0x00005063,
    format = FormatB,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <BGE as RISCVInstruction>::RAMAccess) {
    if cpu.sign_extend(cpu.x[self.operands.rs1 as usize])
        >= cpu.sign_extend(cpu.x[self.operands.rs2 as usize])
    {
        cpu.pc = (self.address as i64 + self.operands.imm as i64) as u64;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## amoorw.rs
> **AMOORW (Atomic Memory Operation OR Word):** Atomically loads a 32-bit word from the address in rs1, ORs it with rs2, stores the result back, and places the original value in rd.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = AMOORW,
    mask   = 0xf800707f,
    match  = 0x4000202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOORW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let or_value = cpu.x[self.operands.rs2 as usize] as u32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = (original_value as u32) | or_value;
    cpu.mmu.store_word(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rd = allocator.allocate();
    let v_rs2 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    match xlen {
        Xlen::Bit32 => {
            amo_pre32(&mut asm, self.operands.rs1, *v_rd);
            asm.emit_r::<OR>(*v_rs2, *v_rd, self.operands.rs2);
            amo_post32(&mut asm, *v_rs2, self.operands.rs1, self.operands.rd, *v_rd);
        }
        Xlen::Bit64 => {
            let v_mask = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            amo_pre64(&mut asm, self.operands.rs1, *v_rd, *v_dword, *v_shift);
            asm.emit_r::<OR>(*v_rs2, *v_rd, self.operands.rs2);
            amo_post64(
                &mut asm,
                self.operands.rs1,
                *v_rs2,
                *v_dword,
                *v_shift,
                *v_mask,
                self.operands.rd,
                *v_rd,
            );
        }
    }
    asm.finalize()
}
```

## divuw.rs
> **DIVUW (Divide Unsigned Word):** Divides the lower 32 bits of rs1 by rs2 as unsigned values, sign-extending the 32-bit quotient into rd. Returns u32::MAX on division by zero.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = DIVUW,
    mask   = 0xfe00707f,
    match  = 0x200503b,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <DIVUW as RISCVInstruction>::RAMAccess) {
    let dividend = cpu.x[self.operands.rs1 as usize] as u32;
    let divisor = cpu.x[self.operands.rs2 as usize] as u32;
    cpu.x[self.operands.rd as usize] = (if divisor == 0 {
        u32::MAX
    } else {
        dividend.wrapping_div(divisor)
    }) as i32 as i64;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let a0 = self.operands.rs1;
    let a1 = self.operands.rs2;
    let a2 = allocator.allocate();
    let a3 = allocator.allocate();
    let t0 = allocator.allocate();
    let t1 = allocator.allocate();
    let t2 = allocator.allocate();
    let t3 = allocator.allocate();
    let t4 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_j::<VirtualAdvice>(*a2, 0);
    asm.emit_j::<VirtualAdvice>(*a3, 0);
    asm.emit_i::<VirtualZeroExtendWord>(*t3, a0, 0);
    asm.emit_i::<VirtualZeroExtendWord>(*t4, a1, 0);
    asm.emit_i::<VirtualZeroExtendWord>(*t2, *a2, 0);
    asm.emit_b::<VirtualAssertEQ>(*t2, *a2, 0);
    asm.emit_r::<MUL>(*t0, *t2, *t4);
    asm.emit_i::<VirtualZeroExtendWord>(*t1, *t0, 0);
    asm.emit_b::<VirtualAssertEQ>(*t1, *t0, 0);
    asm.emit_r::<ADD>(*t0, *t0, *a3);
    asm.emit_b::<VirtualAssertEQ>(*t0, *t3, 0);
    asm.emit_b::<VirtualAssertValidUnsignedRemainder>(*a3, *t4, 0);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, *a2, 0);
    asm.emit_b::<VirtualAssertValidDiv0>(*t4, self.operands.rd, 0);
    asm.finalize()
}
```

## jal.rs
> **JAL (Jump and Link):** Jumps to PC + sign-extended immediate offset and stores the return address (next instruction) in rd. Tracks function calls when rd is x1.

```rust
declare_riscv_instr!(
    name   = JAL,
    mask   = 0x0000_007f,
    match  = 0x0000_006f,
    format = FormatJ,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <JAL as RISCVInstruction>::RAMAccess) {
    if self.operands.rd != 0 {
        if self.operands.rd == 1 {
            cpu.track_call(self.address, NormalizedOperands::from(self.operands));
        }
        cpu.x[self.operands.rd as usize] = cpu.sign_extend(cpu.pc as i64);
    }
    cpu.pc = ((self.address as i64)
        .wrapping_add(normalize_imm(self.operands.imm, &cpu.xlen))) as u64;
}
```

*NO INLINE SEQUENCE FOUND*
* [ ] TODO:
## inline.rs
> **INLINE (Inline Instruction Dispatch):** Emulator-internal meta-instruction that dispatches to registered inline sequence builders based on opcode/funct3/funct7 fields. Calling exec() panics; it must use trace() instead.

```rust
declare_riscv_instr!` macro because we need to:
/// Store opcode, funct3 and funct7 fields for dispatch
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq)
```

```rust
fn exec(&self, _cpu: &mut Cpu, _: &mut <INLINE as RISCVInstruction>::RAMAccess) {
    panic!("Inline instructions must use trace(), not exec()");
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let key = (self.opcode, self.funct3, self.funct7);
    match INLINE_REGISTRY.read() {
        Ok(registry) => {
            match registry.get(&key) {
                Some((_, virtual_seq_fn, _)) => {
                    let asm = InstrAssembler::new_inline(
                        self.address,
                        self.is_compressed,
                        xlen,
                        allocator,
                    );
                    virtual_seq_fn(asm, self.operands)
                }
                None => {
                    panic!(
                        "No inline sequence builder registered for inline \
                            with opcode={:#04x}, funct3={:#03b}, funct7={:#09b}. \
                            Register a builder using register_inline().",
                        self.opcode, self.funct3, self.funct7
                    );
                }
            }
        }
        Err(_) => {
            panic!(
                "Failed to acquire read lock on inline registry. \
                    This indicates a critical error in the system."
            );
        }
    }
}
```

## virtual_shift_right_bitmask.rs
> **VirtualShiftRightBitmask (Shift Right Bitmask):** Emulator-internal instruction that generates a bitmask for right-shift operations based on the shift amount in rs1, producing a mask with ones in the upper bits.

```rust
declare_riscv_instr!(
    name = VirtualShiftRightBitmask,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualShiftRightBitmask as RISCVInstruction>::RAMAccess,
) {
    match cpu.xlen {
        Xlen::Bit32 => {
            let shift = cpu.x[self.operands.rs1 as usize] as u64 & 0x1F;
            let ones = (1u64 << (32 - shift)) - 1;
            cpu.x[self.operands.rd as usize] = (ones << shift) as i64;
        }
        Xlen::Bit64 => {
            let shift = cpu.x[self.operands.rs1 as usize] as u64 & 0x3F;
            let ones = (1u128 << (64 - shift)) - 1;
            cpu.x[self.operands.rd as usize] = (ones << shift) as i64;
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_assert_lte.rs
> **VirtualAssertLTE (Assert Less Than or Equal):** Emulator-internal assertion that verifies rs1 (unsigned) is less than or equal to rs2 (unsigned).

```rust
declare_riscv_instr!(
    name = VirtualAssertLTE,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualAssertLTE as RISCVInstruction>::RAMAccess,
) {
    assert!(
        cpu.x[self.operands.rs1 as usize] as u64 <= cpu.x[self.operands.rs2 as usize] as
        u64
    );
}
```

*NO INLINE SEQUENCE FOUND*

## amomaxd.rs
> **AMOMAXD (Atomic Memory Operation MAX Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, stores the signed maximum of it and rs2, and places the original value in rd.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = AMOMAXD,
    mask   = 0xf800707f,
    match  = 0xa000302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOMAXD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let compare_value = cpu.x[self.operands.rs2 as usize];
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = if original_value >= compare_value {
        original_value
    } else {
        compare_value
    };
    cpu.mmu.store_doubleword(address, new_value as u64).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs2 = allocator.allocate();
    let v_rd = allocator.allocate();
    let v_sel_rs2 = allocator.allocate();
    let v_sel_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_r::<SLT>(*v_sel_rs2, *v_rd, self.operands.rs2);
    asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
    asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
    asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
    asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
    asm.emit_s::<SD>(self.operands.rs1, *v_rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## andi.rs
> **ANDI (AND Immediate):** Computes the bitwise AND of rs1 and a sign-extended 12-bit immediate, storing the result in rd.

```rust
declare_riscv_instr!(
    name   = ANDI,
    mask   = 0x0000707f,
    match  = 0x00007013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <ANDI as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize]
                & normalize_imm(self.operands.imm, &cpu.xlen),
        );
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_pow2_w.rs
> **VirtualPow2W (Virtual Power of 2 Word):** Emulator-internal instruction that computes 2 raised to the power of (rs1 mod 32) and stores the result in rd. Only valid in 64-bit mode.

```rust
declare_riscv_instr!(
    name = VirtualPow2W,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualPow2W as RISCVInstruction>::RAMAccess) {
    match cpu.xlen {
        Xlen::Bit32 => panic!("VirtualPow2W is invalid in 32b mode"),
        Xlen::Bit64 => {
            cpu.x[self.operands.rd as usize] = 1
                << (cpu.x[self.operands.rs1 as usize] as u64 % 32);
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_srli.rs
> **VirtualSRLI (Virtual Shift Right Logical Immediate):** Emulator-internal instruction that performs a logical right shift of rs1 by the shift amount encoded in the trailing zeros of the immediate operand.

```rust
declare_riscv_instr!(
    name = VirtualSRLI,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualSRLI as RISCVInstruction>::RAMAccess) {
    let shift = self.operands.imm.trailing_zeros();
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.unsigned_data(cpu.x[self.operands.rs1 as usize]).wrapping_shr(shift)
                as i64,
        );
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_muli.rs
> **VirtualMULI (Virtual Multiply Immediate):** Emulator-internal instruction that multiplies rs1 by a sign-extended immediate value and stores the result in rd.

```rust
declare_riscv_instr!(
    name = VirtualMULI,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualMULI as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize].wrapping_mul(self.operands.imm as i64),
        );
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_shift_right_bitmaski.rs
> **VirtualShiftRightBitmaskI (Shift Right Bitmask Immediate):** Emulator-internal instruction that generates a bitmask for right-shift operations using an immediate shift amount, producing a mask with ones in the upper bits.

```rust
declare_riscv_instr!(
    name = VirtualShiftRightBitmaskI,
    mask = 0,
    match = 0,
    format = FormatJ,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualShiftRightBitmaskI as RISCVInstruction>::RAMAccess,
) {
    match cpu.xlen {
        Xlen::Bit32 => {
            let shift = self.operands.imm % 32;
            let ones = (1u64 << (32 - shift)) - 1;
            cpu.x[self.operands.rd as usize] = (ones << shift) as i64;
        }
        Xlen::Bit64 => {
            let shift = self.operands.imm % 64;
            let ones = (1u128 << (64 - shift)) - 1;
            cpu.x[self.operands.rd as usize] = (ones << shift) as i64;
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## amoswapd.rs
> **AMOSWAPD (Atomic Memory Operation SWAP Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, stores rs2 at that address, and places the original value in rd.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = AMOSWAPD,
    mask   = 0xf800707f,
    match  = 0x0800302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOSWAPD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let new_value = cpu.x[self.operands.rs2 as usize] as u64;
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    cpu.mmu.store_doubleword(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_s::<SD>(self.operands.rs1, self.operands.rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## lb.rs
> **LB (Load Byte):** Loads an 8-bit byte from memory at rs1 + offset, sign-extending the result into rd.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = LB,
    mask   = 0x0000707f,
    match  = 0x00000003,
    format = FormatLoad,
    ram    = RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LB as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu
        .mmu
        .load(cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64)
    {
        Ok((byte, memory_read)) => {
            *ram_access = memory_read;
            byte as i8 as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => self.inline_sequence_32(allocator),
        Xlen::Bit64 => self.inline_sequence_64(allocator),
    }
}
```

```rust
fn inline_sequence_32(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_word_address = allocator.allocate();
    let v_word = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit32,
        allocator,
    );
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_word_address, *v_address, -4i64 as u64);
    asm.emit_i::<VirtualLW>(*v_word, *v_word_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 3);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_word, *v_shift);
    asm.emit_i::<SRAI>(self.operands.rd, self.operands.rd, 24);
    asm.finalize()
}
```

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 7);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_dword, *v_shift);
    asm.emit_i::<SRAI>(self.operands.rd, self.operands.rd, 56);
    asm.finalize()
}
```

## virtual_lw.rs
> **VirtualLW (Virtual Load Word):** Emulator-internal instruction that loads a 32-bit word from memory at rs1 + offset, sign-extending the result. Only valid in 32-bit mode.

```rust
declare_riscv_instr!(
    name = VirtualLW,
    mask = 0,
    match = 0,
    format = FormatI,
    ram    = super::RAMRead
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    ram_access: &mut <VirtualLW as RISCVInstruction>::RAMAccess,
) {
    assert_eq!(cpu.xlen, Xlen::Bit32);
    let address = (cpu.x[self.operands.rs1 as usize] as u64)
        .wrapping_add(self.operands.imm as i32 as u64);
    let value = cpu.get_mut_mmu().load_word(address);
    cpu.x[self.operands.rd as usize] = match value {
        Ok((value, memory_read)) => {
            *ram_access = memory_read;
            value as i32 as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

*NO INLINE SEQUENCE FOUND*

## srai.rs
> **SRAI (Shift Right Arithmetic Immediate):** Arithmetically shifts rs1 right by the immediate shift amount (masked to log2(XLEN) bits), sign-filling the upper bits, and stores the result in rd.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = SRAI,
    mask   = 0xfc00707f,
    match  = 0x40005013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SRAI as RISCVInstruction>::RAMAccess) {
    let mask = match cpu.xlen {
        Xlen::Bit32 => 0x1f,
        Xlen::Bit64 => 0x3f,
    };
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .x[self.operands.rs1 as usize]
                .wrapping_shr(self.operands.imm as u32 & mask),
        );
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let (shift, len) = match xlen {
        Xlen::Bit32 => (self.operands.imm & 0x1f, 32),
        Xlen::Bit64 => (self.operands.imm & 0x3f, 64),
    };
    let ones = (1u128 << (len - shift)) - 1;
    let bitmask = (ones << shift) as u64;
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_vshift_i::<VirtualSRAI>(self.operands.rd, self.operands.rs1, bitmask);
    asm.finalize()
}
```

## rem.rs
> **REM (Remainder):** Computes the signed remainder of rs1 divided by rs2, storing the result in rd. Returns the dividend if the divisor is zero, or zero for signed overflow.
* [ ] TODO:
```rust
declare_riscv_instr!(
    name   = REM,
    mask   = 0xfe00707f,
    match  = 0x02006033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <REM as RISCVInstruction>::RAMAccess) {
    let dividend = cpu.x[self.operands.rs1 as usize];
    let divisor = cpu.x[self.operands.rs2 as usize];
    if divisor == 0 {
        cpu.x[self.operands.rd as usize] = dividend;
    } else if dividend == cpu.most_negative() && divisor == -1 {
        cpu.x[self.operands.rd as usize] = 0;
    } else {
        cpu.x[self.operands.rd as usize] = cpu
            .sign_extend(
                cpu
                    .x[self.operands.rs1 as usize]
                    .wrapping_rem(cpu.x[self.operands.rs2 as usize]),
            );
    }
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let a0 = self.operands.rs1;
    let a1 = self.operands.rs2;
    let a2 = allocator.allocate();
    let a3 = allocator.allocate();
    let t0 = allocator.allocate();
    let t1 = allocator.allocate();
    let shmat = match xlen {
        Xlen::Bit32 => 31,
        Xlen::Bit64 => 63,
    };
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_j::<VirtualAdvice>(*a2, 0);
    asm.emit_j::<VirtualAdvice>(*a3, 0);
    asm.emit_b::<VirtualAssertValidDiv0>(a1, *a2, 0);
    asm.emit_r::<VirtualChangeDivisor>(*t0, a0, a1);
    asm.emit_r::<MULH>(*t1, *a2, *t0);
    let t2 = allocator.allocate();
    let t3 = allocator.allocate();
    asm.emit_r::<MUL>(*t2, *a2, *t0);
    asm.emit_i::<SRAI>(*t3, *t2, shmat);
    asm.emit_b::<VirtualAssertEQ>(*t1, *t3, 0);
    asm.emit_i::<SRAI>(*t1, a0, shmat);
    asm.emit_r::<XOR>(*t3, *a3, *t1);
    asm.emit_r::<SUB>(*t3, *t3, *t1);
    asm.emit_r::<ADD>(*t2, *t2, *t3);
    asm.emit_b::<VirtualAssertEQ>(*t2, a0, 0);
    asm.emit_i::<SRAI>(*t1, *t0, shmat);
    asm.emit_r::<XOR>(*t2, *t0, *t1);
    asm.emit_r::<SUB>(*t2, *t2, *t1);
    asm.emit_b::<VirtualAssertValidUnsignedRemainder>(*a3, *t2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *t3, 0);
    asm.finalize()
}
```

## srl.rs
> **SRL (Shift Right Logical):** Logically shifts rs1 right by the shift amount in rs2 (masked to log2(XLEN) bits), zero-filling the upper bits, and stores the result in rd.
* [ ]    DONE:
```rust
declare_riscv_instr!(
    name   = SRL,
    mask   = 0xfe00707f,
    match  = 0x00005033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SRL as RISCVInstruction>::RAMAccess) {
    let mask = match cpu.xlen {
        Xlen::Bit32 => 0x1f,
        Xlen::Bit64 => 0x3f,
    };
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .unsigned_data(cpu.x[self.operands.rs1 as usize])
                .wrapping_shr(cpu.x[self.operands.rs2 as usize] as u32 & mask) as i64,
        );
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_bitmask = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualShiftRightBitmask>(*v_bitmask, self.operands.rs2, 0);
    asm.emit_vshift_r::<VirtualSRL>(self.operands.rd, self.operands.rs1, *v_bitmask);
    asm.finalize()
}
```

## sd.rs
> **SD (Store Doubleword):** Stores the 64-bit value in rs2 to memory at the address rs1 + offset.

```rust
declare_riscv_instr!(
    name   = SD,
    mask   = 0x0000707f,
    match  = 0x00003023,
    format = FormatS,
    ram    = RAMWrite
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <SD as RISCVInstruction>::RAMAccess) {
    *ram_access = cpu
        .mmu
        .store_doubleword(
            cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64,
            cpu.x[self.operands.rs2 as usize] as u64,
        )
        .ok()
        .unwrap();
}
```

*NO INLINE SEQUENCE FOUND*

## sub.rs
> **SUB (Subtract):** Subtracts rs2 from rs1 and stores the result in rd.

```rust
declare_riscv_instr!(
    name   = SUB,
    mask   = 0xfe00707f,
    match  = 0x40000033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SUB as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .x[self.operands.rs1 as usize]
                .wrapping_sub(cpu.x[self.operands.rs2 as usize]),
        );
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_assert_word_alignment.rs
> **VirtualAssertWordAlignment (Assert Word Alignment):** Emulator-internal assertion that verifies the computed address (rs1 + imm) is word-aligned (lower 2 bits are zero).

```rust
declare_riscv_instr!(
    name = VirtualAssertWordAlignment,
    mask = 0,
    match = 0,
    format = AssertAlignFormat,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualAssertWordAlignment as RISCVInstruction>::RAMAccess,
) {
    let address = cpu.x[self.operands.rs1 as usize] + self.operands.imm;
    assert!(address & 3 == 0, "RAM access (LW or LWU) is not word aligned: {address:x}");
}
```

*NO INLINE SEQUENCE FOUND*

## sltu.rs
> **SLTU (Set Less Than Unsigned):** Sets rd to 1 if the unsigned value in rs1 is less than the unsigned value in rs2, otherwise sets rd to 0.

```rust
declare_riscv_instr!(
    name   = SLTU,
    mask   = 0xfe00707f,
    match  = 0x00003033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SLTU as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu
        .unsigned_data(cpu.x[self.operands.rs1 as usize])
        < cpu.unsigned_data(cpu.x[self.operands.rs2 as usize])
    {
        true => 1,
        false => 0,
    };
}
```

*NO INLINE SEQUENCE FOUND*

## sw.rs

> 

* [ ]    DONE:

```rust
declare_riscv_instr!(
    name   = SW,
    mask   = 0x0000707f,
    match  = 0x00002023,
    format = FormatS,
    ram    = RAMWrite
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <SW as RISCVInstruction>::RAMAccess) {
    *ram_access = cpu
        .mmu
        .store_word(
            cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64,
            cpu.x[self.operands.rs2 as usize] as u32,
        )
        .ok()
        .unwrap();
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => self.inline_sequence_32(allocator),
        Xlen::Bit64 => self.inline_sequence_64(allocator),
    }
}
```

```rust
fn inline_sequence_32(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit32,
        allocator,
    );
    asm.emit_s::<VirtualSW>(self.operands.rs1, self.operands.rs2, self.operands.imm);
    asm.finalize()
}
```

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let v_mask = allocator.allocate();
    let v_word = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_halign::<VirtualAssertWordAlignment>(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<SLLI>(*v_shift, *v_address, 3);
    asm.emit_i::<ORI>(*v_mask, 0, -1i64 as u64);
    asm.emit_i::<SRLI>(*v_mask, *v_mask, 32);
    asm.emit_r::<SLL>(*v_mask, *v_mask, *v_shift);
    asm.emit_r::<SLL>(*v_word, self.operands.rs2, *v_shift);
    asm.emit_r::<XOR>(*v_word, *v_dword, *v_word);
    asm.emit_r::<AND>(*v_word, *v_word, *v_mask);
    asm.emit_r::<XOR>(*v_dword, *v_dword, *v_word);
    asm.emit_s::<SD>(*v_dword_address, *v_dword, 0);
    asm.finalize()
}
```

## amoswapw.rs
> **AMOSWAPW (Atomic Memory Operation SWAP Word):** Atomically loads a 32-bit word from the address in rs1, stores rs2 at that address, and places the original value in rd.
* [x]    DONE:
```rust
declare_riscv_instr!(
    name   = AMOSWAPW,
    mask   = 0xf800707f,
    match  = 0x0800202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOSWAPW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let new_value = cpu.x[self.operands.rs2 as usize] as u32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    cpu.mmu.store_word(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => {
            let v_rd = allocator.allocate();
            let mut asm = InstrAssembler::new(
                self.address,
                self.is_compressed,
                xlen,
                allocator,
            );
            asm.emit_halign::<
                    super::virtual_assert_word_alignment::VirtualAssertWordAlignment,
                >(self.operands.rs1, 0);
            asm.emit_i::<VirtualLW>(*v_rd, self.operands.rs1, 0);
            asm.emit_s::<VirtualSW>(self.operands.rs1, self.operands.rs2, 0);
            asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
            asm.finalize()
        }
        Xlen::Bit64 => {
            let v_mask = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            let v_rd = allocator.allocate();
            let mut asm = InstrAssembler::new(
                self.address,
                self.is_compressed,
                xlen,
                allocator,
            );
            asm.emit_halign::<VirtualAssertWordAlignment>(self.operands.rs1, 0);
            asm.emit_i::<ANDI>(*v_shift, self.operands.rs1, -8i64 as u64);
            asm.emit_ld::<LD>(*v_dword, *v_shift, 0);
            asm.emit_i::<SLLI>(*v_shift, self.operands.rs1, 3);
            asm.emit_r::<SRL>(*v_rd, *v_dword, *v_shift);
            asm.emit_i::<ORI>(*v_mask, 0, -1i64 as u64);
            asm.emit_i::<SRLI>(*v_mask, *v_mask, 32);
            asm.emit_r::<SLL>(*v_mask, *v_mask, *v_shift);
            asm.emit_r::<SLL>(*v_shift, self.operands.rs2, *v_shift);
            asm.emit_r::<XOR>(*v_shift, *v_dword, *v_shift);
            asm.emit_r::<AND>(*v_shift, *v_shift, *v_mask);
            asm.emit_r::<XOR>(*v_dword, *v_dword, *v_shift);
            asm.emit_i::<ANDI>(*v_mask, self.operands.rs1, -8i64 as u64);
            asm.emit_s::<SD>(*v_mask, *v_dword, 0);
            asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, *v_rd, 0);
            asm.finalize()
        }
    }
}
```

## virtual_sra.rs
> **VirtualSRA (Virtual Shift Right Arithmetic Register):** Emulator-internal instruction that performs an arithmetic right shift of rs1 by the shift amount encoded in the trailing zeros of rs2.

```rust
declare_riscv_instr!(
    name = VirtualSRA,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftR,
    ram = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualSRA as RISCVInstruction>::RAMAccess) {
    let shift = cpu.x[self.operands.rs2 as usize].trailing_zeros();
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(cpu.x[self.operands.rs1 as usize].wrapping_shr(shift));
}
```

*NO INLINE SEQUENCE FOUND*

## remu.rs
> **REMU (Remainder Unsigned):** Computes the unsigned remainder of rs1 divided by rs2, storing the result in rd. 
Returns the dividend if the divisor is zero.

* [ ]    DONE:
```rust
declare_riscv_instr!(
    name   = REMU,
    mask   = 0xfe00707f,
    match  = 0x02007033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <REMU as RISCVInstruction>::RAMAccess) {
    let dividend = cpu.unsigned_data(cpu.x[self.operands.rs1 as usize]);
    let divisor = cpu.unsigned_data(cpu.x[self.operands.rs2 as usize]);
    cpu.x[self.operands.rd as usize] = match divisor {
        0 => cpu.sign_extend(dividend as i64),
        _ => cpu.sign_extend(dividend.wrapping_rem(divisor) as i64),
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let a0 = self.operands.rs1;
    let a1 = self.operands.rs2;
    let a2 = allocator.allocate();
    let a3 = allocator.allocate();
    let t0 = allocator.allocate();
    let t1 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_j::<VirtualAdvice>(*a2, 0);
    asm.emit_j::<VirtualAdvice>(*a3, 0);
    asm.emit_b::<VirtualAssertMulUNoOverflow>(*a2, a1, 0);
    asm.emit_r::<MUL>(*t0, *a2, a1);
    asm.emit_r::<ADD>(*t1, *t0, *a3);
    asm.emit_b::<VirtualAssertLTE>(*t0, *t1, 0);
    asm.emit_b::<VirtualAssertLTE>(*a3, *t1, 0);
    asm.emit_b::<VirtualAssertEQ>(*t1, a0, 0);
    asm.emit_b::<VirtualAssertValidUnsignedRemainder>(*a3, a1, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *a3, 0);
    asm.finalize()
}
```

## virtual_assert_valid_div0.rs
> **VirtualAssertValidDiv0 (Assert Valid Division by Zero):** Emulator-internal assertion that verifies when the divisor is zero, the quotient equals the all-ones value (MAX), matching RISC-V division-by-zero semantics.

```rust
declare_riscv_instr!(
    name = VirtualAssertValidDiv0,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualAssertValidDiv0 as RISCVInstruction>::RAMAccess,
) {
    let divisor = cpu.x[self.operands.rs1 as usize];
    let quotient = cpu.x[self.operands.rs2 as usize];
    match cpu.xlen {
        Xlen::Bit32 => {
            if divisor == 0 {
                assert!(quotient as u64 as u32 == u32::MAX);
            }
        }
        Xlen::Bit64 => {
            if divisor == 0 {
                assert!(quotient as u64 == u64::MAX);
            }
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_zero_extend_word.rs
> **VirtualZeroExtendWord (Zero-Extend Word):** Emulator-internal instruction that zero-extends the lower 32 bits of rs1 into a 64-bit value in rd. Only valid in 64-bit mode.

```rust
declare_riscv_instr!(
    name = VirtualZeroExtendWord,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualZeroExtendWord as RISCVInstruction>::RAMAccess,
) {
    match cpu.xlen {
        Xlen::Bit32 => panic!("VirtualExtend is not supported for 32-bit mode"),
        Xlen::Bit64 => {
            cpu.x[self.operands.rd as usize] = cpu.x[self.operands.rs1 as usize]
                & 0xFFFFFFFF;
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## xor.rs
> **XOR (Exclusive OR):** Computes the bitwise XOR of rs1 and rs2, storing the result in rd.

```rust
declare_riscv_instr!(
    name   = XOR,
    mask   = 0xfe00707f,
    match  = 0x00004033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <XOR as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize] ^ cpu.x[self.operands.rs2 as usize],
        );
}
```

*NO INLINE SEQUENCE FOUND*

## amomaxw.rs
> **AMOMAXW (Atomic Memory Operation MAX Word):** Atomically loads a 32-bit word from the address in rs1, stores the signed maximum of it and rs2, and places the original value in rd.
* [ ] TODO: 
```rust
declare_riscv_instr!(
    name   = AMOMAXW,
    mask   = 0xf800707f,
    match  = 0xa000202f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOMAXW as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let compare_value = cpu.x[self.operands.rs2 as usize] as i32;
    let load_result = cpu.mmu.load_word(address);
    let original_value = match load_result {
        Ok((word, _)) => word as i32 as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = if original_value as i32 >= compare_value {
        original_value as i32
    } else {
        compare_value
    };
    cpu.mmu.store_word(address, new_value as u32).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    match xlen {
        Xlen::Bit32 => {
            let v_rd = allocator.allocate();
            let v_rs2 = allocator.allocate();
            let v_sel_rs2 = allocator.allocate();
            let v_sel_rd = allocator.allocate();
            amo_pre32(&mut asm, self.operands.rs1, *v_rd);
            asm.emit_r::<SLT>(*v_sel_rs2, *v_rd, self.operands.rs2);
            asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
            asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
            asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
            amo_post32(&mut asm, *v_rs2, self.operands.rs1, self.operands.rd, *v_rd);
        }
        Xlen::Bit64 => {
            let v_rd = allocator.allocate();
            let v_dword = allocator.allocate();
            let v_shift = allocator.allocate();
            amo_pre64(&mut asm, self.operands.rs1, *v_rd, *v_dword, *v_shift);
            let v_rs2 = allocator.allocate();
            let v_sel_rs2 = allocator.allocate();
            let v_sel_rd = allocator.allocate();
            let v_mask = allocator.allocate();
            asm.emit_i::<VirtualSignExtendWord>(*v_rs2, self.operands.rs2, 0);
            asm.emit_i::<VirtualSignExtendWord>(*v_sel_rd, *v_rd, 0);
            asm.emit_r::<SLT>(*v_sel_rs2, *v_sel_rd, *v_rs2);
            asm.emit_i::<XORI>(*v_sel_rd, *v_sel_rs2, 1);
            asm.emit_r::<MUL>(*v_rs2, *v_sel_rs2, self.operands.rs2);
            asm.emit_r::<MUL>(*v_sel_rd, *v_sel_rd, *v_rd);
            asm.emit_r::<ADD>(*v_rs2, *v_sel_rd, *v_rs2);
            drop(v_sel_rd);
            drop(v_sel_rs2);
            amo_post64(
                &mut asm,
                self.operands.rs1,
                *v_rs2,
                *v_dword,
                *v_shift,
                *v_mask,
                self.operands.rd,
                *v_rd,
            );
        }
    }
    asm.finalize()
}
```

## slti.rs
> **SLTI (Set Less Than Immediate):** Sets rd to 1 if the signed value in rs1 is less than the sign-extended immediate, otherwise sets rd to 0.

```rust
declare_riscv_instr!(
    name   = SLTI,
    mask   = 0x0000707f,
    match  = 0x00002013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SLTI as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu.x[self.operands.rs1 as usize]
        < normalize_imm(self.operands.imm, &cpu.xlen)
    {
        true => 1,
        false => 0,
    };
}
```

*NO INLINE SEQUENCE FOUND*

## amoord.rs
> **AMOORD (Atomic Memory Operation OR Doubleword):** Atomically loads a 64-bit doubleword from the address in rs1, ORs it with rs2, stores the result back, and places the original value in rd.
* [ ]    DONE:
```rust
declare_riscv_instr!(
    name   = AMOORD,
    mask   = 0xf800707f,
    match  = 0x4000302f,
    format = FormatAMO,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AMOORD as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize] as u64;
    let or_value = cpu.x[self.operands.rs2 as usize] as u64;
    let load_result = cpu.mmu.load_doubleword(address);
    let original_value = match load_result {
        Ok((doubleword, _)) => doubleword as i64,
        Err(_) => panic!("MMU load error"),
    };
    let new_value = (original_value as u64) | or_value;
    cpu.mmu.store_doubleword(address, new_value).expect("MMU store error");
    cpu.x[self.operands.rd as usize] = original_value;
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_rs2 = allocator.allocate();
    let v_rd = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_ld::<LD>(*v_rd, self.operands.rs1, 0);
    asm.emit_r::<OR>(*v_rs2, *v_rd, self.operands.rs2);
    asm.emit_s::<SD>(self.operands.rs1, *v_rs2, 0);
    asm.emit_i::<ADDI>(self.operands.rd, *v_rd, 0);
    asm.finalize()
}
```

## mul.rs
> **MUL (Multiply):** Multiplies `rs1` by `rs2` and stores the lower `XLEN` bits of the product in `rd`.
> Alternatively, 
> ```
> x[rd] = (x[rs1] * x[rs1]) mod 2^XLEN
> x[rd] = x[rd] >= 2^(XLEN-1) ? x[rd] - 2^XLEN: x[rd]
> ```

**EXAMPLES**: 

```
XLEN = 4
-4 * -3 = 12 (mathematically)
-4 in 4-bit binary: 1100
-3 in 4-bit binary: 1101
Full multiplication (treating as unsigned bit patterns): 1100 * 1101 = 0011_1100 (8 bits)
Drop the top 4 bits: keep only 1100
1100 interpreted as 4-bit signed: -4
Result: -4 
```

```rust
declare_riscv_instr!(
    name   = MUL,
    mask   = 0xfe00707f,
    match  = 0x02000033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <MUL as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .x[self.operands.rs1 as usize]
                .wrapping_mul(cpu.x[self.operands.rs2 as usize]),
        );
}
```

*NO INLINE SEQUENCE FOUND*

## blt.rs
> **BLT (Branch if Less Than):** Compares rs1 and rs2 as signed values; if rs1 < rs2, branches to PC + immediate offset.

```rust
declare_riscv_instr!(
    name   = BLT,
    mask   = 0x0000707f,
    match  = 0x00004063,
    format = FormatB,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <BLT as RISCVInstruction>::RAMAccess) {
    if cpu.sign_extend(cpu.x[self.operands.rs1 as usize])
        < cpu.sign_extend(cpu.x[self.operands.rs2 as usize])
    {
        cpu.pc = (self.address as i64 + self.operands.imm as i64) as u64;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## jalr.rs
> **JALR (Jump and Link Register):** Sets PC to (rs1 + sign-extended immediate) with the LSB cleared, and stores the return address (old PC) in rd.

```rust
declare_riscv_instr!(
    name   = JALR,
    mask   = 0x0000707f,
    match  = 0x00000067,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <JALR as RISCVInstruction>::RAMAccess) {
    let tmp = cpu.sign_extend(cpu.pc as i64);
    cpu.pc = (cpu
        .x[self.operands.rs1 as usize]
        .wrapping_add(normalize_imm(self.operands.imm, &cpu.xlen)) as u64) & !1;
    if self.operands.rd != 0 {
        if self.operands.rd == 1 {
            cpu.track_call(self.address, NormalizedOperands::from(self.operands));
        }
        cpu.x[self.operands.rd as usize] = tmp;
    }
}
```

*NO INLINE SEQUENCE FOUND*

## lbu.rs
> **LBU (Load Byte Unsigned):** Loads an 8-bit byte from memory at rs1 + offset, zero-extending the result into rd.

* [ ]    DONE:
```rust
declare_riscv_instr!(
    name   = LBU,
    mask   = 0x0000707f,
    match  = 0x00004003,
    format = FormatLoad,
    ram    = RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LBU as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu
        .mmu
        .load(cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64)
    {
        Ok((byte, memory_read)) => {
            *ram_access = memory_read;
            byte as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => self.inline_sequence_32(allocator),
        Xlen::Bit64 => self.inline_sequence_64(allocator),
    }
}
```

```rust
fn inline_sequence_32(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_word_address = allocator.allocate();
    let v_word = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit32,
        allocator,
    );
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_word_address, *v_address, -4i64 as u64);
    asm.emit_i::<VirtualLW>(*v_word, *v_word_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 3);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_word, *v_shift);
    asm.emit_i::<SRLI>(self.operands.rd, self.operands.rd, 24);
    asm.finalize()
}
```

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 7);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_dword, *v_shift);
    asm.emit_i::<SRLI>(self.operands.rd, self.operands.rd, 56);
    asm.finalize()
}
```

## addi.rs
> **ADDI (Add Immediate):** Adds a sign-extended 12-bit immediate to rs1 and stores the result in rd.

```rust
declare_riscv_instr!(
    name   = ADDI,
    mask   = 0x0000707f,
    match  = 0x00000013,
    format = FormatI,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <ADDI as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu
                .x[self.operands.rs1 as usize]
                .wrapping_add(normalize_imm(self.operands.imm, &cpu.xlen)),
        );
}
```

*NO INLINE SEQUENCE FOUND*

## auipc.rs
> **AUIPC (Add Upper Immediate to PC):** Adds a 20-bit upper immediate value to the current PC and stores the result in rd.

```rust
declare_riscv_instr!(
    name   = AUIPC,
    mask   = 0x0000007f,
    match  = 0x00000017,
    format = FormatU,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <AUIPC as RISCVInstruction>::RAMAccess) {
    let pc = self.address as i64;
    let imm = normalize_imm(self.operands.imm, &cpu.xlen);
    cpu.x[self.operands.rd as usize] = cpu.sign_extend(pc.wrapping_add(imm));
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_sign_extend_word.rs
> **VirtualSignExtendWord (Sign-Extend Word):** Emulator-internal instruction that sign-extends the lower 32 bits of rs1 into a 64-bit value in rd. Only valid in 64-bit mode.

```rust
declare_riscv_instr!(
    name = VirtualSignExtendWord,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualSignExtendWord as RISCVInstruction>::RAMAccess,
) {
    match cpu.xlen {
        Xlen::Bit32 => panic!("VirtualSignExtend is not supported for 32-bit mode"),
        Xlen::Bit64 => {
            cpu.x[self.operands.rd as usize] = (cpu.x[self.operands.rs1 as usize] << 32)
                >> 32;
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_change_divisor_w.rs
> **VirtualChangeDivisorW (Change Divisor Word):** Emulator-internal instruction that adjusts the 32-bit divisor to handle the overflow case where dividend is i32::MIN and divisor is -1, replacing the divisor with 1.

```rust
declare_riscv_instr!(
    name = VirtualChangeDivisorW,
    mask = 0,
    match = 0,
    format = FormatR,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualChangeDivisorW as RISCVInstruction>::RAMAccess,
) {
    match cpu.xlen {
        Xlen::Bit32 => {
            panic!("VirtualChangeDivisorW is invalid in 32b mode");
        }
        Xlen::Bit64 => {
            let dividend = cpu.x[self.operands.rs1 as usize] as i32;
            let divisor = cpu.x[self.operands.rs2 as usize] as i32;
            if dividend == i32::MIN && divisor == -1 {
                cpu.x[self.operands.rd as usize] = 1;
            } else {
                cpu.x[self.operands.rd as usize] = divisor as i64;
            }
        }
    }
}
```

*NO INLINE SEQUENCE FOUND*

## virtual_xor_rotw.rs
> **VirtualXorRotW (XOR with Rotate Word):** Emulator-internal macro-generated instruction for XOR combined with 32-bit word rotation operations.

```rust
declare_riscv_instr!(
            name = $name,
            mask = 0,
            match = 0,
            format = FormatR,
            ram = ()
        );
```

*NO INLINE SEQUENCE FOUND*

## mulhu.rs
> **MULHU (Multiply High Unsigned):** Computes the upper half of the unsigned product of rs1 and rs2, storing the high bits in rd.

```rust
declare_riscv_instr!(
    name   = MULHU,
    mask   = 0xfe00707f,
    match  = 0x02003033,
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <MULHU as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu.xlen {
        Xlen::Bit32 => {
            cpu.sign_extend(
                (((cpu.x[self.operands.rs1 as usize] as u32 as u64)
                    * (cpu.x[self.operands.rs2 as usize] as u32 as u64)) >> 32) as i64,
            )
        }
        Xlen::Bit64 => {
            ((cpu.x[self.operands.rs1 as usize] as u64 as u128)
                .wrapping_mul(cpu.x[self.operands.rs2 as usize] as u64 as u128) >> 64)
                as i64
        }
    };
}
```

*NO INLINE SEQUENCE FOUND*

## sllw.rs

> **SLLW (Shift Left Logical Word):** Shifts the lower 32 bits of rs1 left by the amount in rs2 (masked to 5 bits), sign-extending the 32-bit result into rd.

* [ ]    DONE:

```rust
declare_riscv_instr!(
    name   = SLLW,
    mask   = 0xfe00707f,
    match  = 0x0000003b | (0b001 << 12),
    format = FormatR,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <SLLW as RISCVInstruction>::RAMAccess) {
    let shamt = (cpu.x[self.operands.rs2 as usize] & 0x1f) as u32;
    cpu.x[self.operands.rd as usize] = ((cpu.x[self.operands.rs1 as usize] as u32)
        << shamt) as i32 as i64;
}
```
```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_pow2 = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_i::<VirtualPow2W>(*v_pow2, self.operands.rs2, 0);
    asm.emit_r::<MUL>(self.operands.rd, self.operands.rs1, *v_pow2);
    asm.emit_i::<VirtualSignExtendWord>(self.operands.rd, self.operands.rd, 0);
    asm.finalize()
}
```

## lh.rs
> **LH (Load Halfword):** Loads a 16-bit halfword from memory at rs1 + offset, sign-extending the result into rd.
    DONE:
```rust
declare_riscv_instr!(
    name   = LH,
    mask   = 0x0000707f,
    match  = 0x00001003,
    format = FormatLoad,
    ram    = RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LH as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = match cpu
        .mmu
        .load_halfword(
            cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm) as u64,
        )
    {
        Ok((halfword, memory_read)) => {
            *ram_access = memory_read;
            halfword as i16 as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => self.inline_sequence_32(allocator),
        Xlen::Bit64 => self.inline_sequence_64(allocator),
    }
}
```

```rust
fn inline_sequence_32(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_word_address = allocator.allocate();
    let v_word = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit32,
        allocator,
    );
    asm.emit_halign::<
            VirtualAssertHalfwordAlignment,
        >(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_word_address, *v_address, -4i64 as u64);
    asm.emit_i::<VirtualLW>(*v_word, *v_word_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 2);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_word, *v_shift);
    asm.emit_i::<SRAI>(self.operands.rd, self.operands.rd, 16);
    asm.finalize()
}
```

```rust
fn inline_sequence_64(&self, allocator: &VirtualRegisterAllocator) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(
        self.address,
        self.is_compressed,
        Xlen::Bit64,
        allocator,
    );
    asm.emit_halign::<
            VirtualAssertHalfwordAlignment,
        >(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 6);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_dword, *v_shift);
    asm.emit_i::<SRAI>(self.operands.rd, self.operands.rd, 48);
    asm.finalize()
}
```

## virtual_assert_halfword_alignment.rs
> **VirtualAssertHalfwordAlignment (Assert Halfword Alignment):** Emulator-internal assertion that verifies the computed address (rs1 + imm) is halfword-aligned (bit 0 is zero).

```rust
declare_riscv_instr!(
    name = VirtualAssertHalfwordAlignment,
    mask = 0,
    match = 0,
    format = AssertAlignFormat,
    ram = ()
);
```

```rust
fn exec(
    &self,
    cpu: &mut Cpu,
    _: &mut <VirtualAssertHalfwordAlignment as RISCVInstruction>::RAMAccess,
) {
    let address = cpu.x[self.operands.rs1 as usize] + self.operands.imm;
    assert!(
        address & 1 == 0, "RAM access (LH or LHU) is not halfword aligned: {address:x}"
    );
}
```

*NO INLINE SEQUENCE FOUND*

## lwu.rs
> **LWU (Load Word Unsigned):** Loads a 32-bit word from memory at rs1 + offset, zero-extending the result into rd.
> **Description**: Loads a 32-bit value from memory and zero-extends this to 64 bits before storing it in register rd.
 * [ ] TODO:
```rust
declare_riscv_instr!(
    name   = LWU,
    mask   = 0x0000707f,
    match  = 0x00006003,
    format = FormatLoad,
    ram    = super::RAMRead
);
```

```rust
fn exec(&self, cpu: &mut Cpu, ram_access: &mut <LWU as RISCVInstruction>::RAMAccess) {
    let address = cpu.x[self.operands.rs1 as usize].wrapping_add(self.operands.imm)
        as u64;
    let value = cpu.mmu.load_word(address);
    cpu.x[self.operands.rd as usize] = match value {
        Ok((word, memory_read)) => {
            *ram_access = memory_read;
            word as i64
        }
        Err(_) => panic!("MMU load error"),
    };
}
```

```rust
fn inline_sequence(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    match xlen {
        Xlen::Bit32 => panic!("LWU is invalid in 32b mode"),
        Xlen::Bit64 => self.inline_sequence_64(allocator, xlen),
    }
}
```
```rust
fn inline_sequence_64(
    &self,
    allocator: &VirtualRegisterAllocator,
    xlen: Xlen,
) -> Vec<Instruction> {
    let v_address = allocator.allocate();
    let v_dword_address = allocator.allocate();
    let v_dword = allocator.allocate();
    let v_shift = allocator.allocate();
    let mut asm = InstrAssembler::new(self.address, self.is_compressed, xlen, allocator);
    asm.emit_halign::<VirtualAssertWordAlignment>(self.operands.rs1, self.operands.imm);
    asm.emit_i::<ADDI>(*v_address, self.operands.rs1, self.operands.imm as u64);
    asm.emit_i::<ANDI>(*v_dword_address, *v_address, -8i64 as u64);
    asm.emit_ld::<LD>(*v_dword, *v_dword_address, 0);
    asm.emit_i::<XORI>(*v_shift, *v_address, 4);
    asm.emit_i::<SLLI>(*v_shift, *v_shift, 3);
    asm.emit_r::<SLL>(self.operands.rd, *v_dword, *v_shift);
    asm.emit_i::<SRLI>(self.operands.rd, self.operands.rd, 32);
    asm.finalize()
}
```

## lui.rs
> **LUI (Load Upper Immediate):** Loads a 20-bit immediate value into the upper bits of rd, zeroing the lower 12 bits.

```rust
declare_riscv_instr!(
    name   = LUI,
    mask   = 0x0000007f,
    match  = 0x00000037,
    format = FormatU,
    ram    = ()
);
```

```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <LUI as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = normalize_imm(self.operands.imm, &cpu.xlen);
}
```

*NO INLINE SEQUENCE FOUND*
