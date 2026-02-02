+++
title = "The Virtual Jolt ISA"
weight = 2
+++
This document provides a complete reference for all virtual instructions in the extended RISC-V ISA, organized by instruction format.

## Table of Contents

- [Format Overview](#format-overview)
- [FormatJ Instructions](#formatj-instructions)
- [FormatB Instructions](#formatb-instructions)
- [FormatR Instructions](#formatr-instructions)
- [AssertAlignFormat Instructions](#assertalignformat-instructions)
- [FormatI Instructions](#formati-instructions)
- [FormatS Instructions](#formats-instructions)
- [FormatVirtualRightShiftR Instructions](#formatvirtualrightshiftr-instructions)
- [FormatVirtualRightShiftI Instructions](#formatvirtualrightshifti-instructions)

---

## Format Overview

### Standard RISC-V Formats Used

| Format | Fields | Description |
|--------|--------|-------------|
| **FormatR** | `rd`, `rs1`, `rs2` | Register-to-register operations |
| **FormatI** | `rd`, `rs1`, `imm` | Immediate operations (12-bit) |
| **FormatS** | `rs1`, `rs2`, `imm` | Store operations |
| **FormatB** | `rs1`, `rs2`, `imm` | Branch/comparison operations |
| **FormatJ** | `rd`, `imm` | Jump operations (20-bit) |

### Custom Virtual Formats

| Format | Fields | Description |
|--------|--------|-------------|
| **FormatVirtualRightShiftI** | `rd`, `rs1`, `imm` | Right shift with immediate (shift = `imm.trailing_zeros()`) |
| **FormatVirtualRightShiftR** | `rd`, `rs1`, `rs2` | Right shift with register (shift = `x[rs2].trailing_zeros()`) |
| **AssertAlignFormat** | `rs1`, `imm` | Memory alignment assertions |

---

## FormatJ Instructions

**Format Structure:**
```rust
pub struct FormatJ {
    pub rd: u8,   // Destination register
    pub imm: u64, // 20-bit immediate value
}
```

### 1. VirtualPow2I

**Operation:** `x[rd] = 1 << (imm % XLEN)`

**Description:** Computes 2 raised to the power of `(imm % XLEN)` and stores the result in `rd`.

**Behavior:**
- **32-bit mode:** `x[rd] = 1 << (imm % 32)`
- **64-bit mode:** `x[rd] = 1 << (imm % 64)`

**Example:**
```rust
VirtualPow2I rd=x5, imm=10
// x[5] = 1 << 10 = 1024
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualPow2I,
    mask = 0,
    match = 0,
    format = FormatJ,
    ram = ()
);
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualPow2I,
    mask = 0,
    match = 0,
    format = FormatJ,
    ram = ()
);
```

**Implementation:**
```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualPow2I as RISCVInstruction>::RAMAccess) {
    match cpu.xlen {
        Xlen::Bit32 => cpu.x[self.operands.rd as usize] = 1 << (self.operands.imm % 32),
        Xlen::Bit64 => cpu.x[self.operands.rd as usize] = 1 << (self.operands.imm % 64),
    }
}
```

### 2. VirtualPow2IW

**Operation:** `x[rd] = 1 << (imm % 32)`

**Description:** Computes 2 raised to the power of `(imm % 32)` and stores the result in `rd`. Word-sized operation (32-bit).

**Behavior:**
- **32-bit mode:** Panics (invalid operation)
- **64-bit mode:** `x[rd] = 1 << (imm % 32)`

**Example:**
```rust
VirtualPow2IW rd=x3, imm=5
// x[3] = 1 << 5 = 32
```

**Notes:** Only valid in 64-bit mode. Used for operations that need explicit 32-bit power-of-two values.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualPow2IW,
    mask = 0,
    match = 0,
    format = FormatJ,
    ram = ()
);
```

**Implementation:**
```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualPow2IW as RISCVInstruction>::RAMAccess) {
    match cpu.xlen {
        Xlen::Bit32 => panic!("VirtualPow2IW is invalid in 32b mode"),
        Xlen::Bit64 => cpu.x[self.operands.rd as usize] = 1 << (self.operands.imm % 32),
    }
}
```

### 3. VirtualShiftRightBitmaskI

**Operation:** `x[rd] = ((2^(XLEN-shift) - 1) << shift)` where `shift = imm % XLEN`

**Description:** Generates a bitmask with the upper `(XLEN - shift)` bits set to 1 and the lower `shift` bits set to 0.

**Behavior:**
- **32-bit mode:**
  - `shift = imm % 32`
  - `ones = (1 << (32 - shift)) - 1`
  - `x[rd] = (ones << shift)`
- **64-bit mode:**
  - `shift = imm % 64`
  - `ones = (1 << (64 - shift)) - 1`
  - `x[rd] = (ones << shift)`

**Example:**
```rust
VirtualShiftRightBitmaskI rd=x7, imm=4
// 64-bit mode: shift=4, creates mask: 0xFFFFFFFFFFFFFFF0
// (60 ones followed by 4 zeros)
```

**Use Case:** Creating alignment masks or bit manipulation patterns.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualShiftRightBitmaskI,
    mask = 0,
    match = 0,
    format = FormatJ,
    ram = ()
);
```

**Implementation:**
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

---

## FormatB Instructions

**Format Structure:**
```rust
pub struct FormatB {
    pub rs1: u8,  // Source register 1
    pub rs2: u8,  // Source register 2
    pub imm: i128 // Immediate (not used in most virtual instructions)
}
```

### 1. VirtualAssertEQ

**Operation:** `assert(x[rs1] == x[rs2])`

**Description:** Asserts that the values in registers `rs1` and `rs2` are equal. Panics if they are not equal.

**Example:**
```rust
VirtualAssertEQ rs1=x5, rs2=x6
// Panics if x[5] != x[6]
```

**Use Case:** Runtime verification and debugging.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualAssertEQ,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

**Implementation:**
```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualAssertEQ as RISCVInstruction>::RAMAccess) {
    assert_eq!(cpu.x[self.operands.rs1 as usize], cpu.x[self.operands.rs2 as usize]);
}
```

### 2. VirtualAssertMulUNoOverflow

**Operation:** `assert((x[rs1] as u64).checked_mul(x[rs2] as u64).is_some())`

**Description:** Asserts that the unsigned multiplication of `x[rs1]` and `x[rs2]` does not overflow. Panics if overflow would occur.

**Example:**
```rust
VirtualAssertMulUNoOverflow rs1=x3, rs2=x4
// Panics if (x[3] as u64) * (x[4] as u64) would overflow u64
```

**Use Case:** Safe arithmetic verification in cryptographic or financial computations.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualAssertMulUNoOverflow,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

**Implementation:**
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

### 3. VirtualAssertValidUnsignedRemainder

**Operation:** `assert(divisor == 0 || remainder < divisor)`

**Description:** Validates that `x[rs1]` (remainder) is a valid unsigned remainder when dividing by `x[rs2]` (divisor).

**Behavior:**
- **32-bit mode:** Operates on lower 32 bits as unsigned values
- **64-bit mode:** Operates on full 64-bit unsigned values

**Conditions:**
- If `x[rs2] == 0`: assertion passes (division by zero is handled separately)
- Otherwise: asserts `x[rs1] < x[rs2]`

**Example:**
```rust
VirtualAssertValidUnsignedRemainder rs1=x7, rs2=x8
// If x[8] = 10, then x[7] must be in range [0, 9]
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualAssertValidUnsignedRemainder,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

**Implementation:**
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

### 4. VirtualAssertValidDiv0

**Operation:** `if x[rs1] == 0 then assert(x[rs2] == u64::MAX)`

**Description:** Validates division-by-zero handling. If `x[rs1]` (divisor) is 0, asserts that `x[rs2]` (quotient) equals the maximum unsigned value.

**Behavior:**
- **32-bit mode:** Checks `x[rs2] as u32 == u32::MAX` if divisor is 0
- **64-bit mode:** Checks `x[rs2] as u64 == u64::MAX` if divisor is 0
- If divisor is non-zero: no operation

**Example:**
```rust
VirtualAssertValidDiv0 rs1=x5, rs2=x6
// If x[5] = 0, then x[6] must equal 0xFFFFFFFFFFFFFFFF (64-bit)
```

**Use Case:** Verifying RISC-V division-by-zero semantics.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualAssertValidDiv0,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

**Implementation:**
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

### 5. VirtualAssertLTE

**Operation:** `assert(x[rs1] as u64 <= x[rs2] as u64)`

**Description:** Asserts unsigned less-than-or-equal comparison between registers.

**Example:**
```rust
VirtualAssertLTE rs1=x10, rs2=x11
// Panics if x[10] > x[11] (unsigned comparison)
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualAssertLTE,
    mask = 0,
    match = 0,
    format = FormatB,
    ram = ()
);
```

**Implementation:**
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

---

## FormatR Instructions

**Format Structure:**
```rust
pub struct FormatR {
    pub rd: u8,  // Destination register
    pub rs1: u8, // Source register 1
    pub rs2: u8, // Source register 2
}
```

### 1. VirtualChangeDivisor

**Operation:** Handle signed division overflow case

**Description:** Adjusts divisor to handle the signed overflow case where `MIN / -1` would overflow.

**Behavior:**
- **32-bit mode:**
  - If `x[rs1] == i32::MIN && x[rs2] == -1`: `x[rd] = 1`
  - Otherwise: `x[rd] = x[rs2]`
- **64-bit mode:**
  - If `x[rs1] == i64::MIN && x[rs2] == -1`: `x[rd] = 1`
  - Otherwise: `x[rd] = x[rs2]`

**Example:**
```rust
VirtualChangeDivisor rd=x5, rs1=x6, rs2=x7
// If x[6] = -2^63 and x[7] = -1, then x[5] = 1
// Otherwise x[5] = x[7]
```

**Use Case:** Implementing RISC-V division semantics that handle the signed minimum overflow case.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualChangeDivisor,
    mask = 0,
    match = 0,
    format = FormatR,
    ram = ()
);
```

**Implementation:**
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

### 2. VirtualChangeDivisorW

**Operation:** Handle signed 32-bit division overflow case (64-bit mode only)

**Description:** Like `VirtualChangeDivisor` but operates on 32-bit values within 64-bit registers.

**Behavior:**
- **32-bit mode:** Panics (invalid operation)
- **64-bit mode:**
  - If `(x[rs1] as i32) == i32::MIN && (x[rs2] as i32) == -1`: `x[rd] = 1`
  - Otherwise: `x[rd] = x[rs2] as i32 as i64` (sign-extended)

**Example:**
```rust
VirtualChangeDivisorW rd=x3, rs1=x4, rs2=x5
// If x[4] = -2^31 and x[5] = -1, then x[3] = 1
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualChangeDivisorW,
    mask = 0,
    match = 0,
    format = FormatR,
    ram = ()
);
```

**Implementation:**
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

---

## AssertAlignFormat Instructions

**Format Structure:**
```rust
pub struct AssertAlignFormat {
    pub rs1: u8,  // Base address register
    pub imm: i64, // Offset immediate
}
```

### 1. VirtualAssertHalfwordAlignment

**Operation:** `assert((x[rs1] + imm) & 1 == 0)`

**Description:** Asserts that the computed address is halfword-aligned (divisible by 2).

**Address Calculation:** `address = x[rs1] + imm`

**Example:**
```rust
VirtualAssertHalfwordAlignment rs1=x8, imm=4
// Panics if (x[8] + 4) is odd
```

**Error Message:** `"RAM access (LH or LHU) is not halfword aligned: {address:x}"`

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualAssertHalfwordAlignment,
    mask = 0,
    match = 0,
    format = AssertAlignFormat,
    ram = ()
);
```

**Implementation:**
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

### 2. VirtualAssertWordAlignment

**Operation:** `assert((x[rs1] + imm) & 3 == 0)`

**Description:** Asserts that the computed address is word-aligned (divisible by 4).

**Address Calculation:** `address = x[rs1] + imm`

**Example:**
```rust
VirtualAssertWordAlignment rs1=x10, imm=0
// Panics if x[10] is not divisible by 4
```

**Error Message:** `"RAM access (LW or LWU) is not word aligned: {address:x}"`

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualAssertWordAlignment,
    mask = 0,
    match = 0,
    format = AssertAlignFormat,
    ram = ()
);
```

**Implementation:**
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

---

## FormatI Instructions

**Format Structure:**
```rust
pub struct FormatI {
    pub rd: u8,   // Destination register
    pub rs1: u8,  // Source register
    pub imm: u64, // 12-bit immediate (sign-extended)
}
```

### 1. VirtualPow2

**Operation:** `x[rd] = 1 << (x[rs1] % XLEN)`

**Description:** Computes 2 raised to the power of `(x[rs1] % XLEN)`.

**Behavior:**
- **32-bit mode:** `x[rd] = 1 << (x[rs1] % 32)`
- **64-bit mode:** `x[rd] = 1 << (x[rs1] % 64)`

**Example:**
```rust
VirtualPow2 rd=x5, rs1=x6
// If x[6] = 10, then x[5] = 1024
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualPow2,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

**Implementation:**
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

### 2. VirtualPow2W

**Operation:** `x[rd] = 1 << (x[rs1] % 32)`

**Description:** Word-sized (32-bit) power-of-two computation. Only valid in 64-bit mode.

**Behavior:**
- **32-bit mode:** Panics
- **64-bit mode:** `x[rd] = 1 << (x[rs1] % 32)`

**Example:**
```rust
VirtualPow2W rd=x3, rs1=x4
// If x[4] = 5, then x[3] = 32
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualPow2W,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

**Implementation:**
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

### 3. VirtualRev8W

**Operation:** `x[rd] = rev8w(x[rs1])`

**Description:** Reverses the byte order within each 32-bit word of a 64-bit value.

**Behavior:**
- **32-bit mode:** Not implemented
- **64-bit mode:** Reverses bytes in lower and upper 32-bit words independently

**Example:**
```rust
VirtualRev8W rd=x7, rs1=x8
// If x[8] = 0x1234567890ABCDEF
// Then x[7] = 0x78563412EFCDAB90
```

**Use Case:** Endianness conversion for cryptographic operations.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualRev8W,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

**Implementation:**
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

### 4. VirtualMovsign

**Operation:** `x[rd] = (x[rs1] has sign bit set) ? -1 : 0`

**Description:** Extracts the sign bit and extends it to fill the entire register.

**Behavior:**
- **32-bit mode:** Tests bit 31, returns `0xFFFFFFFF` or `0`
- **64-bit mode:** Tests bit 63, returns `0xFFFFFFFFFFFFFFFF` or `0`

**Example:**
```rust
VirtualMovsign rd=x5, rs1=x6
// If x[6] is negative: x[5] = -1 (all ones)
// If x[6] is non-negative: x[5] = 0
```

**Use Case:** Sign extension and conditional masking.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualMovsign,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

**Implementation:**
```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualMovsign as RISCVInstruction>::RAMAccess) {
    let val = cpu.x[self.operands.rs1 as usize] as u64;
    cpu.x[self.operands.rd as usize] = match cpu.xlen {
        Xlen::Bit32 => if val & SIGN_BIT_32 != 0 { ALL_ONES_32 as i64 } else { 0 }
        Xlen::Bit64 => if val & SIGN_BIT_64 != 0 { ALL_ONES_64 as i64 } else { 0 }
    };
}
```

### 5. VirtualSignExtendWord

**Operation:** `x[rd] = (x[rs1] << 32) >> 32`

**Description:** Sign-extends the lower 32 bits to 64 bits. Only valid in 64-bit mode.

**Behavior:**
- **32-bit mode:** Panics
- **64-bit mode:** Takes lower 32 bits, sign-extends to 64 bits

**Example:**
```rust
VirtualSignExtendWord rd=x3, rs1=x4
// If x[4] = 0x00000000FFFFFFFF, then x[3] = 0xFFFFFFFFFFFFFFFF
// If x[4] = 0x000000007FFFFFFF, then x[3] = 0x000000007FFFFFFF
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualSignExtendWord,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

**Implementation:**
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

### 6. VirtualZeroExtendWord

**Operation:** `x[rd] = x[rs1] & 0xFFFFFFFF`

**Description:** Zero-extends the lower 32 bits to 64 bits. Only valid in 64-bit mode.

**Behavior:**
- **32-bit mode:** Panics
- **64-bit mode:** Masks to lower 32 bits, upper bits set to zero

**Example:**
```rust
VirtualZeroExtendWord rd=x5, rs1=x6
// x[5] = x[6] & 0xFFFFFFFF
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualZeroExtendWord,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

**Implementation:**
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

### 7. VirtualMULI

**Operation:** `x[rd] = sign_extend(x[rs1] * imm)`

**Description:** Multiplies register value by immediate and sign-extends the result.

**Example:**
```rust
VirtualMULI rd=x7, rs1=x8, imm=42
// x[7] = sign_extend(x[8] * 42)
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualMULI,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

**Implementation:**
```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualMULI as RISCVInstruction>::RAMAccess) {
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(
            cpu.x[self.operands.rs1 as usize].wrapping_mul(self.operands.imm as i64),
        );
}
```

### 8. VirtualLW

**Operation:** `x[rd] = sign_extend(M[x[rs1] + imm])`

**Description:** Virtual load word operation. Only supported in 32-bit mode.

**Behavior:**
- **32-bit mode:** Loads 32-bit word from memory at address `x[rs1] + imm`, sign-extends to 64-bit internal representation
- **64-bit mode:** Panics (use standard `LW` instruction)

**Example:**
```rust
VirtualLW rd=x5, rs1=x6, imm=8
// x[5] = sign_extend(Memory[x[6] + 8])
```

**RAM Access:** Records memory read operation for tracing.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualLW,
    mask = 0,
    match = 0,
    format = FormatI,
    ram    = super::RAMRead
);
```

**Implementation:**
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

---

## FormatS Instructions

**Format Structure:**
```rust
pub struct FormatS {
    pub rs1: u8,  // Base address register
    pub rs2: u8,  // Source data register
    pub imm: i64, // Offset immediate
}
```

### 1. VirtualSW

**Operation:** `M[x[rs1] + imm] = x[rs2]`

**Description:** Virtual store word operation. Only supported in 32-bit mode.

**Behavior:**
- **32-bit mode:** Stores lower 32 bits of `x[rs2]` to memory at address `x[rs1] + imm`
- **64-bit mode:** Panics (use standard `SW` instruction)

**Example:**
```rust
VirtualSW rs1=x8, rs2=x9, imm=12
// Memory[x[8] + 12] = x[9] (lower 32 bits)
```

**RAM Access:** Records memory write operation for tracing.

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualSW,
    mask = 0,
    match = 0,
    format = FormatS,
    ram    = super::RAMWrite
);
```

**Implementation:**
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

---

## FormatVirtualRightShiftR Instructions

**Format Structure:**
```rust
pub struct FormatVirtualRightShiftR {
    pub rd: u8,  // Destination register
    pub rs1: u8, // Source value register
    pub rs2: u8, // Shift amount register (encoded as trailing zeros)
}
```

**Shift Amount Encoding:** The actual shift amount is `x[rs2].trailing_zeros()`.

**Important:** `x[rs2]` cannot be 0 (undefined trailing zeros count).

### 1. VirtualSRL

**Operation:** `x[rd] = sign_extend(unsigned(x[rs1]) >> shamt)`

**Description:** Logical right shift with shift amount determined by trailing zeros in `x[rs2]`.

**Shift Amount:** `shamt = x[rs2].trailing_zeros()`

**Example:**
```rust
VirtualSRL rd=x5, rs1=x6, rs2=x7
// If x[7] = 0b00001000 (8), trailing_zeros = 3
// x[5] = sign_extend(unsigned(x[6]) >> 3)
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualSRL,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftR,
    ram = ()
);
```

**Implementation:**
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

### 2. VirtualSRA

**Operation:** `x[rd] = sign_extend(x[rs1] >> shamt)`

**Description:** Arithmetic right shift with shift amount determined by trailing zeros in `x[rs2]`.

**Shift Amount:** `shamt = x[rs2].trailing_zeros()`

**Behavior:** Preserves sign bit during right shift.

**Example:**
```rust
VirtualSRA rd=x3, rs1=x4, rs2=x5
// If x[5] = 0b00000100 (4), trailing_zeros = 2
// x[3] = sign_extend(x[4] >> 2)  // Arithmetic shift
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualSRA,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftR,
    ram = ()
);
```

**Implementation:**
```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualSRA as RISCVInstruction>::RAMAccess) {
    let shift = cpu.x[self.operands.rs2 as usize].trailing_zeros();
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(cpu.x[self.operands.rs1 as usize].wrapping_shr(shift));
}
```

### 3. VirtualShiftRightBitmask

**Operation:** `x[rd] = ((2^(XLEN-shift) - 1) << shift)` where `shift = x[rs1] & (XLEN-1)`

**Description:** Generates a bitmask with the upper `(XLEN - shift)` bits set to 1, using the shift amount from register.

**Behavior:**
- **32-bit mode:**
  - `shift = x[rs1] & 0x1F` (lower 5 bits)
  - Creates mask with upper `(32 - shift)` bits set
- **64-bit mode:**
  - `shift = x[rs1] & 0x3F` (lower 6 bits)
  - Creates mask with upper `(64 - shift)` bits set

**Example:**
```rust
VirtualShiftRightBitmask rd=x7, rs1=x8
// If x[8] = 4 (in 64-bit mode):
// Creates mask: 0xFFFFFFFFFFFFFFF0 (60 ones, 4 zeros)
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualShiftRightBitmask,
    mask = 0,
    match = 0,
    format = FormatI,
    ram = ()
);
```

**Implementation:**
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

---

## FormatVirtualRightShiftI Instructions

**Format Structure:**
```rust
pub struct FormatVirtualRightShiftI {
    pub rd: u8,   // Destination register
    pub rs1: u8,  // Source register
    pub imm: u64, // Immediate (shift encoded as trailing zeros)
}
```

**Shift Amount Encoding:** The actual shift amount is `imm.trailing_zeros()`.

**Examples of Encoding:**
- `imm = 4 (0b000100)` → shift by 2
- `imm = 8 (0b001000)` → shift by 3
- `imm = 16 (0b010000)` → shift by 4

### 1. VirtualSRLI

**Operation:** `x[rd] = sign_extend(unsigned(x[rs1]) >> shamt)`

**Description:** Logical right shift immediate with shift amount as trailing zeros of immediate.

**Shift Amount:** `shamt = imm.trailing_zeros()`

**Example:**
```rust
VirtualSRLI rd=x5, rs1=x6, imm=8
// imm=8 has 3 trailing zeros
// x[5] = sign_extend(unsigned(x[6]) >> 3)
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualSRLI,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftI,
    ram = ()
);
```

**Implementation:**
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

### 2. VirtualSRAI

**Operation:** `x[rd] = sign_extend(x[rs1] >> shamt)`

**Description:** Arithmetic right shift immediate with shift amount as trailing zeros of immediate.

**Shift Amount:** `shamt = imm.trailing_zeros()`

**Behavior:** Preserves sign during right shift.

**Example:**
```rust
VirtualSRAI rd=x3, rs1=x4, imm=16
// imm=16 has 4 trailing zeros
// x[3] = sign_extend(x[4] >> 4)  // Arithmetic shift
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualSRAI,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftI,
    ram = ()
);
```

**Implementation:**
```rust
fn exec(&self, cpu: &mut Cpu, _: &mut <VirtualSRAI as RISCVInstruction>::RAMAccess) {
    let shift = self.operands.imm.trailing_zeros();
    cpu.x[self.operands.rd as usize] = cpu
        .sign_extend(cpu.x[self.operands.rs1 as usize].wrapping_shr(shift));
}
```

### 3. VirtualROTRI

**Operation:** `x[rd] = sign_extend(x[rs1].rotate_right(shamt))`

**Description:** Rotates the value in `rs1` right by `shamt` bits, where `shamt = imm.trailing_zeros()`.

**Behavior:**
- **32-bit mode:** Rotates as 32-bit value
- **64-bit mode:** Rotates as 64-bit value

**Example:**
```rust
VirtualROTRI rd=x5, rs1=x6, imm=4
// imm=4 has 2 trailing zeros
// x[5] = sign_extend(rotate_right(x[6], 2))
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualROTRI,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftI,
    ram = ()
);
```

**Implementation:**
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

### 4. VirtualROTRIW

**Operation:** `x[rd] = rotate_right_word(x[rs1], shamt)` (64-bit mode only)

**Description:** Rotates the lower 32 bits of `x[rs1]` right by `shamt` bits, where `shamt = min(imm.trailing_zeros(), XLEN/2)`.

**Behavior:**
- **32-bit mode:** Panics
- **64-bit mode:** Rotates lower 32 bits only, result sign-extended to 64 bits
- Shift amount capped at `XLEN/2` (16 for 32-bit, 32 for 64-bit)

**Example:**
```rust
VirtualROTRIW rd=x7, rs1=x8, imm=8
// imm=8 has 3 trailing zeros, but operates on lower 32 bits
// x[7] = rotate_right_32bit(x[8] as u32, 3) as i64
```

**Declaration:**
```rust
declare_riscv_instr!(
    name = VirtualROTRIW,
    mask = 0,
    match = 0,
    format = FormatVirtualRightShiftI,
    ram = ()
);
```

**Implementation:**
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

---

## Appendix: Common Patterns and Conventions

### Sign Extension

Many virtual instructions use `sign_extend()` to properly handle values based on XLEN:
- **32-bit mode:** Sign-extends from 32 bits to internal 64-bit representation
- **64-bit mode:** Preserves full 64-bit value

### Trailing Zeros Encoding

Instructions in `FormatVirtualRightShift*` use trailing zeros to encode shift amounts:
```
Value    Binary        Trailing Zeros  Shift Amount
2        0b000010      1               1
4        0b000100      2               2
8        0b001000      3               3
16       0b010000      4               4
32       0b100000      5               5
```

This encoding allows efficient verification in zero-knowledge proof systems.

### XLEN-Dependent Operations

Many instructions behave differently based on the current XLEN setting:
- **32-bit mode:** Operates on 32-bit values
- **64-bit mode:** Operates on 64-bit values
- Some instructions (marked with 'W' suffix) are only valid in 64-bit mode but operate on 32-bit values

### Memory Operations

Virtual memory operations (`VirtualLW`, `VirtualSW`) are typically only used in 32-bit mode. In 64-bit mode, standard RISC-V load/store instructions are used instead.

### Assertion Instructions

Instructions with `Assert` in the name panic on assertion failure, providing runtime verification for correctness properties. These are particularly useful for:
- Division edge cases
- Memory alignment requirements
- Overflow detection
- Value range validation

---

## Implementation Notes

All virtual instructions:
- Use `mask = 0` and `match = 0` (virtual instructions don't map to real RISC-V encodings)
- May have XLEN-dependent behavior
- Support both 32-bit and 64-bit modes (unless explicitly restricted)
- Are designed for efficient verification in zero-knowledge proof systems
