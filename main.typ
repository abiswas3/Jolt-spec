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
  authors: ("Ari", "Quang Dao", "Rose Silver", "Justin Thaler",),
)

// #import "code_template.typ": conf
// #show: conf.with(cols: 92)

#include "chapters/intro.typ"
// #include "chapters/chap2.typ"
#include "chapters/compilations.typ"
#include "chapters/emulation.typ"



#bibliography("ref.bib", style: "association-for-computing-machinery", title: auto) 
