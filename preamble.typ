#import "@preview/ctheorems:1.1.3": *
#import "@preview/great-theorems:0.1.2": *
#import "@preview/equate:0.3.2": equate

#set heading(numbering: "1.1")
#set math.equation(numbering: "(1.1)")
#let theorem = thmbox("theorem", "Theorem", fill: rgb("#e8f4fd"))
#let lemma = thmbox("lemma", "Lemma", fill: rgb("#f0f8ff"))
#let definition = thmbox("definition", "Definition", fill: rgb("#f5f5f5"))
// Proof with thin left border line
#let proof = proofblock(
    "proof", 
    "Proof",
    stroke: (left: 0.2pt + gray),  // Only left border
    inset: (left: 1em)           // Some padding from the line
)

// Bibliography
#let bib_state = state("bib_state",  bibliography("ref.bib", style: "association-for-computing-machinery", title: auto))

#let codebox(body) = block(
  fill: rgb("#e5c890").transparentize(65%),
  inset: 8pt,
  radius: 3pt,
  // width: 100%,
)[
  #body
]


