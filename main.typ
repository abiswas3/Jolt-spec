#import "preamble.typ": *
#bib_state.update(none)
#import "template.typ": *
#import "commands.typ": * 

#show bibliography: it => {
  show link: set text(blue)
  show link: underline
  it
}
//-------------------------COLOURS----------------------------
#show link: underline
#show link: set text(rgb("#1e66f5").darken(20%), weight: "semibold")
#show cite: set text(fill: rgb("#1e66f5").darken(15%), weight: "medium") // citation colour 
#show footnote.entry: set text(fill: rgb("#282828")) // footnote colours
#show ref: set text(fill: rgb("#006633"), weight: "bold") // equation refs colour 

// Equation settings:
#show: equate.with(breakable: true, sub-numbering: true)
#set math.equation(numbering: "(1.1)")
//-------------------------------------------------------------
#show: template.with(
  title: "Jolt Formal Specification",
  authors: ("Ari", "Quang Dao", "Tan Li", "Rose Silver", "Justin Thaler", "Michael Zhou"),
)

// #import "code_template.typ": conf
// #show: conf.with(cols: 92)

#include "chapters/intro.typ"
#include "chapters/compilations.typ"
#include "chapters/emulation.typ"

#pagebreak()
= Appendix

== All Instrutctions 
```rust
pub enum Instruction {
        /// No-operation instruction (address)
        NoOp,
        UNIMPL,
        ADD(ADD),
        ADDI(ADDI),
        AND(AND),
        ANDI(ANDI),
        ANDN(ANDN),
        AUIPC(AUIPC),
        BEQ(BEQ),
        BGE(BGE),
        BGEU(BGEU),
        BLT(BLT),
        BLTU(BLTU),
        BNE(BNE),
        DIV(DIV),
        DIVU(DIVU),
        ECALL(ECALL),
        FENCE(FENCE),
        JAL(JAL),
        JALR(JALR),
        LB(LB),
        LBU(LBU),
        LD(LD),
        LH(LH),
        LHU(LHU),
        LUI(LUI),
        LW(LW),
        MUL(MUL),
        MULH(MULH),
        MULHSU(MULHSU),
        MULHU(MULHU),
        OR(OR),
        ORI(ORI),
        REM(REM),
        REMU(REMU),
        SB(SB),
        SD(SD),
        SH(SH),
        SLL(SLL),
        SLLI(SLLI),
        SLT(SLT),
        SLTI(SLTI),
        SLTIU(SLTIU),
        SLTU(SLTU),
        SRA(SRA),
        SRAI(SRAI),
        SRL(SRL),
        SRLI(SRLI),
        SUB(SUB),
        SW(SW),
        XOR(XOR),
        XORI(XORI),
        ADDIW(ADDIW),
        SLLIW(SLLIW),
        SRLIW(SRLIW),
        SRAIW(SRAIW),
        ADDW(ADDW),
        SUBW(SUBW),
        SLLW(SLLW),
        SRLW(SRLW),
        SRAW(SRAW),
        LWU(LWU),
        DIVUW(DIVUW),
        DIVW(DIVW),
        MULW(MULW),
        REMUW(REMUW),
        REMW(REMW),
        LRW(LRW),
        SCW(SCW),
        AMOSWAPW(AMOSWAPW),
        AMOADDW(AMOADDW),
        AMOANDW(AMOANDW),
        AMOORW(AMOORW),
        AMOXORW(AMOXORW),
        AMOMINW(AMOMINW),
        AMOMAXW(AMOMAXW),
        AMOMINUW(AMOMINUW),
        AMOMAXUW(AMOMAXUW),
        LRD(LRD),
        SCD(SCD),
        AMOSWAPD(AMOSWAPD),
        AMOADDD(AMOADDD),
        AMOANDD(AMOANDD),
        AMOORD(AMOORD),
        AMOXORD(AMOXORD),
        AMOMIND(AMOMIND),
        AMOMAXD(AMOMAXD),
        AMOMINUD(AMOMINUD),
        AMOMAXUD(AMOMAXUD),
        VirtualAdvice(VirtualAdvice),
        VirtualAssertEQ(VirtualAssertEQ),
        VirtualAssertHalfwordAlignment(VirtualAssertHalfwordAlignment),
        VirtualAssertWordAlignment(VirtualAssertWordAlignment),
        VirtualAssertLTE(VirtualAssertLTE),
        VirtualAssertValidDiv0(VirtualAssertValidDiv0),
        VirtualAssertValidUnsignedRemainder(VirtualAssertValidUnsignedRemainder),
        VirtualAssertMulUNoOverflow(VirtualAssertMulUNoOverflow),
        VirtualChangeDivisor(VirtualChangeDivisor),
        VirtualChangeDivisorW(VirtualChangeDivisorW),
        VirtualLW(VirtualLW),
        VirtualSW(VirtualSW),
        VirtualZeroExtendWord(VirtualZeroExtendWord),
        VirtualSignExtendWord(VirtualSignExtendWord),
        VirtualPow2W(VirtualPow2W),
        VirtualPow2IW(VirtualPow2IW),
        VirtualMovsign(VirtualMovsign),
        VirtualMULI(VirtualMULI),
        VirtualPow2(VirtualPow2),
        VirtualPow2I(VirtualPow2I),
        VirtualRev8W(VirtualRev8W),
        VirtualROTRI(VirtualROTRI),
        VirtualROTRIW(VirtualROTRIW),
        VirtualShiftRightBitmask(VirtualShiftRightBitmask),
        VirtualShiftRightBitmaskI(VirtualShiftRightBitmaskI),
        VirtualSRA(VirtualSRA),
        VirtualSRAI(VirtualSRAI),
        VirtualSRL(VirtualSRL),
        VirtualSRLI(VirtualSRLI),
        VirtualXORROT32(VirtualXORROT32),
        VirtualXORROT24(VirtualXORROT24),
        VirtualXORROT16(VirtualXORROT16),
        VirtualXORROT63(VirtualXORROT63),
        VirtualXORROTW16(VirtualXORROTW16),
        VirtualXORROTW12(VirtualXORROTW12),
        VirtualXORROTW8(VirtualXORROTW8),
        VirtualXORROTW7(VirtualXORROTW7),
        /// Inline instruction from external crates
        INLINE(INLINE),
    }
}    
```


#pagebreak()


#bibliography("ref.bib", style: "association-for-computing-machinery", title: auto) 
