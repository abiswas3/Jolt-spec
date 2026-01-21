// template.typ - Reusable academic paper template
#import "@preview/ctheorems:1.1.3": *
#import "@preview/great-theorems:0.1.2": *
#import "@preview/equate:0.3.2": equate // Referencing equations
#import "@preview/lovelace:0.3.0": * // Algorithms 
#import "@preview/cetz:0.4.0": *

// Main template function
#let template(
  title: "",
  authors: (),
  date: datetime.today(),
  body
) = {
  // Document metadata
  set document(author: authors, title: title)
  
  // Page setup
  set page(
    margin: 1in,
    numbering: "1",
    number-align: center
  )
  
  // Text settings
  set text(
    12pt,
    font: "New Computer Modern",
    lang: "en"
  )
  
  // Heading numbering
  set heading(numbering: "1.1.a.i.")
  
  // Paragraph settings
  set par(justify: true)
  
  // Equation settings
  show: equate.with(breakable: true, sub-numbering: true)
  set math.equation(numbering: "(1.1)")
  
  // Theorem initialization
  show: great-theorems-init
  show: thmrules.with(qed-symbol: $square$)
  
  // Title block
  align(center)[
    #text(17pt, weight: "bold")[#title]
    #v(0.5em)
    #authors.join(", ")
    #v(0.3em)
    #date.display("[month repr:long] [day], [year]")
  ]
  
  
  // Main body
  body
}

// Theorem environments
// #let theorem = thmbox("theorem", "Theorem", fill: rgb("#e8f4fd"))
#let theorem = thmbox("theorem", "Theorem", stroke: (left: 2pt + gray), fill: blue)
#let lemma = thmbox("lemma", "Lemma", fill: rgb("#f0f8ff"))
#let definition = thmbox("definition", "Definition", fill: rgb("#f5f5f5"))
#let corollary = thmbox("corollary", "Corollary", fill: rgb("#fff0f5"))
#let proposition = thmbox("proposition", "Proposition", fill: rgb("#f0fff0"))

// Proof environment with left border
#let proof = proofblock(
  "proof",
  "Proof",
  stroke: (left: 0.2pt + gray),
  inset: (left: 1em)
)

// Additional utilities
#let remark = thmbox("remark", "Remark", fill: rgb("#fffef0"), inset: 0.8em)
#let example = thmbox("example", "Example", fill: rgb("#f0fdf4"), inset: 0.8em)


